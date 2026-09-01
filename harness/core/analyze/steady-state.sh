#!/usr/bin/env bash
# Steady-state validator. Every measured number (p99, throughput, and the derived
# per-request efficiency/gate/trend metrics) assumes the measure window was in
# STEADY STATE -- but the harness only does a fixed 10s warm-up and then measures
# the whole window, without confirming the system actually settled. JIT, pool-fill,
# cache-fill and GC settling bleed into a short window and skew the result.
#
# It divides the measure window into equal TIME buckets and, per bucket, reads two
# genuinely WINDOW-LOCAL server metrics from Prometheus:
#   throughput = sum(rate(http_server_request_duration_seconds_count[bucket]))
#   p99        = histogram_quantile(0.99, sum by (le) (rate(..._bucket[bucket])))
# and answers:
#   1. Did it reach steady state?   (tail throughput/latency DRIFT -- a systematic trend)
#   2. How long was the warm-up?    (recommended trim seconds, time-accurate)
#   3. How much did warm-up skew it? (whole-window vs steady-region, same estimator)
#
# The verdict is DRIFT-based (least-squares slope over the tail), NOT spread/CV: steady
# state means "no systematic trend", so a flat-but-noisy series or a single outlier
# bucket stays steady, while a monotonic ramp (warm-up not done, or degrading) does not.
# CV is reported for information. A latency floor ignores sub-few-ms jitter on very fast
# endpoints (where a trivial absolute move is a huge relative one).
#
# WHY the server histogram, not k6: k6's remote-write p95/p99 gauges are CUMULATIVE
# for the whole run (one TrendSink per series, samples never reset), so they cannot be
# treated as sub-window values -- they converge monotonically and mask tail drift. The
# server-side histogram_quantile over a rate() window IS window-local, and is captured
# for every run (no dependency on k6 remote-write). It measures server processing time.
#
# SCOPE -- this certifies SERVER-side steady state, NOT client-p99 steadiness. k6's
# client percentiles cannot be windowed (cumulative, above), so client-side p99 TAIL
# steadiness is not independently verified. The verdict requires windowed THROUGHPUT and
# server p99 to be non-drifting; in a closed-loop run (fixed VUs) throughput =
# VUs/MEAN-iteration-duration, so throughput drift tracks client MEAN latency -- but NOT
# a p99/tail drift that leaves the mean (hence throughput) roughly unchanged. An open-
# loop (arrival) run pins the offered rate, so throughput does not track client latency
# at all. Both facts are emitted (clientLatencyCoupling, certifies) so a caller never
# mistakes a server-steady verdict for a client-p99-steady guarantee.
#
# It reports; it does not change the measurement. Enforce with `gate.sh
# --require-steady`. Writes analysis/steady-state.json and stamps a compact
# `.steadyState` onto facts.json so the verdict travels with the package (and a
# promoted baseline).
#
#   steady-state.sh <run-dir> [--buckets N] [--tput-drift D] [--lat-drift D] [--warmup-frac F] [--warmup-tol T] [--lat-floor-ms M]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"

run_arg="${1:?steady-state.sh <run-dir> [--buckets N] [--tput-drift D] [--lat-drift D] [--warmup-frac F] [--warmup-tol T] [--lat-floor-ms M]}"; shift || true
buckets="6"; tput_drift="0.10"; lat_drift="0.15"; warmup_frac="0.25"; warmup_tol="0.15"; lat_floor_ms="5"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --buckets) buckets="${2:?}"; shift 2 ;;
    --tput-drift) tput_drift="${2:?}"; shift 2 ;;
    --lat-drift) lat_drift="${2:?}"; shift 2 ;;
    --warmup-frac) warmup_frac="${2:?}"; shift 2 ;;
    --warmup-tol) warmup_tol="${2:?}"; shift 2 ;;
    --lat-floor-ms) lat_floor_ms="${2:?}"; shift 2 ;;
    *) echo "Unknown option '$1'." >&2; exit 2 ;;
  esac
