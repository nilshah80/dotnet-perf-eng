#!/usr/bin/env bash
# Fault injection under load: run a scenario while a dependency is faulted for a
# window in the middle of the measured run -- pause (a transient outage where
# in-flight connections stall) or stop (a hard failure). Answers how the app
# behaves, and whether it recovers, when a dependency slows or fails. Reuses
# run-scenario and injects the fault via Docker pause/stop during the measure
# phase (no proxy, no app change). Pick a scenario that actually uses the faulted
# dependency (e.g. any DB scenario for --dependency postgres).
#
#   run-fault.sh <scenario> [duration] [--dependency postgres|redis|rabbitmq]
#                [--kind pause|stop] [--at N] [--for N] [--profile P]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
require_loadgen
# Local-only: fault injection pauses/stops OWNED compose dependencies, which a
# remote target does not have (and must never be attempted against).
[[ "${target_mode:-local}" == "local" ]] || { echo "run-fault.sh needs a local target (PERFLAB_TARGET=local): it pauses/stops OWNED compose dependencies. A remote target has none to fault." >&2; exit 1; }

scenario_id="${1:?run-fault.sh <scenario> [duration] [--dependency D] [--kind pause|stop] [--at N] [--for N]}"; shift
require_scenario "${scenario_id}"
duration="30"
if [[ $# -gt 0 && "${1}" != --* ]]; then duration="$1"; shift; fi
[[ "${duration}" =~ ^[1-9][0-9]*$ ]] || { echo "duration must be a positive integer." >&2; exit 1; }

dep="${PERFLAB_PG_SERVICE:-postgres}"
kind="pause"
at="$(( duration / 4 > 0 ? duration / 4 : 1 ))"
for_s="$(( duration / 3 > 0 ? duration / 3 : 1 ))"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dependency) dep="${2:?}"; shift 2 ;;
    --kind) kind="${2:?}"; shift 2 ;;
    --at) at="${2:?}"; shift 2 ;;
    --for) for_s="${2:?}"; shift 2 ;;
    --profile) export PERFLAB_PROFILE="${2:?}"; shift 2 ;;
    *) echo "Unknown option '$1'." >&2; exit 1 ;;
  esac
done
[[ "${kind}" == "pause" || "${kind}" == "stop" ]] || { echo "--kind must be 'pause' or 'stop'." >&2; exit 1; }
[[ "${at}" =~ ^[0-9]+$ && "${for_s}" =~ ^[1-9][0-9]*$ ]] || { echo "--at/--for must be whole seconds." >&2; exit 1; }
# The fault must land inside the measured window, else it fires during the
# post-load cooldown/capture (or never) and measures nothing. Validate against the
# EFFECTIVE run length: a profile can stretch (soak) or shrink (ramp) the measure
# phase, so use the profile just parsed from --profile, not the requested duration.
fault_profile="${PERFLAB_PROFILE:-steady}"
effective_duration="${duration}"
if [[ "${load_generator}" == "k6" && "${fault_profile}" != "steady" ]]; then
  # shellcheck disable=SC1090
  source "$(loadgen_dir)/profiles.sh"
  effective_duration="$(k6_profile_effective_duration "${fault_profile}" "$(scenario_value "${scenario_id}" connections)" "${duration}")"
fi
[[ $(( at + for_s )) -le effective_duration ]] || {
  echo "--at (${at}s) + --for (${for_s}s) = $(( at + for_s ))s exceeds the ${effective_duration}s run (profile ${fault_profile}); the fault window must fit inside it." >&2; exit 1; }
# The dependency must be a compose service this lab actually runs.
case " ${dependencies} ${app_services} " in
  *" ${dep} "*) : ;;
  *) echo "Dependency '${dep}' is not a service in this lab (have: ${dependencies} ${app_services})." >&2; exit 1 ;;
esac

export PERFLAB_FAULT_DEP="${dep}" PERFLAB_FAULT_KIND="${kind}" PERFLAB_FAULT_AT="${at}" PERFLAB_FAULT_FOR="${for_s}"
echo "Fault run: ${kind} '${dep}' at +${at}s for ${for_s}s during a ${duration}s ${scenario_id} run (profile ${PERFLAB_PROFILE:-steady})"
echo "Expect an error/latency spike during the outage; health:\"degraded\" if it exceeds the error threshold, then recovery."
exec "${harness_core_dir}/run/run-scenario.sh" "${scenario_id}" "${duration}"
