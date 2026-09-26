#!/usr/bin/env bash
# Stage-by-stage analysis of a staged load profile (ramp, load, stress, breakpoint,
# spike, capacity): the server-side throughput, p99 and 5xx ratio of every stage
# of the k6 schedule that actually ran, and the conclusion each profile exists
# to draw (Gate A cases 11 and 12):
#
#   ramp, load, stress, breakpoint, capacity
#     levels are the rising stages up to the peak. The last healthy and the first
#     failing level (errors above the error SLO, p99 above a p99 SLO, or an
#     arrival stage delivering under 95% of its rate), and the first level whose
#     throughput stopped following the load (the plateau).
#   spike
#     baseline hold, surge hold and the recovery: the surge's degradation and the
#     seconds from the end of the surge until p99 and errors are back within 25%
#     (+5 ms) and one point of the baseline, at 5 s resolution.
#
# The stage schedule is the executed benchmark/k6-profile.json, anchored at the
# recorded measurement start; every number is a windowed query over one stage
# (the same histogram and scoping as steady-state.sh). A stage shorter than
# 10 s holds fewer than two metric exports and is reported, not judged.
#
#   analyze-stages.sh <run-dir>   ->   <run-dir>/analysis/stages.json
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

run_arg="${1:?analyze-stages.sh <run-dir>}"
[[ -d "${run_arg}" ]] || { echo "analyze-stages: '${run_arg}' is not a run directory." >&2; exit 2; }
manifest="${run_arg}/manifest.json"
[[ -s "${manifest}" ]] || { echo "analyze-stages: no manifest.json under '${run_arg}'." >&2; exit 2; }
mkdir -p "${run_arg}/analysis"
out="${run_arg}/analysis/stages.json"

run_id="$(jqd -r '.telemetryRunId // .runId' < "${manifest}")"
scenario="$(jqd -r '.scenarioId // ""' < "${manifest}")"
profile="$(jqd -r '.workload.profile // ""' < "${manifest}")"
start="$(jqd -r '.measurementStartedEpoch // 0' < "${manifest}")"
end="$(jqd -r '.measurementEndedEpoch // 0' < "${manifest}")"

finish() { # finish <verdict> <reason>
  printf '{"kind":"stages","runId":"%s","scenarioId":"%s","profile":"%s","verdict":"%s","reason":"%s"}\n' \
    "$(json_escape "${run_id}")" "$(json_escape "${scenario}")" "$(json_escape "${profile}")" "$1" "$(json_escape "$2")" > "${out}"
  echo "Stages: $1 -- $2."
  exit 0
}

# Scope to this run's app instance(s), as steady-state.sh does.
si=""
for mf in request_duration process_cpu application_metrics; do
  [[ -s "${run_arg}/telemetry/metrics/${mf}.json" ]] || continue
  si="$(jqd -r '[.data.result[]?.metric.service_instance_id // .metric.instance // empty] | unique | join("|")' < "${run_arg}/telemetry/metrics/${mf}.json" 2>/dev/null || true)"
  [[ -n "${si}" ]] && break
done
matchers='http_route!~"/health.*|"'
[[ -n "${si}" ]] && matchers="service_instance_id=~\"${si}\",${matchers}"
sel="{${matchers}}"
sel5="{${matchers},http_response_status_code=~\"5..\"}"