done
[[ -d "${run_arg}" ]] || { echo "steady-state: '${run_arg}' is not a run directory." >&2; exit 2; }
manifest="${run_arg}/manifest.json"
[[ -s "${manifest}" ]] || { echo "steady-state: no manifest.json under '${run_arg}'." >&2; exit 2; }
facts="${run_arg}/facts.json"

run_id="$(jqd -r '.telemetryRunId // .runId' < "${manifest}")"
scenario="$(jqd -r '.scenarioId // ""' < "${manifest}")"
profile="$(jqd -r '.workload.profile // ""' < "${manifest}")"
start="$(jqd -r '.measurementStartedEpoch // .startedEpoch // 0' < "${manifest}")"
end="$(jqd -r '.measurementEndedEpoch // 0' < "${manifest}")"
[[ "${end}" -gt 0 ]] || end="$(date -u +%s)"
[[ "${start}" -gt 0 ]] || { echo "steady-state: manifest has no measurement window." >&2; exit 2; }
window=$(( end - start )); (( window < 1 )) && window=1
mkdir -p "${run_arg}/analysis"
out="${run_arg}/analysis/steady-state.json"

# Stamp a compact verdict onto facts.json so it travels with the package (gate.sh and a
# promoted baseline read it). Provenance is automatic: it lives in the candidate's own
# facts, matching its runId/scenarioId. Best-effort (append-only, like the efficiency
# and status stamps in capture-evidence.sh).
stamp_facts() { # <json-object-for-.steadyState>
  [[ -s "${facts}" ]] || return 0
  if jqd --argjson ss "$1" '.steadyState=$ss' < "${facts}" > "${facts}.tmp" 2>/dev/null; then
    mv "${facts}.tmp" "${facts}"
  else
    rm -f "${facts}.tmp"
  fi
}
finish_early() { # <verdict> <reason>
  printf '{"kind":"steady-state","runId":"%s","scenarioId":"%s","profile":"%s","verdict":"%s","windowSeconds":%s,"basis":"server-side windowed (http_server_request_duration histogram)","reason":"%s"}\n' \
    "${run_id}" "${scenario}" "${profile}" "$1" "${window}" "$2" > "${out}"
  stamp_facts "{\"verdict\":\"$1\",\"recommendedTrimSeconds\":0,\"basis\":\"server-side windowed\",\"runId\":\"${run_id}\",\"scenarioId\":\"${scenario}\"}"
}

# A ramping/surging profile is non-steady BY DESIGN: a plateau check does not apply.
case "${profile}" in
  steady|arrival|soak|"" ) : ;;
  * )
    finish_early "not-applicable" "profile is intentionally non-steady (ramp/surge); a plateau check does not apply"
    echo "Steady-state: not applicable to a '${profile}' profile (non-steady by design). Wrote ${out}."
    exit 0 ;;
esac

# Bucket count: equal TIME buckets, each wide enough for a meaningful windowed p99
# (>=8s). B is clamped so width>=8s; <3 buckets -> the window is too short to judge.
B="${buckets}"
maxb=$(( window / 8 )); (( B > maxb )) && B="${maxb}"
if (( B < 3 )); then
  finish_early "insufficient-data" "window ${window}s is too short for 3 buckets of >=8s; lengthen the run"
  echo "steady-state: window ${window}s too short (need >=24s). Wrote ${out}." >&2
  exit 3
fi
width=$(( window / B ))

# Scope to THIS run's app instance(s) so stale series from earlier (restarted) app
# processes are excluded; the request-count file is derived from the run's metrics.
si=""
for mf in request_duration process_cpu application_metrics; do
  [[ -s "${run_arg}/telemetry/metrics/${mf}.json" ]] || continue
  si="$(jqd -r '[.data.result[]?.metric.service_instance_id // .metric.instance // empty] | unique | join("|")' < "${run_arg}/telemetry/metrics/${mf}.json" 2>/dev/null || true)"
  [[ -n "${si}" ]] && break
done
if [[ -n "${si}" ]]; then
  sel="{service_instance_id=~\"${si}\",http_route!~\"/health.*|\"}"
else
  sel="{http_route!~\"/health.*|\"}"
fi

