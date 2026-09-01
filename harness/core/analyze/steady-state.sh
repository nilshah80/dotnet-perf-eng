#!/usr/bin/env bash
# Steady-state validator. Every measured number (p99, throughput, and the derived
# per-request efficiency/gate/trend metrics) assumes the measure window was in
# STEADY STATE -- but the harness only does a fixed 10s warm-up and then measures
# the whole window, without confirming the system actually settled. JIT, pool-fill,
# cache-fill and GC settling bleed into a short window and skew the result.
#
# This reads the run's k6 remote-write series from Prometheus over the measure
# window (served RPS = sum(rate(k6_http_reqs_total)), and the k6 latency
# percentiles), buckets the window, and answers three things:
#   1. Did it reach steady state?           (tail throughput/latency CV + drift)
#   2. How long was the warm-up transient?  (recommended trim seconds)
#   3. How much did warm-up skew the numbers? (whole-window vs steady-window)
#
# It reports; it does not change the measurement. Wire the verdict into a gate with
# `gate.sh --require-steady` to refuse numbers taken off a run that never settled.
# Requires PERFLAB_K6_PROM_RW to have been on during the run (the default) so the
# client series exist. Writes analysis/steady-state.json.
#
#   steady-state.sh <run-dir> [--buckets N] [--step S] [--tput-cv C] [--lat-cv C] [--warmup-frac F] [--warmup-tol T]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"

run_arg="${1:?steady-state.sh <run-dir> [--buckets N] [--step S] [--tput-cv C] [--lat-cv C] [--warmup-frac F] [--warmup-tol T]}"; shift || true
buckets="8"; step="10"; tput_cv="0.10"; lat_cv="0.15"; warmup_frac="0.25"; warmup_tol="0.15"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --buckets) buckets="${2:?}"; shift 2 ;;
    --step) step="${2:?}"; shift 2 ;;
    --tput-cv) tput_cv="${2:?}"; shift 2 ;;
    --lat-cv) lat_cv="${2:?}"; shift 2 ;;
    --warmup-frac) warmup_frac="${2:?}"; shift 2 ;;
    --warmup-tol) warmup_tol="${2:?}"; shift 2 ;;
    *) echo "Unknown option '$1'." >&2; exit 2 ;;
  esac
done
[[ -d "${run_arg}" ]] || { echo "steady-state: '${run_arg}' is not a run directory." >&2; exit 2; }
manifest="${run_arg}/manifest.json"
[[ -s "${manifest}" ]] || { echo "steady-state: no manifest.json under '${run_arg}'." >&2; exit 2; }

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

# A ramping/surging profile is non-steady BY DESIGN: a "not steady" verdict there is
# meaningless. Record not-applicable (the measurement is the ramp, not a plateau) and
# stop -- but steady/arrival/soak (constant offered load) are exactly what this checks.
case "${profile}" in
  steady|arrival|soak|"" ) : ;;
  * )
    printf '{"kind":"steady-state","runId":"%s","scenarioId":"%s","profile":"%s","verdict":"not-applicable","reason":"profile is intentionally non-steady (ramp/surge); a plateau check does not apply"}\n' \
      "${run_id}" "${scenario}" "${profile}" > "${out}"
    echo "Steady-state: not applicable to a '${profile}' profile (non-steady by design). Wrote ${out}."
    exit 0 ;;
esac

