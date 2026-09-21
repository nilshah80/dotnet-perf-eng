#!/usr/bin/env bash
# Target ownership and exclusive diagnostic leases (C-5).
#
# The harness previously knew only "local" and "remote", and a local target was
# assumed to be OWNED: capture-runtime.sh runs `compose up -d --force-recreate`
# before a diagnostic so the process starts clean. That is correct for a lab
# stack this run created, and destructive for anything else -- pointed at a
# shared box it restarts an API somebody else is using, and the first sign is
# their traffic failing.
#
# Ownership is therefore explicit and conservative: a target is owned only when
# this run is declared to have created it. Everything else is attached to and
# left alone. "I am not sure" resolves to "do not touch it".
#
#   PERFLAB_TARGET_KIND:
#     managed-compose    (default) this run owns the compose project: recreate,
#                        reset and clean up are allowed.
#     existing-process   attach to a process this run did not start.
#     existing-container attach to a container this run did not start.
#     existing-environment  a deployment this run does not own at all (remote).
#
# A diagnostic also needs EXCLUSIVITY. Two runs capturing the same process at
# once produce two EventPipe sessions, two sets of overhead, and two traces each
# attributing the other's perturbation to the application. The lease makes that
# a refusal instead of a silently wrong pair of measurements.

target_kind="${PERFLAB_TARGET_KIND:-managed-compose}"
case "${target_kind}" in
  managed-compose|existing-process|existing-container|existing-environment) ;;
  *)
    echo "Unknown PERFLAB_TARGET_KIND '${target_kind}'. Use managed-compose, existing-process, existing-container, or existing-environment." >&2
    exit 1
    ;;
esac

# A remote target is never owned, whatever the kind says.
if [[ "${target_mode:-local}" == "remote" ]]; then
  target_kind="existing-environment"
fi

case "${target_kind}" in
  managed-compose) target_owned=1 ;;
  *)               target_owned=0 ;;
esac
export PERFLAB_TARGET_KIND="${target_kind}"

# require_target_ownership <operation>
# Refuses a lifecycle operation on a target this run did not create. The message
# names the operation and the kind so the refusal is actionable rather than a
# bare "not allowed".
require_target_ownership() {
  local operation="${1:?operation required}"
  if [[ "${target_owned}" == "1" ]]; then
    return 0
  fi
  echo "Refusing to ${operation}: PERFLAB_TARGET_KIND='${target_kind}' means this run did not create the target." >&2
  echo "  Attach-only kinds never stop, restart or reset a process somebody else owns." >&2
  echo "  Use PERFLAB_TARGET_KIND=managed-compose only when this harness brought the stack up." >&2
  return 1
}

# Exclusive diagnostic lease, keyed on the thing being diagnosed rather than on
# the run: two different runs targeting the same process must still collide. The
# lease directory is created atomically (mkdir succeeds for exactly one caller),
# which needs no lock daemon and survives a kill -9 as a stale directory the
# next caller can diagnose from its recorded pid.
target_lease_dir=""
acquire_diagnostic_lease() { # acquire_diagnostic_lease <target-identity>
  local identity="${1:?target identity required}" holder=""
  local key
  key="$(printf '%s' "${identity}" | tr -c 'A-Za-z0-9._-' '_')"
  target_lease_dir="${TMPDIR:-/tmp}/perflab-diagnostic-lease-${key}"
  if mkdir "${target_lease_dir}" 2>/dev/null; then
    printf '%s\n' "$$" > "${target_lease_dir}/pid"
    printf '%s\n' "${PERF_RUN_ID:-unknown}" > "${target_lease_dir}/run"
    return 0
  fi
  holder="$(cat "${target_lease_dir}/pid" 2>/dev/null || echo unknown)"
  # A lease whose holder is gone is stale, not held. Reclaiming it is safe
  # because the holder cannot still be capturing.
  if [[ "${holder}" != "unknown" ]] && ! kill -0 "${holder}" 2>/dev/null; then
    echo "Reclaiming a stale diagnostic lease from pid ${holder} (process is gone)." >&2
    rm -rf "${target_lease_dir}"
    if mkdir "${target_lease_dir}" 2>/dev/null; then
      printf '%s\n' "$$" > "${target_lease_dir}/pid"
      printf '%s\n' "${PERF_RUN_ID:-unknown}" > "${target_lease_dir}/run"
      return 0
    fi
  fi
  echo "Another diagnostic already holds ${identity} (pid ${holder}, run $(cat "${target_lease_dir}/run" 2>/dev/null || echo unknown))." >&2
  echo "  Two concurrent captures give the same process two EventPipe sessions, and each trace then records the other's overhead as application cost." >&2
  return 1
}

release_diagnostic_lease() {
  [[ -n "${target_lease_dir}" && -d "${target_lease_dir}" ]] || return 0
  # Only the holder may release it, or a crashed run's cleanup would free a
  # lease another run has since legitimately acquired.
  if [[ "$(cat "${target_lease_dir}/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "${target_lease_dir}"
  fi
  target_lease_dir=""
}