prom_instant() { # <query> <time-epoch> -> scalar or ""
  local value="" attempt
  for attempt in 1 2 3; do
    value="$(curl -fsS -G "${prometheus_url}/api/v1/query" \
      --data-urlencode "query=$1" --data-urlencode "time=$2" 2>/dev/null \
      | jqd -r '.data.result[0].value[1] // empty' 2>/dev/null | head -1 || true)"
    [[ -n "${value}" && "${value}" != "NaN" ]] && { printf '%s\n' "${value}"; return 0; }
    (( attempt < 3 )) && sleep 1
  done
  return 0
}
# Client-observed transport failures (k6 status 0: a connection that never got a
# response) never reach the server histogram, so a stage whose connections were
# dropped before the application would otherwise read as healthy.
k6_run="testid=\"$(json_escape "${run_id}")\""
window_stats() { # window_stats <from> <to> -> "rps p99ms errRatio transportRatio" (empty fields as -)
  local from="$1" to="$2" w rps p99 bad sent failed
  w=$(( to - from )); (( w < 1 )) && w=1
  rps="$(prom_instant "sum(rate(http_server_request_duration_seconds_count${sel}[${w}s]))" "${to}")"
  p99="$(prom_instant "1000*histogram_quantile(0.99, sum by (le) (rate(http_server_request_duration_seconds_bucket${sel}[${w}s])))" "${to}")"
  bad="$(prom_instant "sum(rate(http_server_request_duration_seconds_count${sel5}[${w}s]))" "${to}")"
  sent="$(prom_instant "sum(increase(k6_http_reqs_total{${k6_run}}[${w}s]))" "${to}")"
  failed="$(prom_instant "sum(increase(k6_http_reqs_total{${k6_run},status=\"0\"}[${w}s]))" "${to}")"
  awk -v r="${rps}" -v p="${p99}" -v b="${bad:-0}" -v sent="${sent}" -v f="${failed:-0}" 'BEGIN {
    t = (sent != "" && sent + 0 > 0 ? (f + 0) / (sent + 0) : "-")
    if (r == "") { printf "- - - %s\n", t; exit }
    printf "%s %s %s %s\n", r, (p == "" ? "-" : p), (r + 0 > 0 ? (b + 0) / (r + 0) : 0), t }'
}

# SLO thresholds from the lab's slos.tsv: the scenario's own row, else default.
slo() { # slo <metric>
  local file="${lab_dir:-}/slos.tsv"
  [[ -s "${file}" ]] || return 0
  awk -F'\t' -v s="${scenario}" -v m="$1" '$0 !~ /^#/ && $2 == m && $3 == "max" {
    if ($1 == s) own = $4; else if ($1 == "default") dflt = $4 }
    END { if (own != "") print own; else if (dflt != "") print dflt }' "${file}"
}
p99_slo="$(slo http.latency.p99)"
err_slo="$(slo http.error_rate)"; err_slo="${err_slo:-0.02}"

# Fault outcome (run-fault.sh): whether the target degraded while a dependency
# was down and how long after the restore it recovered -- the question a fault
# run exists to answer. Baseline is the measurement start to the fault; the
# outage is applied to restored; recovery probes 10 s windows every 5 s from the
# restore until p99 and errors are back within the spike tolerance.
# recover_after <epoch> <tolerance-p99-ms> <tolerance-error-ratio>: probe 10 s
# windows every 5 s from <epoch> until p99 and errors are back within the
# tolerance. Sets recovered, seconds and samples (JSON objects, comma-joined).
recover_after() {
  local from="$1" tol_p99="$2" tol_err="$3" probe rps p99 err
  recovered="false"; seconds="null"; samples=""
  for (( probe = from + 10; probe <= end; probe += 5 )); do
    read -r rps p99 err _ <<< "$(window_stats $(( probe - 10 )) "${probe}")"
    samples+="${samples:+,}{\"atEpoch\":${probe},\"p99Ms\":$([[ "${p99}" == "-" ]] && echo null || echo "${p99}"),\"errorRatio\":$([[ "${err}" == "-" ]] && echo null || echo "${err}")}"
    if [[ "${p99}" != "-" ]] && awk -v p="${p99}" -v tp="${tol_p99}" -v r="${err}" -v tr="${tol_err}" 'BEGIN { exit !(p + 0 <= tp + 0 && r + 0 <= tr + 0) }'; then
      recovered="true"; seconds=$(( probe - from )); return 0
    fi
  done
}