rps_tsv="$(mktemp)"; p95_tsv="$(mktemp)"; p99_tsv="$(mktemp)"
trap 'rm -f "${rps_tsv}" "${p95_tsv}" "${p99_tsv}"' EXIT
prom_range() { # <query> <outfile>
  curl -fsS -G "${prometheus_url}/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "start=${start}" \
    --data-urlencode "end=${end}" --data-urlencode "step=${step}" 2>/dev/null \
    | jqd -r '.data.result[0].values[]? | "\(.[0]) \(.[1])"' > "$2" 2>/dev/null || true
}
# scenario="measure" is the executor name the profile configs use, excluding any
# setup()/login traffic -- same scoping find-knee.sh uses. k6 RW latency percentiles
# are stored in SECONDS, so awk below multiplies by 1000 for ms.
prom_range "sum(rate(k6_http_reqs_total{run=\"${run_id}\",scenario=\"measure\"}[15s]))" "${rps_tsv}"
prom_range "max(k6_http_req_duration_p95{run=\"${run_id}\",scenario=\"measure\"})" "${p95_tsv}"
prom_range "max(k6_http_req_duration_p99{run=\"${run_id}\",scenario=\"measure\"})" "${p99_tsv}"
# A steady executor keys its series scenario="default", not "measure". Fall back so a
# plain (non-profile) steady run is still assessable.
if [[ ! -s "${rps_tsv}" ]]; then
  prom_range "sum(rate(k6_http_reqs_total{run=\"${run_id}\"}[15s]))" "${rps_tsv}"
  prom_range "max(k6_http_req_duration_p95{run=\"${run_id}\"})" "${p95_tsv}"
  prom_range "max(k6_http_req_duration_p99{run=\"${run_id}\"})" "${p99_tsv}"
fi

samples="$(wc -l < "${rps_tsv}" 2>/dev/null | tr -d ' ')"; samples="${samples:-0}"
if [[ "${samples}" -lt 6 ]]; then
  printf '{"kind":"steady-state","runId":"%s","scenarioId":"%s","profile":"%s","verdict":"insufficient-data","windowSeconds":%s,"samples":%s,"reason":"need >=6 k6 remote-write samples over the window (was PERFLAB_K6_PROM_RW on, Prometheus reachable, and the window long enough at step=%ss?)"}\n' \
    "${run_id}" "${scenario}" "${profile}" "${window}" "${samples}" "${step}" > "${out}"
  echo "steady-state: only ${samples} k6 RW samples for run=${run_id} (need >=6). Wrote ${out}." >&2
  exit 3
fi

# whole-window facts (client-observed) for the skew comparison, from the k6 summary.
w_p99="$(jqd -r '((.observations // [])[]? | select(.name=="http.latency.p99") | .value) // empty' < "${run_arg}/facts.json" 2>/dev/null | head -1)"
w_rps="$(jqd -r '((.observations // [])[]? | select(.name=="http.requests_per_second") | .value) // empty' < "${run_arg}/facts.json" 2>/dev/null | head -1)"

