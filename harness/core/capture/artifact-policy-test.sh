#!/usr/bin/env bash
# Acceptance case 45: artifacts satisfy sensitivity and retention limits.
#
# Two separate promises, and both have to be enforced rather than documented:
#
#   SENSITIVITY -- a process dump contains whatever was in memory: connection
#   strings, tokens, customer rows. It is the single most disclosive artifact
#   the harness can produce, so it requires an explicit acknowledgement. A
#   default-on dump would put that in an evidence package somebody attaches to
#   a ticket.
#
#   RETENTION -- a diagnostic campaign writes traces, heap dumps and process
#   dumps, and their combined size is bounded. Without a budget a "quick
#   diagnostic" can fill a disk, and the run that does it is the one nobody was
#   watching.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "artifact-policy-test: $*" >&2; exit 1; }
test_root="$(mktemp -d "${TMPDIR:-/tmp}/artifact-policy-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT HUP INT TERM

# --- sensitivity: a process dump is refused without acknowledgement ---------
pkg="${test_root}/pkg"
mkdir -p "${pkg}"
printf '{"runId":"run-policy","scenarioId":"S01","target":"local"}\n' > "${pkg}/manifest.json"

set +e
out="$(PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh" \
  bash "${repo}/harness/core/capture/capture-runtime.sh" "${pkg}" dump 5 2>&1)"
rc=$?
set -e
[[ "${rc}" != 0 ]] || fail "a process dump was captured with no sensitivity acknowledgement"
printf '%s' "${out}" | grep -q 'PERFLAB_DUMP_ACK' \
  || fail "the refusal does not name the acknowledgement that unlocks it: ${out}"
printf '%s' "${out}" | grep -qi 'secrets\|personal data' \
  || fail "the refusal does not say WHY a dump is sensitive, so an operator will set the flag without understanding it: ${out}"

# The acknowledgement must be exact. A truthy-looking value is not consent.
for wrong in yes true 1 i-understand; do
  set +e
  out="$(PERFLAB_DUMP_ACK="${wrong}" PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh" \
    bash "${repo}/harness/core/capture/capture-runtime.sh" "${pkg}" dump 5 2>&1)"
  rc=$?
  set -e
  [[ "${rc}" != 0 ]] || fail "PERFLAB_DUMP_ACK='${wrong}' was accepted as an acknowledgement"
done

# --- retention: the campaign budget is enforced, not advisory ---------------
capture="${repo}/harness/adapters/runtime/dotnet/capture.sh"
grep -q 'PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES' "${capture}" \
  || fail "the runtime campaign has no artifact budget"
# The budget must be ENFORCED, not merely counted. Incrementing a failure count
# and leaving the oversized artifacts in place is not a limit: the disk is
# already full and the files are already in the package somebody will attach to
# a ticket.
grep -qE 'runtime_bytes > budget_bytes' "${capture}" \
  || fail "the artifact budget is recorded but never compared against actual bytes"
grep -q 'rm -f "${oversized_file}"' "${capture}" \
  || fail "exceeding the budget removes nothing; the limit is advisory"
grep -q 'artifact-budget.json' "${capture}" \
  || fail "artifacts are dropped without recording which ones, so the package is silently incomplete"

# A direct dump is the largest artifact this harness produces. It had no free
# space check at all, so the capture most able to fill a disk was the least
# protected.
runtime_entry="${repo}/harness/core/capture/capture-runtime.sh"
grep -q 'Insufficient free disk for the ${direct_budget}-byte' "${runtime_entry}" \
  || fail "a direct (non-campaign) capture has no disk-space budget"

# A pre-flight free-space check is a guess: the dump is produced by the target
# and its size is unknown until it arrives. The DOWNLOAD itself has to be
# bounded, and the artifact discarded if it exceeds the budget -- otherwise the
# oversized file is already written by the time anyone counts it.
grep -q -- '--max-filesize' "${capture}" \
  || fail "diagnostic downloads are unbounded; the budget cannot be enforced mid-transfer"
grep -q 'exceeding the ${budget}-byte budget; it was discarded' "${capture}" \
  || fail "an oversized direct artifact is left in the package rather than discarded"

# And the default must be finite. An unbounded default is the same as no budget.
default_budget="$(grep -oE 'PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES:-[0-9]+' "${capture}" | head -1 | cut -d- -f2-)"
default_budget="${default_budget#-}"
[[ "${default_budget}" =~ ^[0-9]+$ && "${default_budget}" -gt 0 ]] \
  || fail "the artifact budget has no finite default (${default_budget:-unset})"

# --- retention: evidence query budgets are finite too ----------------------
# Logs and traces are the unbounded signals: a saturated window can return
# millions of records, and "capture everything" is how a package becomes
# unreadable and undistributable.
context="${repo}/harness/core/lib/lab-context.sh"
for limit in PERFLAB_LOG_LIMIT PERFLAB_TRACE_LIMIT; do
  grep -q "${limit}" "${context}" \
    || fail "${limit} has no default; the evidence budget would be unbounded"
done
grep -q 'observability_result_max' "${context}" \
  || fail "there is no ceiling on the configurable evidence limits"

echo "artifact policy (dump acknowledgement, retention budgets) tests passed"
