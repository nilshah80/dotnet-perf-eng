#!/usr/bin/env bash
# D-P1-8: the perflab-baggage-v1 probe decides whether capture may select the
# measured phase. It must verify only an exact echo of the run and phase, never
# fail a run, and refuse phase scoping for a generator that sends no baggage:
# phase-filtered queries against a browser run would return nothing and look
# like missing evidence.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
fail() { echo "baggage-contract-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

export PERFLAB_LAB_OPTIONAL=1
# shellcheck disable=SC1091
source "${root}/harness/core/lib/common.sh"
# The host jq, with the same CR and MSYS guards common.sh's jqd applies.
jqd() { MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
# shellcheck disable=SC1091
source "${root}/harness/core/lib/performance.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/baggage-contract.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM
calls="${work}/calls"

# Stands in for the target: records the request, writes the body to -o and
# prints the status like curl -w '%{http_code}'.
probe_mode=echo
target_curl() {
  local output="" url="" header="" previous=""
  for argument in "$@"; do
    case "${previous}" in
      -o) output="${argument}" ;;
      -H) header="${argument}" ;;
    esac
    previous="${argument}"
    url="${argument}"
  done
  printf '%s %s\n' "${url}" "${header}" >> "${calls}"
  case "${probe_mode}" in
    echo) printf '{"contractVersion":"perflab-baggage-v1","runId":"run-7","phase":"measure","source":"injected"}' > "${output}"; printf 200 ;;
    wrong) printf '{"contractVersion":"perflab-baggage-v1","runId":"other","phase":"measure"}' > "${output}"; printf 200 ;;
    absent) printf 'Not Found' > "${output}"; printf 404 ;;
    down) return 7 ;;
  esac
}

probe() { # <generator> <protocol> -> proof path
  local proof="${work}/proof-$1-$2-${probe_mode}.json"
  load_generator="$1" PERF_PROTOCOL="$2" performance_baggage_probe "https://target.example/api/v1/" run-7 "${proof}" 2>/dev/null \
    || fail "the probe failed a run (${probe_mode})"
  printf '%s' "${proof}"
}

proof="$(probe k6 "")"
jq -e '.state == "verified" and .phaseScoped == true and .version == "perflab-baggage-v1" and .runId == "run-7"' "${proof}" >/dev/null \
  || fail "an exact echo was not verified: $(cat "${proof}")"
grep -q '^https://target.example/perf/baggage baggage: perf.run.id=run-7,perf.phase=measure$' "${calls}" \
  || fail "the probe did not ask the target's origin with the run's baggage: $(cat "${calls}")"

for generator in wrk jmeter; do
  jq -e '.phaseScoped == true' "$(probe "${generator}" "")" >/dev/null || fail "${generator} sends baggage but was not phase-scoped"
done

proof="$(probe k6 browser-synthetic)"
jq -e '.state == "verified" and .phaseScoped == false and (.phaseScopeReason | test("browser"))' "${proof}" >/dev/null \
  || fail "a browser run was phase-scoped: $(cat "${proof}")"

probe_mode=wrong
jq -e '.state == "refused" and .phaseScoped == false' "$(probe k6 "")" >/dev/null || fail "a wrong echo was trusted"

probe_mode=absent
proof="$(probe k6 "")"
jq -e '.state == "not-advertised" and .phaseScoped == false and (.reason | test("404"))' "${proof}" >/dev/null \
  || fail "a target without the contract was not reported as not advertised: $(cat "${proof}")"

probe_mode=down
jq -e '.state == "not-advertised" and .phaseScoped == false' "$(probe k6 "")" >/dev/null || fail "an unreachable probe was trusted"

# An unbounded run id is never sent to the target.
probe_mode=echo
: > "${calls}"
load_generator=k6 performance_baggage_probe "https://target.example/" 'run 7;x' "${work}/bad.json" 2>/dev/null
jq -e '.state == "not-advertised" and (.reason | test("bounded"))' "${work}/bad.json" >/dev/null || fail "an unbounded run id was probed"
[[ ! -s "${calls}" ]] || fail "an unbounded run id reached the target"

echo "baggage contract probe tests passed"