fault_proof="${run_arg}/benchmark/fault-proof.json"
if [[ -s "${fault_proof}" && "${start}" -gt 0 && "${end}" -gt "${start}" ]]; then
  applied=0; restored=0
  # Only a fault that was applied has an outage to analyse.
  read -r applied restored < <(jqd -r 'select(.applied == true) | [(.appliedAt | fromdateiso8601? // 0), (.restoredAt | fromdateiso8601? // 0)] | @tsv' < "${fault_proof}" 2>/dev/null) || true
  fault_json='{"kind":"fault","captureState":"not-captured","reason":"the fault proof records no applied fault with applied and restored times"}'
  if [[ "${applied:-0}" -gt "${start}" && "${restored:-0}" -ge "${applied}" ]]; then
    read -r b_rps b_p99 b_err _ <<< "$(window_stats "${start}" "${applied}")"
    read -r o_rps o_p99 o_err _ <<< "$(window_stats "${applied}" "$(( restored > applied ? restored : applied + 1 ))")"
    if [[ "${b_rps}" == "-" || "${b_p99}" == "-" || $(( applied - start )) -lt 10 ]]; then
      fault_json='{"kind":"fault","captureState":"not-captured","reason":"fewer than 10 s of server samples before the fault to form a baseline"}'
    else
      tol_p99="$(awk -v p="${b_p99}" 'BEGIN { printf "%.3f", p * 1.25 + 5 }')"
      tol_err="$(awk -v e="${b_err}" 'BEGIN { printf "%.6f", e + 0.01 }')"
      recover_after "${restored}" "${tol_p99}" "${tol_err}"
      fault_json="$(jqd -c \
        --argjson ba "${applied}" --argjson re "${restored}" --arg brps "${b_rps}" --arg bp99 "${b_p99}" --arg berr "${b_err}" \
        --arg orps "${o_rps}" --arg op99 "${o_p99}" --arg oerr "${o_err}" --argjson tp "${tol_p99}" --argjson te "${tol_err}" \
        --argjson recovered "${recovered}" --argjson seconds "${seconds}" --argjson samples "[${samples}]" '
        def num: if . == "-" then null else tonumber end;
        . as $proof
        | {kind:"fault", captureState:"captured", dependency:$proof.service, action:$proof.action,
         appliedEpoch:$ba, restoredEpoch:$re, basis:"server-side windowed (http_server_request_duration histogram)",
         baseline:{rps:($brps|num), p99Ms:($bp99|num), errorRatio:($berr|num)},
         outage:{rps:($orps|num), p99Ms:($op99|num), errorRatio:($oerr|num)},
         toleranceP99Ms:$tp, toleranceErrorRatio:$te} as $f
        | $f + {degraded:(($f.outage.p99Ms // 0) > $tp or ($f.outage.errorRatio // 0) > $te or (($f.outage.rps // 0) < 0.5 * ($f.baseline.rps // 0))),
                recovered:$recovered, recoverySeconds:$seconds, resolutionSeconds:5, windowSeconds:10, samples:$samples}' < "${fault_proof}")"
    fi
  fi
  printf '%s\n' "${fault_json}" > "${run_arg}/analysis/fault.json"
  jqd -r 'if .captureState == "captured" then "Fault (\(.action) \(.dependency)): baseline p99 \(.baseline.p99Ms) ms, errors \(.baseline.errorRatio) -> outage p99 \(.outage.p99Ms // "?") ms, errors \(.outage.errorRatio // "?") (degraded: \(.degraded)); recovered: \(.recovered) after \(.recoverySeconds // "?") s" else "Fault: \(.captureState) -- \(.reason)" end' < "${run_arg}/analysis/fault.json"
fi

case "${profile}" in
  ramp|load|stress|breakpoint|spike|capacity|knee) ;;
  *) finish "not-applicable" "profile '${profile}' has no load stages" ;;
esac
schedule="${run_arg}/benchmark/k6-profile.json"
[[ -s "${schedule}" ]] || finish "not-captured" "no executed k6 stage schedule (benchmark/k6-profile.json)"
[[ "${start}" -gt 0 && "${end}" -gt "${start}" ]] || finish "not-captured" "the manifest has no measurement window"

executor="$(jqd -r '.scenarios.measure.executor // ""' < "${schedule}")"
unit="VUs"; [[ "${executor}" == "ramping-arrival-rate" ]] && unit="req/s"
stages="$(jqd -r '.scenarios.measure.stages[]? | [(.duration | rtrimstr("s") | tonumber), .target] | @tsv' < "${schedule}")"
[[ -n "${stages}" ]] || finish "not-captured" "the executed schedule has no stages"

# Stage windows from the recorded measurement start, clipped to the window end.
rows=""; t="${start}"; index=0; previous_target="$(jqd -r '.scenarios.measure.startVUs // .scenarios.measure.startRate // 0' < "${schedule}")"
while IFS=$'\t' read -r duration stage_target; do
  [[ -n "${duration}" ]] || continue
  s="${t}"; e=$(( t + ${duration%.*} )); (( e > end )) && e="${end}"; t=$(( t + ${duration%.*} ))
  kind="ramp"; [[ "${stage_target}" == "${previous_target}" ]] && kind="hold"
  if (( e - s >= 10 )); then read -r rps p99 err transport <<< "$(window_stats "${s}" "${e}")"; else rps="-"; p99="-"; err="-"; transport="-"; fi
  rows+="${index}"$'\t'"${s}"$'\t'"${e}"$'\t'"${previous_target}"$'\t'"${stage_target}"$'\t'"${kind}"$'\t'"${rps}"$'\t'"${p99}"$'\t'"${err}"$'\t'"${transport}"$'\n'
  previous_target="${stage_target}"; index=$(( index + 1 ))
done <<< "${stages}"

