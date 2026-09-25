#!/usr/bin/env bash
# Target ownership and diagnostic lease tests.
#
# capture-runtime.sh runs `compose up -d --force-recreate` before a diagnostic.
# That is correct for a stack this run brought up and destructive for anything
# else -- pointed at a shared host it restarts an API somebody else is using,
# and the first sign is their traffic failing. So the interesting cases here are
# all the REFUSALS: a guard that only ever says yes is indistinguishable from no
# guard at all.
set -euo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The lease signal cases need a SIGINT the lease holder can trap.
# shellcheck source=/dev/null
. "${lib_dir}/sigint-reset.sh"
reset_inherited_sigint "$@"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/target-lifecycle-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT HUP INT TERM
fail() { echo "target-lifecycle-test: $*" >&2; exit 1; }

# --- ownership -------------------------------------------------------------

# ownership_rc <kind> <target-mode> -> exit code of require_target_ownership
ownership_rc() {
  local out
  out="$(
    PERFLAB_TARGET_KIND="$1" bash -c '
      target_mode="'"$2"'"
      source "'"${lib_dir}"'/target-lifecycle.sh"
      require_target_ownership "restart the application stack" 2>&1
      echo "rc=$?"
    '
  )"
  printf '%s' "${out}"
}

result="$(ownership_rc managed-compose local)"
[[ "${result}" == "rc=0" ]] || fail "a stack this run created must be operable, got: ${result}"

for kind in existing-process existing-container existing-environment; do
  result="$(ownership_rc "${kind}" local)"
  [[ "${result}" == *"rc=1" ]] || fail "${kind} must refuse a lifecycle operation, got: ${result}"
  [[ "${result}" == *"restart the application stack"* ]] \
    || fail "${kind} refusal must name the operation it refused, got: ${result}"
  [[ "${result}" == *"${kind}"* ]] || fail "${kind} refusal must name the kind, got: ${result}"
done

# A remote target is never owned, whatever the kind claims. Trusting the kind
# here would let a stray environment variable authorise recreating a deployment
# in another environment entirely.
result="$(ownership_rc managed-compose remote)"
[[ "${result}" == *"rc=1" ]] || fail "a remote target must never be owned, got: ${result}"
[[ "${result}" == *"existing-environment"* ]] \
  || fail "a remote target must report itself as existing-environment, got: ${result}"

# An unrecognised kind is a typo, and a typo must not silently fall back to the
# permissive default.
set +e
unknown="$(PERFLAB_TARGET_KIND=managed_compose bash -c '
  target_mode=local; source "'"${lib_dir}"'/target-lifecycle.sh"' 2>&1)"
unknown_rc=$?
set -e
[[ "${unknown_rc}" != 0 ]] || fail "a misspelled PERFLAB_TARGET_KIND was accepted"
[[ "${unknown}" == *"managed-compose"* ]] || fail "the error must list the valid kinds, got: ${unknown}"

# --- exclusive diagnostic lease -------------------------------------------

# Two runs capturing one process open two EventPipe sessions, and each trace
# then records the other's overhead as application cost. The lease turns that
# into a refusal instead of two quietly wrong measurements.
lease_env() { PERFLAB_TARGET_KIND=managed-compose TMPDIR="${test_root}" bash "$@"; }

held="$(lease_env -c '
  target_mode=local; source "'"${lib_dir}"'/target-lifecycle.sh"
  acquire_diagnostic_lease "svc-api@uid-1" || exit 9
  # A second acquire from a LIVE holder must be refused, not granted.
  if acquire_diagnostic_lease "svc-api@uid-1" 2>/dev/null; then echo "double-acquire"; exit 0; fi
  echo "refused"
' 2>/dev/null)"
[[ "${held}" == "refused" ]] || fail "a held lease was granted twice (${held})"

# Different targets do not contend: the lease is keyed on the thing diagnosed,
# not on the harness, so two runs against two services proceed in parallel.
other="$(lease_env -c '
  target_mode=local; source "'"${lib_dir}"'/target-lifecycle.sh"
  acquire_diagnostic_lease "svc-api@uid-1" || exit 9
  acquire_diagnostic_lease "svc-worker@uid-2" || { echo "contended"; exit 0; }
  echo "independent"
' 2>/dev/null)"
[[ "${other}" == "independent" ]] || fail "unrelated targets contended for one lease (${other})"

