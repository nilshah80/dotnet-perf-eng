#!/usr/bin/env bash
# Capacity knee: for a ramping-arrival-rate ("capacity") run, report the highest
# sustained throughput reached before p99 latency breaches the SLO -- the single
# number a capacity plan needs.
#
# It reads the run's k6 remote-write time-series from Prometheus
# (k6_http_reqs_total rate = offered/served RPS, and k6_http_req_duration_p99,
# both labelled run=<PERF_RUN_ID>) over the measure window, walks time forward,
# and finds the RPS at the first sample where p99 crosses the SLO. Requires
# PERFLAB_K6_PROM_RW to have been on during the run (the default) so the client
# series exist. Writes analysis/capacity.json.
#
#   find-knee.sh <run-dir> [--p99-ms N] [--slos P] [--step S]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"
# shellcheck disable=SC1091
source "${here}/../lib/slo-lib.sh"

run_arg="${1:?find-knee.sh <run-dir> [--p99-ms N] [--slos P] [--step S]}"; shift || true
p99_ms_override=""; slos_override=""; step="5"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --p99-ms) p99_ms_override="${2:?}"; shift 2 ;;
    --slos) slos_override="${2:?}"; shift 2 ;;
    --step) step="${2:?}"; shift 2 ;;
    *) echo "Unknown option '$1'." >&2; exit 2 ;;
  esac
done
[[ -d "${run_arg}" ]] || { echo "find-knee: '${run_arg}' is not a run directory." >&2; exit 2; }
manifest="${run_arg}/manifest.json"
[[ -s "${manifest}" ]] || { echo "find-knee: no manifest.json under '${run_arg}'." >&2; exit 2; }

run_id="$(jqd -r '.telemetryRunId // .runId' < "${manifest}")"
scenario="$(jqd -r '.scenarioId // ""' < "${manifest}")"
profile="$(jqd -r '.workload.profile // ""' < "${manifest}")"
start="$(jqd -r '.measurementStartedEpoch // .startedEpoch // 0' < "${manifest}")"
end="$(jqd -r '.measurementEndedEpoch // 0' < "${manifest}")"
[[ "${end}" -gt 0 ]] || end="$(date -u +%s)"
[[ "${start}" -gt 0 ]] || { echo "find-knee: manifest has no measurement window." >&2; exit 2; }
[[ "${profile}" == "capacity" ]] || echo "find-knee: NOTE profile is '${profile}', not 'capacity'; the knee only means something for a ramping-arrival-rate run." >&2

# p99 SLO in ms: explicit override, else the scenario's http.latency.p99 max from slos.tsv.
p99_ms="${p99_ms_override}"
if [[ -z "${p99_ms}" ]]; then
  slos_file="${slos_override:-${lab_dir}/slos.tsv}"
  p99_ms="$(slo_effective "${slos_file}" "${scenario}" 2>/dev/null | awk -F'\t' '$1=="http.latency.p99" && $2=="max"{print $3; exit}')"
fi
[[ -n "${p99_ms}" ]] || { echo "find-knee: no p99 SLO (set --p99-ms N or add 'http.latency.p99 max <ms>' to slos.tsv for ${scenario})." >&2; exit 2; }

rps_tsv="$(mktemp)"; p99_tsv="$(mktemp)"
trap 'rm -f "${rps_tsv}" "${p99_tsv}"' EXIT
prom_range() { # <query> <outfile>
  curl -fsS -G "${prometheus_url}/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "start=${start}" \
    --data-urlencode "end=${end}" --data-urlencode "step=${step}" 2>/dev/null \
    | jqd -r '.data.result[0].values[]? | "\(.[0]) \(.[1])"' > "$2" 2>/dev/null || true
}
# scenario="measure" is the executor name the profile config uses (see
# adapters/loadgen/k6/profiles.sh), which excludes any setup()/login traffic (e.g.
# the ecommerce auth in setup()) that must not count toward served throughput.
prom_range "sum(rate(k6_http_reqs_total{run=\"${run_id}\",scenario=\"measure\"}[15s]))" "${rps_tsv}"
prom_range "max(k6_http_req_duration_p99{run=\"${run_id}\",scenario=\"measure\"})" "${p99_tsv}"