# Everything numeric is computed in one awk pass over the joined (ts,rps,p95,p99)
# grid: bucket means, a stable tail reference, warm-up onset (leading buckets that
# deviate from the tail), tail coefficient-of-variation and drift, and the
# whole-vs-steady skew. Emits a single JSON object.
json="$(awk \
  -v B="${buckets}" -v tcv="${tput_cv}" -v lcv="${lat_cv}" -v wfrac="${warmup_frac}" -v wtol="${warmup_tol}" \
  -v window="${window}" -v runid="${run_id}" -v scen="${scenario}" -v prof="${profile}" \
  -v samples="${samples}" -v step="${step}" -v wp99="${w_p99:-}" -v wrps="${w_rps:-}" '
  function abs(x){ return x<0?-x:x }
  # Tail coefficient of variation (spread) over buckets [a,b); -1 if empty.
  function cv(arr, a,b,   i,cc,su,mu,sd){ cc=0;su=0; for(i=a;i<b;i++){su+=arr[i];cc++} if(cc==0)return -1; mu=su/cc; if(mu==0)return 0; sd=0; for(i=a;i<b;i++){sd+=(arr[i]-mu)*(arr[i]-mu)} sd=sqrt(sd/cc); return sd/(mu<0?-mu:mu) }
  function pct(a,b){ return (b!=0? (a-b)/b*100 : 0) }
  # file 1 = rps, file 2 = p95(ms), file 3 = p99(ms). Join on timestamp.
  FNR==NR { rps[$1]=$2+0; order[++n]=$1; next }
  FILENAME==f2 { p95[$1]=($2+0)*1000; next }
  FILENAME==f3 { p99[$1]=($2+0)*1000; next }
  END {
    # Clamp bucket count so each bucket has >=2 samples; keep >=3 buckets to have a tail.
    if (B > int(n/2)) B = int(n/2); if (B < 3) B = 3;
    # Per-bucket means over the timestamp order (contiguous equal-size groups).
    for (b=0;b<B;b++){ sr[b]=0; s5[b]=0; s9[b]=0; cnt[b]=0 }
    for (i=1;i<=n;i++){ ts=order[i]; b=int((i-1)*B/n); if(b>=B)b=B-1;
      sr[b]+=rps[ts]; s5[b]+=(ts in p95?p95[ts]:0); s9[b]+=(ts in p99?p99[ts]:0); cnt[b]++ }
    for (b=0;b<B;b++){ if(cnt[b]>0){ mr[b]=sr[b]/cnt[b]; m5[b]=s5[b]/cnt[b]; m9[b]=s9[b]/cnt[b] } }
    # Stable reference = mean over the tail half of the buckets.
    t0=int(B/2); tn=0; trR=0; trL=0;
    for (b=t0;b<B;b++){ trR+=mr[b]; trL+=m5[b]; tn++ }
    refR=(tn>0?trR/tn:0); refL=(tn>0?trL/tn:0);
    # Warm-up onset: first bucket from which throughput AND tail-latency are within
    # tolerance of the stable reference. Buckets before it are the warm-up transient.
    onset=0;
    for (b=0;b<B;b++){
      dR=(refR>0?abs(mr[b]-refR)/refR:0); dL=(refL>0?abs(m5[b]-refL)/refL:0);
      if (dR<=wtol && dL<=wtol){ onset=b; break }
      onset=b+1;
    }
    if (onset>=B) onset=B-1;
    # Tail coefficient of variation (spread) for throughput and latency, plus a
    # normalized least-squares drift on tail latency (a rising tail = not settled /
    # degrading, even if the spread looks small).
    cvR=cv(mr,t0,B); cvL=cv(m5,t0,B);
    # drift: slope of tail latency per bucket / mean, over the tail.
    sx=0;sy=0;sxy=0;sxx=0;dc=0; for(b=t0;b<B;b++){ x=b-t0; sx+=x; sy+=m5[b]; sxy+=x*m5[b]; sxx+=x*x; dc++ }
    den=(dc*sxx - sx*sx); slope=(den!=0?(dc*sxy - sx*sy)/den:0); mL=(dc>0?sy/dc:0);
    drift=(mL>0? slope/mL : 0);
    # whole-window vs steady-window (buckets from onset to end) means.
    wR=0;wL5=0;wL9=0;wc=0; for(b=0;b<B;b++){ wR+=mr[b];wL5+=m5[b];wL9+=m9[b];wc++ }
    wR=(wc>0?wR/wc:0); wL5=(wc>0?wL5/wc:0); wL9=(wc>0?wL9/wc:0);
    eR=0;eL5=0;eL9=0;ec=0; for(b=onset;b<B;b++){ eR+=mr[b];eL5+=m5[b];eL9+=m9[b];ec++ }
    eR=(ec>0?eR/ec:0); eL5=(ec>0?eL5/ec:0); eL9=(ec>0?eL9/ec:0);
    trim=int(onset*window/B); ofrac=onset/B;
    # Verdict. A stable tail with a small warm-up is steady; stable but late-settling
    # is warming; an unstable/drifting tail never reached (or left) steady state.
    steadyTail=(cvR>=0 && cvR<=tcv && cvL>=0 && cvL<=lcv && abs(drift)<=lcv);
    if (!steadyTail) verdict="unsteady";
    else if (ofrac<=wfrac) verdict="steady";
    else verdict="warming";
    # skew of the whole-window client numbers vs the steady region (from facts).
    skew9=(wp99!=""? pct(wp99+0, eL9) : pct(wL9, eL9));
    skewR=(wrps!=""? pct(wrps+0, eR) : pct(wR, eR));
    # emit
    printf "{";
    printf "\"kind\":\"steady-state\",\"runId\":\"%s\",\"scenarioId\":\"%s\",\"profile\":\"%s\",", runid, scen, prof;
    printf "\"verdict\":\"%s\",\"windowSeconds\":%d,\"samples\":%d,\"buckets\":%d,\"stepSeconds\":%d,", verdict, window, samples, B, step;
    printf "\"warmup\":{\"onsetBucket\":%d,\"fraction\":%.3f,\"recommendedTrimSeconds\":%d},", onset, ofrac, trim;
    printf "\"tail\":{\"throughputCv\":%.4f,\"latencyCv\":%.4f,\"latencyDriftPerBucket\":%.4f},", cvR, cvL, drift;
    printf "\"thresholds\":{\"throughputCv\":%.3f,\"latencyCv\":%.3f,\"warmupFraction\":%.3f,\"warmupTol\":%.3f},", tcv, lcv, wfrac, wtol;
    printf "\"wholeWindow\":{\"rps\":%.2f,\"p95Ms\":%.2f,\"p99Ms\":%.2f},", (wrps!=""?wrps+0:wR), wL5, (wp99!=""?wp99+0:wL9);
    printf "\"steadyWindow\":{\"rps\":%.2f,\"p95Ms\":%.2f,\"p99Ms\":%.2f},", eR, eL5, eL9;
    printf "\"skewPct\":{\"rps\":%.2f,\"p99\":%.2f},", skewR, skew9;
    # per-bucket series (rounded) for transparency / the AI phase.
    printf "\"series\":{\"rps\":[";     for(b=0;b<B;b++){ printf "%s%.2f",(b?",":""),mr[b] } printf "],";
    printf "\"p99Ms\":[";               for(b=0;b<B;b++){ printf "%s%.2f",(b?",":""),m9[b] } printf "]}";
    printf "}\n";
  }' f2="${p95_tsv}" f3="${p99_tsv}" "${rps_tsv}" "${p95_tsv}" "${p99_tsv}")"