prom_instant() { # <query> <time-epoch> -> scalar or ""
  curl -fsS -G "${prometheus_url}/api/v1/query" \
    --data-urlencode "query=$1" --data-urlencode "time=$2" 2>/dev/null \
    | jqd -r '.data.result[0].value[1] // empty' 2>/dev/null | head -1
}

# Per-bucket windowed throughput + p99. Buckets TILE the window exactly: bucket i is
# [start+i*window/B, start+(i+1)*window/B], and the rate() range == that bucket's OWN
# width (window/B rounds to 15 or 16s), evaluated at the bucket end. Using a single
# floor(window/B) range would leave ~1s gaps between buckets and miss the window tail.
data="$(mktemp)"; trap 'rm -f "${data}"' EXIT
valid=0
for ((i=0; i<B; i++)); do
  bstart=$(( start + i*window/B ))
  bend=$(( start + (i+1)*window/B ))
  brange=$(( bend - bstart )); (( brange < 1 )) && brange=1
  tp="$(prom_instant "sum(rate(http_server_request_duration_seconds_count${sel}[${brange}s]))" "${bend}")"
  p99="$(prom_instant "1000*histogram_quantile(0.99, sum by (le) (rate(http_server_request_duration_seconds_bucket${sel}[${brange}s])))" "${bend}")"
  # No zero-fill: a bucket counts only if BOTH throughput (>0) and a real p99 are
  # present. Missing/NaN latency must NOT become 0 (that would fake a perfectly-steady
  # tail and let the gate pass on absent data).
  if [[ -n "${tp}" && -n "${p99}" && "${p99}" != "NaN" ]] && awk "BEGIN{exit !(${tp}+0>0 && \"${p99}\"+0>0)}" 2>/dev/null; then
    printf '%d %s %s\n' "${i}" "${tp}" "${p99}" >> "${data}"
    valid=$((valid+1))
  fi
done

if (( valid < B )); then
  finish_early "insufficient-data" "only ${valid}/${B} time buckets had both server throughput and a p99 (a pure-worker scenario has no HTTP server histogram; or telemetry was incomplete)"
  echo "steady-state: ${valid}/${B} buckets usable for run=${run_id} (need all ${B}; server http histogram required, health routes excluded). Wrote ${out}." >&2
  exit 3
fi

# whole-window CLIENT p99 (the REPORTED headline number) for reference only -- it is
# client-observed and cumulative, so it is NOT the skew basis (that is server-side).
c_p99="$(jqd -r '((.observations // [])[]? | select(.name=="http.latency.p99") | .value) // empty' < "${facts}" 2>/dev/null | head -1)"