# Judge each stage and derive the profile's conclusion in one awk pass.
spike_mode=0; [[ "${profile}" == "spike" ]] && spike_mode=1
# The generator is the authority on delivery: an arrival executor drops the
# iterations it cannot start. The served rate is a rate() over 5 s exports of a
# series that only begins with the load, so a first ramp stage under-reads
# (S08, P07: "delivered 67.9 of 75.5" with 0 dropped); a shortfall counts only
# when the run dropped iterations.
dropped=0
[[ -s "${run_arg}/facts.json" ]] && dropped="$(jqd -r '((.observations // [])[]? | select(.name == "http.dropped_iterations") | .value) // 0' < "${run_arg}/facts.json" 2>/dev/null | head -1 || true)"
summary="$(printf '%s' "${rows}" | awk -F'\t' -v unit="${unit}" -v p99slo="${p99_slo}" -v errslo="${err_slo}" -v spike="${spike_mode}" -v dropped="${dropped:-0}" '
  { i=$1+0; s[i]=$2; e[i]=$3; from[i]=$4+0; tg[i]=$5+0; kind[i]=$6; rps[i]=$7; p99[i]=$8; err[i]=$9; tr[i]=$10; n=i+1 }
  function judged(k) { return rps[k] != "-" }
  # A linear ramp delivers its average rate, not its end target.
  function expected(k) { return (kind[k] == "ramp" ? (from[k] + tg[k]) / 2 : tg[k]) }
  function short(k) { return unit == "req/s" && dropped + 0 > 0 && rps[k] + 0 < 0.95 * expected(k) }
  function transport_bad(k) { return tr[k] != "-" && tr[k] + 0 > errslo + 0 }
  function healthy(k,   ok) {
    ok = (err[k] + 0 <= errslo + 0) && !transport_bad(k)
    if (p99slo != "" && p99[k] != "-" && p99[k] + 0 > p99slo + 0) ok = 0
    if (short(k)) ok = 0
    return ok }
  function why(k,   r) {
    r = ""
    if (err[k] + 0 > errslo + 0) r = r sprintf("5xx ratio %.3f > %s; ", err[k], errslo)
    if (transport_bad(k)) r = r sprintf("client transport errors %.3f > %s (connections that never got a response); ", tr[k], errslo)
    if (p99slo != "" && p99[k] != "-" && p99[k] + 0 > p99slo + 0) r = r sprintf("p99 %.1f ms > SLO %s ms; ", p99[k], p99slo)
    if (short(k)) r = r sprintf("delivered %.1f of %.1f req/s with %d iterations dropped; ", rps[k], expected(k), dropped)
    return r }
  END {
    printf "{\"stages\":["
    for (k = 0; k < n; k++) {
      printf "%s{\"index\":%d,\"kind\":\"%s\",\"startEpoch\":%d,\"endEpoch\":%d,\"fromTarget\":%d,\"target\":%d,\"unit\":\"%s\",", (k ? "," : ""), k, kind[k], s[k], e[k], from[k], tg[k], unit
      if (judged(k)) printf "\"judged\":true,\"expectedRate\":%s,\"servedRps\":%.4f,\"p99Ms\":%s,\"errorRatio\":%.6f,\"transportErrorRatio\":%s,\"healthy\":%s,\"reasons\":\"%s\"}", (unit == "req/s" ? sprintf("%.1f", expected(k)) : "null"), rps[k], (p99[k] == "-" ? "null" : sprintf("%.3f", p99[k])), err[k], (tr[k] == "-" ? "null" : sprintf("%.6f", tr[k])), (healthy(k) ? "true" : "false"), why(k)
      else printf "\"judged\":false,\"reason\":\"%s\"}", (e[k] - s[k] < 10 ? "stage shorter than 10 s: fewer than two metric exports" : "no server-side request samples in this stage window")
    }
    printf "]"
    if (spike) {
      base = -1; surge = -1; peak = -1
      for (k = 0; k < n; k++) if (kind[k] == "hold" && judged(k)) { if (base < 0) base = k; if (tg[k] > peak) { peak = tg[k]; surge = k } }
      if (base < 0 || surge < 0 || surge == base) { printf ",\"spike\":{\"captureState\":\"not-captured\",\"reason\":\"no judged baseline and surge hold stages\"}}"; exit }
      bp = p99[base] + 0; be = err[base] + 0; sp = p99[surge] + 0; se = err[surge] + 0
      degraded = (sp > bp * 1.25 + 5 || se > be + 0.01)
      printf ",\"spike\":{\"captureState\":\"captured\",\"baselineStage\":%d,\"surgeStage\":%d,\"baselineP99Ms\":%.3f,\"baselineErrorRatio\":%.6f,\"surgeP99Ms\":%.3f,\"surgeErrorRatio\":%.6f,\"degraded\":%s,\"surgeEndEpoch\":%d,\"toleranceP99Ms\":%.3f,\"toleranceErrorRatio\":%.6f}", base, surge, bp, be, sp, se, (degraded ? "true" : "false"), e[surge], bp * 1.25 + 5, be + 0.01
    } else {
      last = -1; first = -1; plateau = -1; scaled = -1; prevk = -1
      for (k = 0; k < n; k++) {
        if (!judged(k) || (prevk >= 0 && tg[k] < tg[prevk])) continue
        if (healthy(k)) { if (first < 0) last = k } else if (first < 0) first = k
        if (plateau < 0 && prevk >= 0 && expected(k) >= 1.2 * expected(prevk) && rps[prevk] + 0 > 0 && rps[k] + 0 < 1.05 * rps[prevk]) { plateau = k; scaled = prevk }
        prevk = k
      }
      printf ",\"levels\":{\"lastHealthyStage\":%s,\"lastHealthyTarget\":%s,\"firstFailingStage\":%s,\"firstFailingTarget\":%s,\"firstFailingReasons\":\"%s\",\"plateauStage\":%s,\"plateauTarget\":%s,\"scaledUpToTarget\":%s}", \
        (last < 0 ? "null" : last), (last < 0 ? "null" : tg[last]), (first < 0 ? "null" : first), (first < 0 ? "null" : tg[first]), (first < 0 ? "" : why(first)), (plateau < 0 ? "null" : plateau), (plateau < 0 ? "null" : tg[plateau]), (scaled < 0 ? "null" : tg[scaled])
    }
    printf "}"
  }')"