[[ -n "${json}" ]] || { echo "steady-state: computation produced no output." >&2; exit 3; }
printf '%s\n' "${json}" > "${out}"

# Human summary.
verdict="$(jqd -r '.verdict' < "${out}" 2>/dev/null || echo "?")"
read -r trim ofrac cvr cvl p99skew < <(jqd -r '[.warmup.recommendedTrimSeconds,.warmup.fraction,.tail.throughputCv,.tail.latencyCv,.skewPct.p99]|@tsv' < "${out}" 2>/dev/null || echo "0 0 0 0 0")
echo "Steady-state for ${scenario} (run ${run_id}, profile ${profile:-steady})"
case "${verdict}" in
  steady)  echo "  verdict:  STEADY -- tail throughput CV=${cvr}, latency CV=${cvl}; warm-up ~${trim}s (${ofrac} of the window)." ;;
  warming) echo "  verdict:  WARMING -- settled late: warm-up ~${trim}s (${ofrac} of the window). Trim the first ${trim}s or lengthen the run so steady state dominates." >&2 ;;
  unsteady)echo "  verdict:  UNSTEADY -- the tail is still moving (throughput CV=${cvr}, latency CV=${cvl}); the run never reached, or is drifting away from, steady state. Cross-check analyze-trends.sh for a leak/degradation." >&2 ;;
  *)       echo "  verdict:  ${verdict}" >&2 ;;
esac
echo "  skew:     whole-window p99 is ${p99skew}% vs the steady region (positive = warm-up inflated the reported number)."
echo "  wrote ${out}"