json="$(awk \
  -v B="${B}" -v width="${width}" -v window="${window}" -v tdr="${tput_drift}" -v ldr="${lat_drift}" \
  -v latfloor="${lat_floor_ms}" -v wfrac="${warmup_frac}" -v wtol="${warmup_tol}" \
  -v runid="${run_id}" -v scen="${scenario}" -v prof="${profile}" -v cp99="${c_p99:-}" -v si="${si}" '
  function abs(x){ return x<0?-x:x }
  function cv(arr, a,b,   i,cc,su,mu,sd){ cc=0;su=0; for(i=a;i<b;i++){su+=arr[i];cc++} if(cc==0)return -1; mu=su/cc; if(mu==0)return 0; sd=0; for(i=a;i<b;i++){sd+=(arr[i]-mu)*(arr[i]-mu)} sd=sqrt(sd/cc); return sd/(mu<0?-mu:mu) }
  # normalized least-squares slope per bucket over [a,b): a systematic TREND, robust to a
  # single outlier bucket (a fit, not a spread). This drives the verdict, not CV.
  function drift(arr, a,b,   i,n,sx,sy,sxy,sxx,x,slope,mu){ n=0;sx=0;sy=0;sxy=0;sxx=0;
    for(i=a;i<b;i++){ x=i-a; sx+=x; sy+=arr[i]; sxy+=x*arr[i]; sxx+=x*x; n++ }
    if(n<2 || (n*sxx-sx*sx)==0) return 0;
    slope=(n*sxy-sx*sy)/(n*sxx-sx*sx); mu=sy/n; return (mu!=0? slope/mu : 0) }
  function pct(a,b){ return (b!=0? (a-b)/b*100 : 0) }
  # median over [a,b): the tail REFERENCE for warm-up onset must be outlier-robust, or a
  # single spike bucket inflates the mean and makes steady buckets look like warm-up.
  function median(arr, a,b,   i,n,v,j,t){ n=0; for(i=a;i<b;i++){ v[n]=arr[i]; n++ }
    for(i=1;i<n;i++){ t=v[i]; j=i-1; while(j>=0 && v[j]>t){ v[j+1]=v[j]; j-- } v[j+1]=t }
    if(n==0) return 0; if(n%2==1) return v[int(n/2)]; return (v[n/2-1]+v[n/2])/2 }
  { mr[$1]=$2+0; m9[$1]=$3+0 }
  END {
    t0=int(B/2);
    refR=median(mr,t0,B); refL=median(m9,t0,B);
    # in-band per bucket vs the robust (median) tail reference; count ALL out-of-band
    # buckets so mid/late deviations are surfaced, not hidden by the onset value.
    oob=0;
    for(b=0;b<B;b++){ dR=(refR>0?abs(mr[b]-refR)/refR:0); dL=(refL>0?abs(m9[b]-refL)/refL:0);
      inband[b]=(dR<=wtol && dL<=wtol)?1:0; if(!inband[b]) oob++ }
    # warm-up onset = end of the LEADING transient: the first bucket that is in-band AND
    # STAYS in-band through the next bucket, so a single lucky touch does not end warm-up
    # early. Mid/late out-of-band buckets are noise (reported as bucketsOutOfBand) and are
    # handled by the drift verdict, not folded into the trim.
    # Require a GENUINE two-in-a-row settling (b AND b+1 both in-band). The last bucket
    # alone cannot be an onset -- there is no next bucket to confirm it stayed settled.
    settled=0; onset=B;
    for(b=0;b<B-1;b++){ if(inband[b] && inband[b+1]){ onset=b; settled=1; break } }
    cvR=cv(mr,t0,B); cvL=cv(m9,t0,B);
    driftR=drift(mr,t0,B); driftL=drift(m9,t0,B);
    # Fast endpoints: below the latency floor, a few ms of jitter is a large RELATIVE
    # drift but physically negligible -- do not let it drive the verdict.
    latDriftEff=(refL < latfloor ? 0 : driftL);
    wR=0;wL=0; for(b=0;b<B;b++){ wR+=mr[b]; wL+=m9[b] } wR/=B; wL/=B;
    eR=0;eL=0;ec=0; for(b=onset;b<B;b++){ eR+=mr[b]; eL+=m9[b]; ec++ } eR=(ec>0?eR/ec:0); eL=(ec>0?eL/ec:0);
    trim=(settled?onset*width:0); ofrac=(settled?onset/B:1);
    # steady = no systematic trend AND a real 2-bucket settling; warming = settled but
    # late; NO settling pair => the run never reached steady state, whatever the drift.
    steadyTail=(abs(driftR)<=tdr && abs(latDriftEff)<=ldr);
    if(!steadyTail || !settled) verdict="unsteady"; else if(ofrac<=wfrac) verdict="steady"; else verdict="warming";
    skewR=pct(wR,eR); skewL=pct(wL,eL);
    printf "{";
    printf "\"kind\":\"steady-state\",\"runId\":\"%s\",\"scenarioId\":\"%s\",\"profile\":\"%s\",", runid, scen, prof;
    printf "\"basis\":\"server-side windowed (http_server_request_duration histogram)\",\"scopedInstance\":\"%s\",", si;
    printf "\"clientLatencyCoupling\":\"%s\",", (prof=="arrival"?"open-loop: offered rate pinned; throughput does NOT track client latency":"closed-loop: throughput tracks client MEAN latency (fixed VUs), not the p99 tail");
    printf "\"certifies\":\"server-side steady state (windowed throughput + server p99); client-side p99 TAIL steadiness is NOT independently verified (k6 client percentiles are cumulative)\",";
    printf "\"verdict\":\"%s\",\"windowSeconds\":%d,\"buckets\":%d,\"bucketWidthSeconds\":%d,", verdict, window, B, width;
    printf "\"warmup\":{\"onsetBucket\":%s,\"settled\":%s,\"fraction\":%.3f,\"recommendedTrimSeconds\":%d,\"bucketsOutOfBand\":%d},", (settled?sprintf("%d",onset):"null"), (settled?"true":"false"), ofrac, trim, oob;
    printf "\"tail\":{\"throughputDriftPerBucket\":%.4f,\"latencyDriftPerBucket\":%.4f,\"throughputCv\":%.4f,\"latencyCv\":%.4f},", driftR, driftL, cvR, cvL;
    printf "\"thresholds\":{\"throughputDrift\":%.3f,\"latencyDrift\":%.3f,\"latencyFloorMs\":%.1f,\"warmupFraction\":%.3f,\"warmupTol\":%.3f},", tdr, ldr, latfloor, wfrac, wtol;
    printf "\"wholeWindow\":{\"servedRps\":%.2f,\"serverP99Ms\":%.2f},", wR, wL;
    printf "\"steadyWindow\":{\"servedRps\":%.2f,\"serverP99Ms\":%.2f},", eR, eL;
    printf "\"skewPct\":{\"servedRps\":%.2f,\"serverP99\":%.2f},", skewR, skewL;
    printf "\"clientP99MsReported\":%s,", (cp99!=""? sprintf("%.2f",cp99+0) : "null");
    printf "\"series\":{\"servedRps\":["; for(b=0;b<B;b++){ printf "%s%.2f",(b?",":""),mr[b] } printf "],";
    printf "\"serverP99Ms\":["; for(b=0;b<B;b++){ printf "%s%.2f",(b?",":""),m9[b] } printf "]}";
    printf "}\n";
  }' "${data}")"

