#!/usr/bin/env bash
# D-P0-3. /stacks loads monitor shared libraries from /app/shared inside the
# target. Protocol Reliability already staged them; the other three images did
# not, so enabling the flag still produced an empty channel.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../../../.." && pwd)"
fail() { echo "stacks-staging-test: $*" >&2; exit 1; }

images=(
  source/dotnet/protocol-reliability/Dockerfile
  source/dotnet/scenariolab/src/PerfLab.Api/Dockerfile
  source/dotnet/scenariolab/src/PerfLab.Worker/Dockerfile
  source/dotnet/ecommerce/src/ECommerce.Api/Dockerfile
)
for image in "${images[@]}"; do
  path="${root}/${image}"
  [[ -f "${path}" ]] || fail "missing ${image}"
  grep -q 'FROM mcr.microsoft.com/dotnet/monitor:10.0 AS monitor' "${path}" \
    || fail "${image} does not stage the monitor image"
  grep -q 'COPY --from=monitor /app/shared /app/shared' "${path}" \
    || fail "${image} does not copy /app/shared into the target"
done

capture="${root}/harness/adapters/runtime/dotnet/capture.sh"
grep -q 'ICorProfiler' "${capture}" || fail "capture.sh lost the profiler-coexistence rule"
grep -q 'dotnet-stack' "${capture}" || fail "capture.sh must record why dotnet-stack is not used"
! grep -q 'unreliable in this Docker Desktop sidecar topology' "${capture}" \
  || fail "capture.sh still carries the inverted Docker Desktop comment"

runtime="${root}/harness/core/capture/capture-runtime.sh"
grep -q 'PERFLAB_CONTINUOUS_PROFILING=0' "${runtime}" \
  || fail "capture-runtime.sh must recreate with Pyroscope off for /stacks"
grep -q 'unset PERFLAB_ENABLE_DOTNET_MONITOR_STACKS' "${runtime}" \
  || fail "capture-runtime.sh must clear an inherited /stacks flag before remote or attach paths"
grep -q 'PERFLAB_STACKS_FORCE_TRACE=1' "${runtime}" \
  || fail "profiled diagnose stacks must force the documented CPU-trace fallback"
grep -q 'Diagnose-mode gcdump: recreating with PERFLAB_CONTINUOUS_PROFILING=0' "${runtime}" \
  || fail "gcdump diagnostics must recreate owned targets without Pyroscope"
recreate_line="$(grep -n 'force-recreate' "${runtime}" | head -n1 | cut -d: -f1)"
flag_line="$(grep -n 'PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true' "${runtime}" | tail -n1 | cut -d: -f1)"
[[ -n "${recreate_line}" && -n "${flag_line}" && "${flag_line}" -gt "${recreate_line}" ]] \
  || fail "PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true must be set only after a successful owned compose recreate"

echo "dotnet /stacks image staging and coexistence rules passed"