# Spike recovery: 10 s windows every 5 s from the end of the surge.
recovery='null'
if [[ "${spike_mode}" == 1 ]] && jqd -e '.spike.captureState == "captured"' <<< "${summary}" >/dev/null 2>&1; then
  surge_end="$(jqd -r '.spike.surgeEndEpoch' <<< "${summary}")"
  tol_p99="$(jqd -r '.spike.toleranceP99Ms' <<< "${summary}")"; tol_err="$(jqd -r '.spike.toleranceErrorRatio' <<< "${summary}")"
  degraded="$(jqd -r '.spike.degraded' <<< "${summary}")"
  if [[ "${degraded}" == "false" ]]; then
    recovered="true"; seconds=0; samples=""
  else
    recover_after "${surge_end}" "${tol_p99}" "${tol_err}"
  fi
  recovery="{\"recovered\":${recovered},\"recoverySeconds\":${seconds},\"resolutionSeconds\":5,\"windowSeconds\":10,\"samples\":[${samples}]}"
fi

jqd --arg run "${run_id}" --arg scen "${scenario}" --arg prof "${profile}" --arg exec "${executor}" \
  --arg p99slo "${p99_slo}" --arg errslo "${err_slo}" --argjson recovery "${recovery}" \
  '{kind:"stages", runId:$run, scenarioId:$scen, profile:$prof, verdict:"captured", executor:$exec,
    basis:"server-side windowed (http_server_request_duration histogram) per executed k6 stage",
    thresholds:{p99SloMs:($p99slo|tonumber? // null), errorRatio:($errslo|tonumber)}} + .
    | if .spike and $recovery != null then .spike += $recovery else . end' <<< "${summary}" > "${out}"

jqd -r '"Stages (\(.profile), \(.executor)):",
  (.stages[] | "  stage \(.index) \(.kind) \(.fromTarget)->\(.target) \(.unit): " +
    (if .judged then "\(.servedRps|floor) rps, p99 \(.p99Ms // "?") ms, 5xx \(.errorRatio)\(if .transportErrorRatio then ", transport \(.transportErrorRatio)" else "" end) -> \(if .healthy then "healthy" else "FAILING (\(.reasons))" end)" else .reason end)),
  (if ([.stages[] | select(.judged)] | length) == 0 then "  no stage could be judged" elif .levels then "  last healthy: \(.levels.lastHealthyTarget // "none") ; first failing: \(.levels.firstFailingTarget // "none within the tested range") ; throughput \(if .levels.scaledUpToTarget then "stopped scaling above \(.levels.scaledUpToTarget) " + (.stages[0].unit) else "kept scaling" end)" else empty end),
  (if .spike.captureState == "captured" then "  spike: baseline p99 \(.spike.baselineP99Ms) ms -> surge p99 \(.spike.surgeP99Ms) ms (degraded: \(.spike.degraded)); recovered: \(.spike.recovered) after \(.spike.recoverySeconds // "?") s" else empty end)' < "${out}"
echo "wrote ${out}"
