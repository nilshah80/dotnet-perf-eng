#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/arch.sh"

fail() { echo "entrypoint-test: $*" >&2; exit 1; }

[[ "$(pyroscope_glibc_arch amd64)" == "x86_64" ]] || fail "amd64 mapping"
[[ "$(pyroscope_glibc_arch x86_64)" == "x86_64" ]] || fail "x86_64 mapping"
[[ "$(pyroscope_glibc_arch arm64)" == "aarch64" ]] || fail "arm64 mapping"
[[ "$(pyroscope_glibc_arch aarch64)" == "aarch64" ]] || fail "aarch64 mapping"
if pyroscope_glibc_arch ppc64le >/dev/null 2>&1; then
  fail "ppc64le must be rejected"
fi

wrapper="${here}/entrypoint.sh"
[[ -x "${wrapper}" ]] || fail "entrypoint is not executable"

canonical="$(cd "${here}/../../../../.." && pwd)/harness/adapters/runtime/dotnet/pyroscope/entrypoint.sh"
scenariolab="$(cd "${here}/../../../../.." && pwd)/source/dotnet/scenariolab/docker/pyroscope-entrypoint.sh"
ecommerce="$(cd "${here}/../../../../.." && pwd)/source/dotnet/ecommerce/docker/pyroscope-entrypoint.sh"
diff -q "${wrapper}" "${scenariolab}" >/dev/null || fail "scenariolab entrypoint drifted from canonical"
diff -q "${wrapper}" "${ecommerce}" >/dev/null || fail "ecommerce entrypoint drifted from canonical"

disabled_env="$(
  env -i PATH="${PATH}" PERFLAB_CONTINUOUS_PROFILING=0 \
    "${wrapper}" /usr/bin/env
)"
printf '%s\n' "${disabled_env}" | grep -q '^CORECLR_ENABLE_PROFILING=' && fail "disabled path exported CORECLR_ENABLE_PROFILING"
printf '%s\n' "${disabled_env}" | grep -q '^LD_PRELOAD=' && fail "disabled path exported LD_PRELOAD"
printf '%s\n' "${disabled_env}" | grep -q '^PYROSCOPE_PROFILING_ENABLED=' && fail "disabled path exported PYROSCOPE_PROFILING_ENABLED"
printf '%s\n' "${disabled_env}" | grep -q '^DD_INTERNAL_PROFILING_ENABLED_ARM64=' && fail "disabled path exported ARM64 profiler gate"
printf '%s\n' "${disabled_env}" | grep -q '^DD_PROFILING_' && fail "disabled path exported Datadog profiler settings"
printf '%s\n' "${disabled_env}" | grep -q '^DOTNET_TieredCompilation=' && fail "disabled path must not touch tiered compilation"

if env -i PATH="${PATH}" PERFLAB_CONTINUOUS_PROFILING=maybe "${wrapper}" /usr/bin/true 2>/dev/null; then
  fail "invalid boolean was accepted"
fi

enabled_env="$(
  env -i PATH="${PATH}" \
    PERFLAB_CONTINUOUS_PROFILING=1 \
    PERFLAB_PROFILING_MIN_CORES_THRESHOLD=0.1 \
    PERFLAB_PROFILING_EFFECTIVE_CPU_CORES=0.75 \
    PYROSCOPE_SERVER_ADDRESS=http://lgtm:4040 \
    PYROSCOPE_APPLICATION_NAME=perflab-api \
    PERF_RUN_ID=s01-run \
    PERF_SCENARIO=S01 \
    PERF_RUN_MODE=measure \
    OTEL_SERVICE_VERSION=lab \
    "${wrapper}" /usr/bin/env
)"
for required in \
  'CORECLR_ENABLE_PROFILING=1' \
  'CORECLR_PROFILER={BD1A650D-AC5D-4896-B64F-D6FA25D6B26A}' \
  'CORECLR_PROFILER_PATH=/opt/pyroscope/Pyroscope.Profiler.Native.so' \
  'LD_PRELOAD=/opt/pyroscope/Pyroscope.Linux.ApiWrapper.x64.so' \
  'LD_LIBRARY_PATH=/opt/pyroscope' \
  'PYROSCOPE_PROFILING_ENABLED=1' \
  'PYROSCOPE_PROFILING_CPU_ENABLED=true' \
  'PYROSCOPE_SERVER_ADDRESS=http://lgtm:4040' \
  'PYROSCOPE_APPLICATION_NAME=perflab-api' \
  'PYROSCOPE_PROFILING_LOG_DIR=/opt/pyroscope/logs' \
  'DD_PROFILING_MIN_CORES_THRESHOLD=0.1' \
  'DD_PROFILING_UPLOAD_PERIOD=10'
do
  printf '%s\n' "${enabled_env}" | grep -Fxq "${required}" || fail "missing ${required}"
done
printf '%s\n' "${enabled_env}" | grep -q 'PYROSCOPE_LABELS=.*perf_run_id:s01-run' || fail "perf_run_id label"
printf '%s\n' "${enabled_env}" | grep -q 'PYROSCOPE_LABELS=.*perf_scenario:S01' || fail "perf_scenario label"
printf '%s\n' "${enabled_env}" | grep -q 'PYROSCOPE_LABELS=.*service_version:lab' || fail "service_version label"
printf '%s\n' "${enabled_env}" | grep -q 'PYROSCOPE_LABELS=.*service_name:' && fail "service_name must come from PYROSCOPE_APPLICATION_NAME, not duplicated in labels"
printf '%s\n' "${enabled_env}" | grep -q 'perf_phase:' && fail "static perf_phase label must not be set"
printf '%s\n' "${enabled_env}" | grep -q 'PYROSCOPE_PROFILING_ALLOCATION_ENABLED=true' && fail "allocation profiling must stay off"
printf '%s\n' "${enabled_env}" | grep -q 'PYROSCOPE_PROFILING_HEAP_ENABLED=true' && fail "heap profiling must stay off"

