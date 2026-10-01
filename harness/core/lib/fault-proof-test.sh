#!/usr/bin/env bash
# C-7 / C-8. Fault apply/restore must be recorded from observed container state.
# Kill is an advertised hard failure; pause/stop remain. Network/disk stay deferred.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
fail() { echo "fault-proof-test: $*" >&2; exit 1; }

run="${root}/harness/core/run/run-scenario.sh"
fault="${root}/harness/core/pe-tests/run-fault.sh"
grep -q 'fault-proof.json' "${run}" || fail "run-scenario.sh must write apply/restore proof"
grep -q 'compose kill' "${run}" || fail "run-scenario.sh must implement kill"
grep -q 'performance_fault_state_applied' "${run}" || fail "inject_fault must observe applied container state"
grep -q 'windowHeld' "${run}" || fail "run-scenario.sh must record whether the fault window held"
grep -q 'appliedAt' "${run}" || fail "run-scenario.sh must record fault timestamps"
grep -q 'performance_compose_service_id' "${run}" || fail "run-scenario.sh must record container identity"
grep -q 'pause|stop|kill' "${fault}" || fail "run-fault.sh must accept kill"

# shellcheck disable=SC1091
source "${root}/harness/core/lib/performance.sh"
performance_fault_state_applied pause paused || fail "pause applied state was refused"
performance_fault_state_applied kill exited || fail "kill applied state was refused"
performance_fault_state_restored running || fail "running restore state was refused"
if performance_fault_state_applied pause running 2>/dev/null; then
  fail "a still-running container was accepted as a pause"
fi
if performance_fault_state_restored paused 2>/dev/null; then
  fail "a paused container was accepted as restored"
fi

compose() {
  local has_all=0
  for argument in "$@"; do
    [[ "${argument}" == "--all" ]] && has_all=1
  done
  if [[ "${has_all}" != "1" ]]; then
    return 0
  fi
  if [[ " $* " == *" '{{.State}}' "* || " $* " == *" {{.State}} "* ]]; then
    printf 'exited\n'
    return 0
  fi
  if [[ " $* " == *" '{{.ID}}' "* || " $* " == *" {{.ID}} "* ]]; then
    printf 'deadcontainer\n'
    return 0
  fi
  return 0
}
state="$(performance_compose_service_state api)"
[[ "${state}" == "exited" ]] || fail "compose ps without --all omits exited containers; observer returned '${state:-empty}'"
id="$(performance_compose_service_id api)"
[[ "${id}" == "deadcontainer" ]] || fail "compose ps without --all omitted the stopped container id"

echo "fault apply/restore proof and kill action passed"