[[ -n "${json}" ]] || { echo "steady-state: computation produced no output." >&2; exit 3; }
printf '%s\n' "${json}" > "${out}"

# The per-bucket series above drives the DRIFT verdict; but a mean of per-window p99s is
# NOT itself a p99. Report the whole-window and steady-region (onset..end) p99/throughput
# as TRUE single windowed quantiles (histogram_quantile over one rate window), and base
# the skew on those.
sverdict="$(jqd -r '.verdict' < "${out}" 2>/dev/null || echo "")"
settled_f="$(jqd -r '.warmup.settled' < "${out}" 2>/dev/null || echo false)"
onset_b="$(jqd -r '.warmup.onsetBucket // 0' < "${out}" 2>/dev/null || echo 0)"
# The whole-window numbers are always meaningful; compute them as TRUE single windowed
# quantiles (histogram_quantile over one rate window).
w_rps="$(prom_instant "sum(rate(http_server_request_duration_seconds_count${sel}[${window}s]))" "${end}")"
w_p99="$(prom_instant "1000*histogram_quantile(0.99, sum by (le) (rate(http_server_request_duration_seconds_bucket${sel}[${window}s])))" "${end}")"
if [[ "${settled_f}" == "true" && ( "${sverdict}" == "steady" || "${sverdict}" == "warming" ) ]]; then
  # Settled: report the steady region (onset..end), exact trim from the tiling endpoint.
  trim_exact=$(( onset_b * window / B ))
  steady_secs=$(( window - trim_exact )); (( steady_secs < 8 )) && steady_secs=$(( window / B ))
  s_rps="$(prom_instant "sum(rate(http_server_request_duration_seconds_count${sel}[${steady_secs}s]))" "${end}")"
  s_p99="$(prom_instant "1000*histogram_quantile(0.99, sum by (le) (rate(http_server_request_duration_seconds_bucket${sel}[${steady_secs}s])))" "${end}")"
  if [[ -n "${w_rps}" && -n "${w_p99}" && -n "${s_rps}" && -n "${s_p99}" && "${w_p99}" != "NaN" && "${s_p99}" != "NaN" ]]; then
    patched="$(jqd --argjson wr "${w_rps}" --argjson wp "${w_p99}" --argjson sr "${s_rps}" --argjson sp "${s_p99}" --argjson trim "${trim_exact}" '
      .warmup.recommendedTrimSeconds=$trim
      | .wholeWindow={servedRps:($wr*100|round/100),serverP99Ms:($wp*100|round/100)}
      | .steadyWindow={servedRps:($sr*100|round/100),serverP99Ms:($sp*100|round/100)}
      | .skewPct={servedRps:(if $sr!=0 then (($wr-$sr)/$sr*10000|round/100) else 0 end),
                  serverP99:(if $sp!=0 then (($wp-$sp)/$sp*10000|round/100) else 0 end)}' < "${out}" 2>/dev/null || cat "${out}")"
    [[ -n "${patched}" ]] && printf '%s\n' "${patched}" > "${out}"
  fi
