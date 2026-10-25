#!/usr/bin/env bash
# C-9 / C-10 / C-11. Qualify every advertised capability, not every combination.
# JMeter extras stay out of this gate (C-4).
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
fail() { echo "capability-qualification-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

# C-9. Protocol Reliability is an advertised lab. Its catalog, k6 workload,
# and diagnostic kinds must exist and name the capabilities they claim.
pr="${root}/labs/protocol-reliability"
[[ -f "${pr}/catalog.json" && -f "${pr}/loadgen/k6.js" && -f "${pr}/scenarios.tsv" ]] \
  || fail "protocol-reliability lab assets are missing"
jq -e '.scenarios | length >= 1' "${pr}/catalog.json" >/dev/null \
  || fail "protocol-reliability catalog has no scenarios"
jq -e '[.scenarios[].workload.type] | index("protocol")' "${pr}/catalog.json" >/dev/null \
  || fail "C-9 protocol-reliability catalog lost protocol workloads"
jq -e '[.scenarios[].diagnostics.preset] | index("stacks")' "${pr}/catalog.json" >/dev/null \
  || fail "C-9 protocol-reliability catalog lost stacks diagnostics"

# C-10. Advertised k6 profiles (not JMeter extras).
profiles_sh="${root}/harness/adapters/loadgen/k6/profiles.sh"
shape_test="${root}/harness/adapters/loadgen/k6/profile-shape-test.sh"
[[ -f "${profiles_sh}" && -f "${shape_test}" ]] || fail "k6 profile compiler or shape test is missing"
for profile in smoke load steady ramp stress breakpoint capacity knee spike open closed soak arrival; do
  grep -Eq "(^|[[:space:]|])${profile}(\)|\|)" "${profiles_sh}" || fail "advertised k6 profile ${profile} is not compiled"
done
# wrk and JMeter subsets are advertised as subsets; unsupported profiles fail
# before traffic. That refusal is the qualification, not implementing extras.
# shellcheck disable=SC1091
source "${root}/harness/core/lib/performance.sh"
# Delegates to the host jq so the selector under test is the real one, but it
# must keep BOTH guards common.sh's jqd applies. jq.exe writes CRLF on Windows,
# so a value read through a bare override carries a trailing CR that corrupts
# every later comparison and URL built from it; and MSYS rewrites any argument
# that looks like a POSIX path, so `--arg path /stacks` reaches jq.exe as
# C:/Program Files/Git/stacks and the lookup silently misses.
jqd() { MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
performance_profile_preflight closed jmeter || fail "advertised JMeter closed profile was refused"
if performance_profile_preflight soak jmeter 2>/dev/null; then
  fail "JMeter soak (unadvertised extra) was accepted"
fi
if performance_profile_preflight stress jmeter 2>/dev/null; then
  fail "JMeter stress (unadvertised extra) was accepted"
fi
performance_profile_preflight soak k6 || fail "advertised k6 soak profile was refused"

# The generic adapter's profile support is not permission to run every
# selector. The manifest is the exact per-selector capability declaration.
manifest="${pr}/workload-manifest.json"
[[ -f "${manifest}" ]] || fail "protocol-reliability workload manifest is missing"
performance_manifest_selector_preflight "${manifest}" P12 k6 journey \
  || fail "declared k6 security journey was refused"
if performance_manifest_selector_preflight "${manifest}" P12 jmeter journey 2>/dev/null; then
  fail "JMeter security journey (an unadvertised extra) was accepted"
fi
if performance_manifest_selector_preflight "${manifest}" P01 jmeter protocol 2>/dev/null; then
  fail "JMeter protocol workload (an unadvertised extra) was accepted"
fi

# C-11. Six Pyroscope types plus diagnose-mode /stacks.
lab_context="${root}/harness/core/lib/lab-context.sh"
for profile_type in cpu wall allocation lock exception live-heap; do
  grep -q "${profile_type}" "${lab_context}" || fail "Pyroscope type ${profile_type} is not handled"
done
stacks_test="${root}/harness/adapters/runtime/dotnet/stacks-staging-test.sh"
capture_test="${root}/harness/adapters/runtime/dotnet/capture-test.sh"
[[ -x "${stacks_test}" && -f "${capture_test}" ]] || fail "C-11 /stacks proofs are missing"
grep -q 'cannot share ICorProfiler with Pyroscope' "${capture_test}" \
  || fail "C-11 must prove /stacks falls back while Pyroscope is loaded"
grep -q 'PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true' "${capture_test}" \
  || fail "C-11 must prove diagnose-mode /stacks captures stacks.txt"
grep -q 'target_mode=remote' "${capture_test}" \
  || fail "C-11 must prove inherited /stacks is refused on a remote target"
grep -q 'preset:hang' "${capture_test}" \
  || fail "C-11 must prove hang /stacks follows the same ownership gate"

echo "advertised labs, k6 profiles, Pyroscope types, and /stacks are qualified"