# A lease whose holder was killed is stale, not held. Without reclaim, one
# kill -9 wedges the target until somebody deletes a directory by hand.
stale_dir="${test_root}/perflab-diagnostic-lease-svc-api_uid-3"
mkdir -p "${stale_dir}"
printf '2147483647\n' > "${stale_dir}/pid"   # a pid that cannot be running
printf 'run-crashed\n' > "${stale_dir}/run"
reclaimed="$(lease_env -c '
  target_mode=local; source "'"${lib_dir}"'/target-lifecycle.sh"
  acquire_diagnostic_lease "svc-api@uid-3" && echo "reclaimed"
' 2>/dev/null)"
[[ "${reclaimed}" == "reclaimed" ]] || fail "a lease from a dead process was treated as held"

# Release is holder-only. A crashed run's cleanup must not free a lease that a
# later run has since legitimately taken.
foreign_dir="${test_root}/perflab-diagnostic-lease-svc-api_uid-4"
mkdir -p "${foreign_dir}"
printf '2147483647\n' > "${foreign_dir}/pid"
lease_env -c '
  target_mode=local; source "'"${lib_dir}"'/target-lifecycle.sh"
  target_lease_dir="'"${foreign_dir}"'"
  release_diagnostic_lease
' >/dev/null 2>&1
[[ -d "${foreign_dir}" ]] || fail "release_diagnostic_lease freed a lease held by another process"

# A signal must END a capture that holds the lease, not only free the lease. The
# old trap released it and let the capture carry on post-processing without it,
# exiting 0, so a cancelled diagnostic read as a finished one. The holder runs as
# a job with its own process group, like a terminal job, and is signalled the way
# Ctrl-C signals one. It is started directly rather than through lease_env: a
# backgrounded function wrapper would be what receives the signal and exits.
signal_dir="${test_root}/perflab-diagnostic-lease-svc-api_uid-5"
for signal in INT TERM; do
  continued="${test_root}/lease-${signal}-continued"
  set -m
  PERFLAB_TARGET_KIND=managed-compose TMPDIR="${test_root}" bash -c '
    target_mode=local; source "'"${lib_dir}"'/target-lifecycle.sh"
    acquire_diagnostic_lease "svc-api@uid-5" || exit 9
    arm_diagnostic_lease_release
    sleep 30
    : > "'"${continued}"'"
  ' </dev/null >/dev/null 2>&1 &
  holder_pid=$!
  set +m
  for _ in $(seq 1 100); do
    [[ -f "${signal_dir}/pid" ]] && break
    sleep 0.1
  done
  if [[ ! -f "${signal_dir}/pid" ]]; then
    kill -KILL -- "-${holder_pid}" 2>/dev/null || true
    fail "the ${signal} lease holder never acquired its lease"
  fi
  kill -"${signal}" -- "-${holder_pid}"
  holder_rc=0
  wait "${holder_pid}" || holder_rc=$?
  expected_rc=130
  [[ "${signal}" == INT ]] || expected_rc=143
  [[ "${holder_rc}" == "${expected_rc}" ]] \
    || fail "${signal} ended the lease holder with ${holder_rc}, expected ${expected_rc}"
  [[ ! -d "${signal_dir}" ]] || fail "${signal} did not release the diagnostic lease"
  [[ ! -e "${continued}" ]] || fail "the capture kept running after ${signal} released its lease"
done
grep -qx 'arm_diagnostic_lease_release' "$(dirname "${lib_dir}")/capture/capture-runtime.sh" \
  || fail "capture-runtime.sh must arm the signal-safe lease release"

# --- attach-only measurement (the capability, not just the refusal) ---------

# A guard that only ever says no is not a feature. C-5 asks for existing local
# processes and containers to be MEASURABLE; before this, every local target
# entered the Compose path and then failed the ownership check, so the kinds
# could be declared and never used. Acceptance case 17 -- measure an existing
# local process without deploying or terminating it -- depends on this split.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${lib_dir}")" && pwd)/lib/performance.sh"

for kind in existing-process existing-container; do
  for action in measure attach diagnose; do
    performance_target_preflight "${kind}" attach "${action}" 2>/dev/null \
      || fail "${kind} refused ${action}; attach-only measurement is impossible"
  done
  for action in deploy start stop reset recreate; do
    if performance_target_preflight "${kind}" attach "${action}" 2>/dev/null; then
      fail "${kind} allowed ${action} on a target this run did not create"
    fi
  done
done

# The managed kind must still require ownership, or the split above would have
# quietly widened what a Compose target may do.
performance_target_preflight managed-compose managed deploy 2>/dev/null \
  || fail "a managed Compose target was refused its own deploy"
if performance_target_preflight managed-compose attach deploy 2>/dev/null; then
  fail "a Compose deploy was allowed without lifecycle ownership"
fi

echo "target lifecycle ownership and lease tests passed"