else
  # UNSTEADY / never-settled: NULL the steady-region fields UNCONDITIONALLY -- they are
  # meaningless without a settled window, and must not survive as zero placeholders just
  # because the whole-window query happened to fail. Update wholeWindow to true windowed
  # values only when ITS query succeeds; otherwise leave the awk's bucket-mean estimate.
  if [[ -n "${w_rps}" && -n "${w_p99}" && "${w_p99}" != "NaN" ]]; then
    patched="$(jqd --argjson wr "${w_rps}" --argjson wp "${w_p99}" '
      .warmup.recommendedTrimSeconds=null
      | .wholeWindow={servedRps:($wr*100|round/100),serverP99Ms:($wp*100|round/100)}
      | .steadyWindow=null | .skewPct=null' < "${out}" 2>/dev/null || cat "${out}")"
  else
    patched="$(jqd '.warmup.recommendedTrimSeconds=null | .steadyWindow=null | .skewPct=null' < "${out}" 2>/dev/null || cat "${out}")"
  fi
  [[ -n "${patched}" ]] && printf '%s\n' "${patched}" > "${out}"
fi

compact="$(jqd -c '{verdict,recommendedTrimSeconds:.warmup.recommendedTrimSeconds,basis:"server-side windowed",serverP99SkewPct:.skewPct.serverP99,runId,scenarioId}' < "${out}" 2>/dev/null || echo '{}')"
stamp_facts "${compact}"

verdict="$(jqd -r '.verdict' < "${out}" 2>/dev/null || echo "?")"
# Coalesce the now-nullable trim/skew to a token so an empty @tsv field can't shift the
# rest under the default IFS.
read -r trim ofrac dR dL skew oob < <(jqd -r '[(.warmup.recommendedTrimSeconds // "n/a"),.warmup.fraction,.tail.throughputDriftPerBucket,.tail.latencyDriftPerBucket,(.skewPct.serverP99 // "n/a"),.warmup.bucketsOutOfBand]|@tsv' < "${out}" 2>/dev/null || echo "n/a 0 0 0 n/a 0")
oobnote=""; [[ "${oob:-0}" != "0" ]] && oobnote=" (${oob}/${B} buckets out-of-band -- noise, see CV)"
echo "Steady-state for ${scenario} (run ${run_id}, profile ${profile:-steady})  [server-side windowed, ${B}x${width}s buckets]"
case "${verdict}" in
  steady)  echo "  verdict:  STEADY -- no tail trend (throughput drift=${dR}/bucket, server-p99 drift=${dL}/bucket); warm-up ~${trim}s (${ofrac} of the window)${oobnote}." ;;
  warming) echo "  verdict:  WARMING -- settled late: warm-up ~${trim}s (${ofrac} of the window). Trim the first ${trim}s or lengthen the run so steady state dominates." >&2 ;;
  unsteady)echo "  verdict:  UNSTEADY -- did not reach steady state (throughput drift=${dR}/bucket, server-p99 drift=${dL}/bucket; a drifting tail and/or no 2-bucket settling). No steady sub-window. Cross-check analyze-trends.sh for a leak/degradation." >&2 ;;
  *)       echo "  verdict:  ${verdict}" >&2 ;;
esac
if [[ "${skew}" != "n/a" ]]; then
  echo "  skew:     server p99 over the whole window is ${skew}% vs the steady region (positive = warm-up inflated the reported number)."
else
  echo "  window:   no steady sub-window (the run never settled) -- no trim or steady-region skew reported."
fi
echo "  wrote ${out} (verdict also stamped onto facts.json)"