if [[ ! -s "${rps_tsv}" || ! -s "${p99_tsv}" ]]; then
  echo "find-knee: no k6 measure-scenario series in Prometheus for run=${run_id}. Was PERFLAB_K6_PROM_RW on, Prometheus reachable during the run, and was this a --profile capacity run (executor 'measure')?" >&2
  exit 3
fi

# max_ok accumulates ONLY before the first breach: a later temporary recovery must
# not report a "max sustained" above the point where the SLO first broke.
read -r max_ok breach_rps breach_ms peak_rps peak_ms < <(awk -v slo="${p99_ms}" '
  FNR==NR { p99[$1]=$2*1000; next }
  { ts=$1; rps=$2+0; if (!(ts in p99)) next; ms=p99[ts]
    if (!breached && ms<=slo && rps>max_ok) max_ok=rps
    if (ms>slo && !breached) { breached=1; brps=rps; bms=ms }
    if (rps>peak_rps) { peak_rps=rps; pms=ms } }
  END { printf "%.1f %s %s %.1f %.1f\n", max_ok+0, (breached?sprintf("%.1f",brps):"-"), (breached?sprintf("%.1f",bms):"-"), peak_rps+0, pms+0 }
' "${p99_tsv}" "${rps_tsv}") || true

# Dropped iterations: with an arrival-rate executor a dropped iteration means the
# offered rate could not even be launched -- OFFERED load exceeded SERVED
# throughput (VU starvation and/or server saturation). Read the generator's count.
dropped="$(jqd -r '((.observations // [])[]? | select(.name=="http.dropped_iterations") | .value) // 0' < "${run_arg}/facts.json" 2>/dev/null | head -1)"
[[ -n "${dropped}" ]] || dropped=0

echo "Capacity knee for ${scenario} (run ${run_id}, profile ${profile})"
echo "  p99 SLO:                   ${p99_ms} ms"
echo "  max sustained (SERVED):    ${max_ok} req/s   (highest SERVED rate with p99 <= SLO, before the first breach)"
if [[ "${breach_rps}" != "-" ]]; then
  echo "  first SLO breach at:       ${breach_rps} req/s served   (p99 = ${breach_ms} ms)"
else
  echo "  SLO breach:                none within the run -- raise PERFLAB_TARGET_RPS to push further"
fi
echo "  peak served:               ${peak_rps} req/s   (p99 there = ${peak_ms} ms)"
if awk "BEGIN{exit !(${dropped}+0 > 0)}" 2>/dev/null; then
  echo "  NOTE: ${dropped} iterations were DROPPED -- the executor could not launch the offered rate, so"
  echo "        OFFERED load exceeded SERVED throughput (VU starvation and/or server saturation). Treat the"
  echo "        served knee as a LOWER BOUND; if drops are VU starvation, raise PERFLAB_MAX_VUS and re-run."
fi

mkdir -p "${run_arg}/analysis"
printf '{"kind":"capacity-knee","runId":"%s","scenarioId":"%s","profile":"%s","p99SloMs":%s,"maxSustainedServedRps":%s,"breachServedRps":%s,"breachP99Ms":%s,"peakServedRps":%s,"peakP99Ms":%s,"droppedIterations":%s}\n' \
  "${run_id}" "${scenario}" "${profile}" "${p99_ms}" "${max_ok}" \
  "$([[ "${breach_rps}" == "-" ]] && echo null || echo "${breach_rps}")" \
  "$([[ "${breach_ms}" == "-" ]] && echo null || echo "${breach_ms}")" \
  "${peak_rps}" "${peak_ms}" "${dropped}" > "${run_arg}/analysis/capacity.json"
echo "  wrote ${run_arg}/analysis/capacity.json"
