#!/usr/bin/env bash
# Load-profile execution semantics.
#
# Acceptance cases 9, 11 and 12. A profile name is a promise about HOW load is
# applied, and the k6 executor is where that promise is kept or silently broken:
#
#   9  closed execution means a fixed population of concurrent users. A
#      constant-VUs executor delivers that; an arrival-rate executor does not,
#      and the two answer different questions about the same system.
#  11  breakpoint must climb past the declared load so there IS a last healthy
#      and a first failing level to record. A ramp that stops at the declared
#      connections can never find a breaking point.
#  12  spike must return to the baseline after the burst, or there is no
#      recovery phase to measure -- only a failure.
#
# These compile the REAL profile definitions; the executor and stages are the
# contract between a profile name and what k6 actually does.
set -euo pipefail

adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${adapter_dir}/../../../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/k6-profile-shape-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT HUP INT TERM
fail() { echo "k6-profile-shape-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

mkdir -p "${test_root}/bin"
cat > "${test_root}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "run" ]] || exit 0
shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in --rm|--interactive|-i|-t|--tty) shift ;; *) break ;; esac
done
shift
exec $(command -v jq) "\$@"
EOF
chmod +x "${test_root}/bin/docker"

export PATH="${test_root}/bin:${PATH}"
export PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh"
# shellcheck disable=SC1091
source "${repo}/harness/core/lib/common.sh"
# shellcheck disable=SC1091
source "${repo}/harness/adapters/loadgen/k6/profiles.sh"

compile() { # compile <profile> -> options JSON path
  local profile="$1" out="${test_root}/${1}.json"
  PERFLAB_PROFILE="${profile}" PERFLAB_MAX_VUS=256 PERFLAB_TARGET_RPS=400 \
    k6_write_profile_config "${profile}" 64 60 "${out}" \
    || fail "profile '${profile}' failed to compile"
  printf '%s' "${out}"
}

executor() { jq -r '.scenarios.measure.executor' < "$1"; }
targets()  { jq -r '[.scenarios.measure.stages[]?.target] | join(",")' < "$1"; }

# --- case 9: closed execution is a fixed concurrent population --------------
closed="$(compile closed)"
[[ "$(executor "${closed}")" == "constant-vus" ]] \
  || fail "the closed profile compiled to '$(executor "${closed}")'; a closed model is a fixed VU population"
[[ "$(jq -r '.scenarios.measure.vus' < "${closed}")" == "64" ]] \
  || fail "the closed profile did not honour the declared connection count"
jq -e '.scenarios.measure | has("rate") | not' "${closed}" >/dev/null \
  || fail "the closed profile carries an arrival rate; it would answer an open-model question instead"

# --- case 11: breakpoint must climb past the declared load ------------------
breakpoint="$(compile breakpoint)"
[[ "$(executor "${breakpoint}")" == "ramping-vus" ]] \
  || fail "breakpoint compiled to '$(executor "${breakpoint}")'; it has to ramp to find a limit"
peak="$(jq -r '[.scenarios.measure.stages[].target] | max' < "${breakpoint}")"
[[ "${peak}" -gt 64 ]] \
  || fail "breakpoint peaks at ${peak}, which is not above the declared 64; it can never reach a first failing level"
stage_count="$(jq -r '.scenarios.measure.stages | length' < "${breakpoint}")"
[[ "${stage_count}" -ge 3 ]] \
  || fail "breakpoint has ${stage_count} stage(s); distinguishing last healthy from first failing needs several levels"

# --- case 12: spike must return to baseline so recovery is measurable -------
spike="$(compile spike)"
[[ "$(executor "${spike}")" == "ramping-vus" ]] \
  || fail "spike compiled to '$(executor "${spike}")'"
first="$(jq -r '.scenarios.measure.stages[0].target' < "${spike}")"
last="$(jq -r '.scenarios.measure.stages[-1].target' < "${spike}")"
spike_peak="$(jq -r '[.scenarios.measure.stages[].target] | max' < "${spike}")"
[[ "${spike_peak}" -gt "${first}" ]] \
  || fail "spike never rises above its baseline (${first}); there is no spike to recover from"
[[ "${last}" == "${first}" ]] \
  || fail "spike ends at ${last} rather than returning to its ${first} baseline; recovery time cannot be measured"

# --- the open model stays distinct from the closed one ----------------------
open="$(compile open)"
[[ "$(executor "${open}")" == "constant-arrival-rate" ]] \
  || fail "the open profile compiled to '$(executor "${open}")'; open arrival is rate-driven, not VU-driven"
[[ "$(executor "${open}")" != "$(executor "${closed}")" ]] \
  || fail "open and closed compiled to the same executor; the distinction is not real"

echo "k6 profile shape (closed, breakpoint, spike) tests passed"