all_env="$(
  env -i PATH="${PATH}" PERFLAB_CONTINUOUS_PROFILING=1 \
    PERFLAB_PROFILING_TYPES=cpu,wall,allocation,lock,exception,live-heap \
    PERFLAB_PROFILING_MIN_CORES_THRESHOLD=0.1 PERFLAB_PROFILING_EFFECTIVE_CPU_CORES=0.75 \
    PYROSCOPE_SERVER_ADDRESS=http://lgtm:4040 PYROSCOPE_APPLICATION_NAME=perflab-api \
    "${wrapper}" /usr/bin/env
)"
for enabled_flag in \
  PYROSCOPE_PROFILING_CPU_ENABLED=true \
  PYROSCOPE_PROFILING_WALLTIME_ENABLED=true \
  PYROSCOPE_PROFILING_ALLOCATION_ENABLED=true \
  PYROSCOPE_PROFILING_LOCK_ENABLED=true \
  PYROSCOPE_PROFILING_EXCEPTION_ENABLED=true \
  PYROSCOPE_PROFILING_HEAP_ENABLED=true
do
  printf '%s\n' "${all_env}" | grep -Fxq "${enabled_flag}" || fail "missing ${enabled_flag}"
done
if env -i PATH="${PATH}" PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_PROFILING_TYPES=cpu,unknown \
    PERFLAB_PROFILING_MIN_CORES_THRESHOLD=0.1 PERFLAB_PROFILING_EFFECTIVE_CPU_CORES=0.75 \
    PYROSCOPE_SERVER_ADDRESS=http://lgtm:4040 PYROSCOPE_APPLICATION_NAME=perflab-api \
    "${wrapper}" /usr/bin/true 2>/dev/null; then
  fail "unknown profile type was accepted"
fi
host_arch="$(uname -m)"
case "${host_arch}" in
  aarch64|arm64)
    printf '%s\n' "${enabled_env}" | grep -Fxq 'DD_INTERNAL_PROFILING_ENABLED_ARM64=1' \
      || fail "ARM64 enabled path must set DD_INTERNAL_PROFILING_ENABLED_ARM64=1"
    printf '%s\n' "${enabled_env}" | grep -Fxq 'DOTNET_TieredCompilation=0' \
      || fail "ARM64 enabled path must disable tiered compilation (unsupported arm64 build loses re-jitted frames)"
    printf '%s\n' "${enabled_env}" | grep -q 'PYROSCOPE_LABELS=.*dotnet_tiered_compilation:0' || fail "tiering label"
    keep_env="$(env -i PATH="${PATH}" PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_PROFILING_KEEP_TIERING=1 \
      PERFLAB_PROFILING_MIN_CORES_THRESHOLD=0.1 PERFLAB_PROFILING_EFFECTIVE_CPU_CORES=0.75 \
      PYROSCOPE_SERVER_ADDRESS=http://lgtm:4040 PYROSCOPE_APPLICATION_NAME=perflab-api "${wrapper}" /usr/bin/env)"
    printf '%s\n' "${keep_env}" | grep -q '^DOTNET_TieredCompilation=' && fail "PERFLAB_PROFILING_KEEP_TIERING=1 must leave tiering alone"
    printf '%s\n' "${keep_env}" | grep -q 'dotnet_tiered_compilation:1' || fail "keep-tiering label"
    ;;
  *)
    printf '%s\n' "${enabled_env}" | grep -q '^DD_INTERNAL_PROFILING_ENABLED_ARM64=' \
      && fail "x86_64 enabled path must not set ARM64 profiler gate"
    printf '%s\n' "${enabled_env}" | grep -q '^DOTNET_TieredCompilation=' \
      && fail "x86_64 enabled path must not change tiered compilation"
    printf '%s\n' "${enabled_env}" | grep -q 'dotnet_tiered_compilation:1' || fail "tiering label on x86_64"
    ;;
esac

if env -i PATH="${PATH}" PERFLAB_CONTINUOUS_PROFILING=1 PYROSCOPE_SERVER_ADDRESS=http://lgtm:4040 \
    PERFLAB_PROFILING_MIN_CORES_THRESHOLD=0.1 PERFLAB_PROFILING_EFFECTIVE_CPU_CORES=0.75 \
    PYROSCOPE_APPLICATION_NAME=perflab-api PERF_RUN_ID='bad:value' \
    "${wrapper}" /usr/bin/true 2>/dev/null; then
  fail "colon in a label value was accepted"
fi

if env -i PATH="${PATH}" PERFLAB_CONTINUOUS_PROFILING=1 \
    PERFLAB_PROFILING_MIN_CORES_THRESHOLD=0.8 PERFLAB_PROFILING_EFFECTIVE_CPU_CORES=0.75 \
    PYROSCOPE_SERVER_ADDRESS=http://lgtm:4040 PYROSCOPE_APPLICATION_NAME=perflab-api \
    "${wrapper}" /usr/bin/true 2>/dev/null; then
  fail "threshold above the effective quota was accepted"
fi

echo "entrypoint tests passed"
