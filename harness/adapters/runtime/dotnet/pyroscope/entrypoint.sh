#!/bin/sh
# Opt-in Pyroscope .NET profiler wrapper. When continuous profiling is off,
# the application is exec'd with no CLR profiler or LD_PRELOAD activation.
set -eu

parse_bool() {
  case "$(printf '%s' "${1:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    0|false|no|off|"") return 1 ;;
    *)
      echo "PERFLAB_CONTINUOUS_PROFILING must be 1/true or 0/false; received '$1'." >&2
      exit 1
      ;;
  esac
}

append_label() {
  key="$1"
  val="$2"
  [ -n "${val}" ] || return 0
  case "${val}" in
    *:*|*,*|*" "*|*\|*)
      echo "invalid Pyroscope label value for ${key} (must be a bounded token without colon, comma, pipe, or space)." >&2
      exit 1
      ;;
  esac
  if [ -n "${PYROSCOPE_LABELS}" ]; then
    PYROSCOPE_LABELS="${PYROSCOPE_LABELS},"
  fi
  PYROSCOPE_LABELS="${PYROSCOPE_LABELS}${key}:${val}"
}

if parse_bool "${PERFLAB_CONTINUOUS_PROFILING:-0}"; then
  : "${PYROSCOPE_SERVER_ADDRESS:?PYROSCOPE_SERVER_ADDRESS is required when continuous profiling is enabled}"
  : "${PYROSCOPE_APPLICATION_NAME:?PYROSCOPE_APPLICATION_NAME is required when continuous profiling is enabled}"

  export CORECLR_ENABLE_PROFILING=1
  export CORECLR_PROFILER="{BD1A650D-AC5D-4896-B64F-D6FA25D6B26A}"
  export CORECLR_PROFILER_PATH="/opt/pyroscope/Pyroscope.Profiler.Native.so"
  export LD_PRELOAD="/opt/pyroscope/Pyroscope.Linux.ApiWrapper.x64.so"
  if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    export LD_LIBRARY_PATH="/opt/pyroscope:${LD_LIBRARY_PATH}"
  else
    export LD_LIBRARY_PATH="/opt/pyroscope"
  fi
  profile_types="${PERFLAB_PROFILING_TYPES:-cpu}"
  export PYROSCOPE_PROFILING_ENABLED=1
  export PYROSCOPE_PROFILING_CPU_ENABLED=false
  export PYROSCOPE_PROFILING_WALLTIME_ENABLED=false
  export PYROSCOPE_PROFILING_ALLOCATION_ENABLED=false
  export PYROSCOPE_PROFILING_LOCK_ENABLED=false
  export PYROSCOPE_PROFILING_EXCEPTION_ENABLED=false
  export PYROSCOPE_PROFILING_HEAP_ENABLED=false
  selected=0
  old_ifs="${IFS}"
  IFS=','
  for profile_type in ${profile_types}; do
    case "${profile_type}" in
      cpu) export PYROSCOPE_PROFILING_CPU_ENABLED=true ;;
      wall) export PYROSCOPE_PROFILING_WALLTIME_ENABLED=true ;;
      allocation) export PYROSCOPE_PROFILING_ALLOCATION_ENABLED=true ;;
      lock) export PYROSCOPE_PROFILING_LOCK_ENABLED=true ;;
      exception) export PYROSCOPE_PROFILING_EXCEPTION_ENABLED=true ;;
      live-heap) export PYROSCOPE_PROFILING_HEAP_ENABLED=true ;;
      *)
        echo "unsupported Pyroscope profile type '${profile_type}' in PERFLAB_PROFILING_TYPES." >&2
        exit 1
        ;;
    esac
    selected=$((selected + 1))
  done
  IFS="${old_ifs}"
  [ "${selected}" -gt 0 ] || { echo "PERFLAB_PROFILING_TYPES must select at least one type." >&2; exit 1; }
  export PERFLAB_PROFILING_TYPES="${profile_types}"
  export PYROSCOPE_PROFILING_LOG_DIR="${PYROSCOPE_PROFILING_LOG_DIR:-/opt/pyroscope/logs}"
  export PYROSCOPE_SERVER_ADDRESS
  export PYROSCOPE_APPLICATION_NAME
  # grafana/pyroscope-dotnet 1.5.1 still inherits Datadog's ARM64 gate. Official
  # docs advertise aarch64 glibc builds; without this flag the native profiler
  # loads then immediately disables itself ("Continuous Profiler is not enabled
  # for ARM64 architecture").
  tiered_compilation="${DOTNET_TieredCompilation:-1}"
  case "$(uname -m)" in
    aarch64|arm64)
      export DD_INTERNAL_PROFILING_ENABLED_ARM64=1
      # Live-verified on aarch64: the unsupported arm64 build resolves frames of
      # first-JIT and ReadyToRun code but loses every frame once a method is
      # re-jitted by tiered compilation, so flame graphs collapse to
      # Unknown-Type.Unknown-Method ~20-30s after start. Disabling tiering is
      # the only known way to keep arm64 profiles attributable. It changes JIT
      # behavior, which is one more reason profiling-on runs are never compared
      # with profiling-off runs. Opt out with PERFLAB_PROFILING_KEEP_TIERING=1.
      case "$(printf '%s' "${PERFLAB_PROFILING_KEEP_TIERING:-0}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) : ;;
        *) tiered_compilation=0; export DOTNET_TieredCompilation=0 ;;
      esac
      ;;
  esac
  # pyroscope-dotnet uses this inherited internal setting for its CPU gate. The
  # orchestrator validates the provider range and each service quota first.
  threshold="${PERFLAB_PROFILING_MIN_CORES_THRESHOLD:?required when continuous profiling is enabled}"
  effective_cores="${PERFLAB_PROFILING_EFFECTIVE_CPU_CORES:?required when continuous profiling is enabled}"
  if ! awk -v threshold="${threshold}" -v effective="${effective_cores}" 'BEGIN {
    exit !(threshold >= 0.1 && threshold <= 1 && effective > 0 && threshold <= effective)
  }'; then
    echo "invalid profiling CPU threshold/quota: threshold=${threshold} effective=${effective_cores}" >&2
    exit 1
  fi
  export DD_PROFILING_MIN_CORES_THRESHOLD="${threshold}"
  # Each upload is stored by Pyroscope at ONE timestamp. The inherited 60s
  # period puts at most one point inside a 30s measurement window (often none),
  # so exact-window queries miss active processes. 10s matches the 10s query
  # resolution and keeps window-scoped evidence deterministic.
  export DD_PROFILING_UPLOAD_PERIOD="${DD_PROFILING_UPLOAD_PERIOD:-10}"

  PYROSCOPE_LABELS=""
  append_label perf_run_id "${PERF_RUN_ID:-}"
  append_label perf_scenario "${PERF_SCENARIO:-}"
  append_label perf_run_mode "${PERF_RUN_MODE:-}"
  # pyroscope-dotnet 1.5.1 already labels the Push series with
  # service_name=PYROSCOPE_APPLICATION_NAME. Repeating that key here makes
  # Grafana Pyroscope v2 reject the upload with HTTP 400 (duplicate label).
  append_label service_version "${OTEL_SERVICE_VERSION:-${PYROSCOPE_SERVICE_VERSION:-lab}}"
  # Bounded runtime-shape label so a profile self-describes the JIT mode it
  # was captured under (see the aarch64 note above).
  append_label dotnet_tiered_compilation "${tiered_compilation}"
  export PYROSCOPE_LABELS
fi

exec "$@"
