#!/usr/bin/env bash
# A baseline must come from a settled measurement. E11's 30 s repetitions were
# measured mostly inside JIT warm-up and read 15-19% below the steady 60 s ones;
# promoting them biased every later comparison.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "update-baseline-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"
work="$(mktemp -d "${TMPDIR:-/tmp}/update-baseline-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM

# A private copy of the lab config, so baselines land in the temp directory.
mkdir -p "${work}/lab"
cp "${repo}/labs/ecommerce/lab.config.sh" "${work}/lab/lab.config.sh"
source_run() { # source_run <name> <steady-verdict> -> run dir
  mkdir -p "${work}/$1"
  printf '{"scenarioId":"E11","status":"captured","loadGenerator":"wrk","steadyState":{"verdict":"%s"},"observations":[]}\n' "$2" > "${work}/$1/facts.json"
  printf '%s' "${work}/$1"
}
promote() {
  PERFLAB_JQ=host PERFLAB_CONFIG="${work}/lab/lab.config.sh" bash "${repo}/harness/core/analyze/update-baseline.sh" "$@"
}

for verdict in warming unsteady insufficient-data; do
  if promote "$(source_run "${verdict}" "${verdict}")" > /dev/null 2> "${work}/refused.err"; then
    fail "a '${verdict}' source was promoted to a baseline"
  fi
  grep -q "steady-state verdict is '${verdict}': the measurement did not settle" "${work}/refused.err" || fail "the refusal does not name the verdict: $(cat "${work}/refused.err")"
done
[[ ! -e "${work}/lab/baselines/E11.json" ]] || fail "a refused source still wrote a baseline"

# A ramp or stress profile varies the load by design: not-applicable, promotable.
promote "$(source_run ramp not-applicable)" > /dev/null || fail "a not-applicable (varying-profile) source was refused"
promote "$(source_run steady steady)" > /dev/null || fail "a steady source was refused"
jq -e '.steadyState.verdict == "steady"' "${work}/lab/baselines/E11.json" > /dev/null || fail "the steady baseline was not written"
promote "$(source_run forced warming)" --allow-unsteady > /dev/null 2>&1 || fail "--allow-unsteady did not override the guard"

echo "update-baseline tests passed"
