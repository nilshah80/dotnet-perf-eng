#!/usr/bin/env bash
# D-P0-6. The post-incident path is a real dotnet-monitor CollectionRules
# configuration, not metadata named "collection rules". The live monitor image
# only loads this JSON after the explicit acknowledgement and a managed
# diagnose-mode recreation; its filesystem egress is a 512 MiB tmpfs.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../../../.." && pwd)"
fail() { echo "collection-rules-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

rules="${root}/harness/adapters/runtime/dotnet/monitor/collection-rules.json"
[[ -f "${rules}" ]] || fail "missing collection-rules document"

jq -e '
  .Egress.FileSystem.perflabCrashDumps.DirectoryPath == "/diag/collection-rule-dumps" and
  .Egress.FileSystem.perflabCrashDumps.IntermediateDirectoryPath == "/diag/collection-rule-dumps/incomplete" and
  .CollectionRules.PerflabCrashDump.Trigger.Type == "AspNetRequestCount" and
  .CollectionRules.PerflabCrashDump.Trigger.Settings.RequestCount == 1 and
  .CollectionRules.PerflabCrashDump.Actions[0].Type == "CollectDump" and
  .CollectionRules.PerflabCrashDump.Actions[0].Settings.Type == "Triage" and
  .CollectionRules.PerflabCrashDump.Actions[0].Settings.Egress == "perflabCrashDumps" and
  .CollectionRules.PerflabCrashDump.Limits.ActionCount == 1 and
  .CollectionRules.PerflabCrashDump.Limits.ActionCountSlidingWindowDuration == "01:00:00"
' "${rules}" >/dev/null || fail "CollectionRules config must have one bounded Triage CollectDump action and filesystem egress"

entrypoint="${root}/harness/adapters/runtime/dotnet/monitor/monitor-entrypoint.sh"
grep -q 'PERFLAB_COLLECTION_RULES:-0.*= "1"' "${entrypoint}" || fail "entrypoint must require PERFLAB_COLLECTION_RULES=1"
grep -q 'PERFLAB_DUMP_ACK.*i-understand-sensitive-dump' "${entrypoint}" || fail "entrypoint must require the dump acknowledgement"
grep -q 'PERF_RUN_MODE.*diagnose' "${entrypoint}" || fail "entrypoint must require diagnose mode"
grep -q 'PERFLAB_TARGET_KIND.*managed-compose' "${entrypoint}" || fail "entrypoint must require managed Compose ownership"
grep -q -- '--configuration-file-path /opt/perflab/collection-rules.json' "${entrypoint}" || fail "entrypoint must load the real rules JSON when armed"

runtime="${root}/harness/core/capture/capture-runtime.sh"
grep -q 'PERFLAB_COLLECTION_RULES' "${runtime}" || fail "capture-runtime.sh must arm collection rules only when acknowledged"
grep -q 'collection-rule-dumps' "${runtime}" || fail "capture-runtime.sh must collect the monitor rule egress"
grep -q 'collectionrules' "${runtime}" || fail "capture-runtime.sh must verify the live monitor rule state"
grep -q 'owned target' "${runtime}" || fail "capture-runtime.sh must refuse collection rules on a remote target"
grep -q 'performance_crash_dump_collect_path_from' "${runtime}" || fail "capture-runtime.sh must collect rule dumps with a bounded source-side copy"
grep -q 'performance_crash_dump_enforce_source' "${root}/harness/core/lib/performance.sh" || fail "performance.sh must prune oversize and extra dumps in the source volume before copy"
grep -q 'performance_crash_dump_purge_source' "${root}/harness/core/lib/performance.sh" || fail "performance.sh must delete createdump files from the source volume after copy"
grep -q 'compose run --rm --no-deps' "${root}/harness/core/lib/performance.sh" || fail "stopped dump sources must be reachable with compose run"
grep -q 'Failed to copy or purge dotnet-monitor CollectionRules egress' "${runtime}" || fail "capture-runtime.sh must fail when rule-egress copy or purge fails"
if grep -q 'compose cp' "${runtime}"; then
  fail "unbounded compose cp of crash dumps is still present"
fi
capture="${root}/harness/adapters/runtime/dotnet/capture.sh"
grep -q 'head -c' "${capture}" || fail "capture.sh must bound diagnostic downloads with a limit+1 stream"
grep -q 'performance_stream_copy_limit' "${capture}" || fail "capture.sh must use a bounded streaming writer"

for compose in \
  "${root}/labs/scenariolab/compose.yaml" \
  "${root}/labs/ecommerce/compose.yaml" \
  "${root}/labs/protocol-reliability/compose.yaml"
do
  grep -q 'harness/adapters/runtime/dotnet/monitor' "${compose}" \
    || fail "${compose} does not use the gated monitor image"
  grep -q 'PERFLAB_COLLECTION_RULES' "${compose}" \
    || fail "${compose} does not pass the opt-in to the monitor"
  grep -q '/diag/collection-rule-dumps:size=536870912' "${compose}" \
    || fail "${compose} does not provision the 512 MiB bounded egress tmpfs"
done

# shellcheck disable=SC1091
source "${root}/harness/core/lib/performance.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/collection-rules.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/dumps"
dd if=/dev/zero of="${work}/dumps/coredump.1" bs=1024 count=2 >/dev/null 2>&1
dd if=/dev/zero of="${work}/dumps/coredump.2" bs=512 count=1 >/dev/null 2>&1
dd if=/dev/zero of="${work}/dumps/coredump.3" bs=512 count=1 >/dev/null 2>&1
PERFLAB_CRASH_DUMP_MAX_BYTES=1024 performance_crash_dump_enforce "${work}/dumps"
[[ ! -f "${work}/dumps/coredump.1" ]] || fail "oversize createdump was retained"
[[ -f "${work}/dumps/coredump.2" ]] || fail "in-budget dump was discarded"
[[ ! -f "${work}/dumps/coredump.3" ]] || fail "second dump in the window was retained"

printf 'abcd' | performance_stream_copy_limit "${work}/bounded.ok" 4 || fail "in-budget bounded copy failed"
[[ "$(wc -c < "${work}/bounded.ok" | tr -d ' ')" == "4" ]] || fail "bounded copy truncated an in-budget body"
if printf 'abcde' | performance_stream_copy_limit "${work}/bounded.over" 4; then
  fail "bounded copy accepted an oversize body"
fi
[[ ! -e "${work}/bounded.over" && ! -e "${work}/bounded.over.tmp" ]] || fail "oversize bounded copy left bytes on disk"

fake_dumps="${work}/container-diag/crash-dumps"
mkdir -p "${fake_dumps}"
dd if=/dev/zero of="${fake_dumps}/coredump.1" bs=1024 count=2 >/dev/null 2>&1
dd if=/dev/zero of="${fake_dumps}/coredump.2" bs=512 count=1 >/dev/null 2>&1
dd if=/dev/zero of="${fake_dumps}/coredump.3" bs=512 count=1 >/dev/null 2>&1
compose() {
  local script="" previous=""
  for argument in "$@"; do
    [[ "${previous}" == "-c" ]] && script="${argument}"
    previous="${argument}"
  done
  [[ -n "${script}" ]] || { echo "compose mock missing -c: $*" >&2; return 1; }
  script="${script//\/diag\/crash-dumps/${fake_dumps}}"
  script="${script//\/diag\/collection-rule-dumps/${fake_dumps}}"
  sh -c "${script}"
}
PERFLAB_CRASH_DUMP_MAX_BYTES=1024 performance_crash_dump_enforce_source api \
  || fail "source-side dump enforcement failed on a running container"
[[ ! -f "${fake_dumps}/coredump.1" ]] || fail "oversize source dump was copied instead of pruned"
[[ -f "${fake_dumps}/coredump.2" ]] || fail "in-budget source dump was pruned"
[[ ! -f "${fake_dumps}/coredump.3" ]] || fail "second source dump in the window was retained"

dd if=/dev/zero of="${fake_dumps}/coredump.2" bs=512 count=1 >/dev/null 2>&1
collect_dest="${work}/collected"
PERFLAB_CRASH_DUMP_MAX_BYTES=1024 performance_crash_dump_collect_path_from api /diag/collection-rule-dumps "${collect_dest}" \
  || fail "bounded monitor rule dump collect failed"
[[ -f "${collect_dest}/coredump.2" ]] || fail "in-budget dump was not copied"
[[ ! -f "${fake_dumps}/coredump.2" ]] || fail "source dump survived after confirmed purge"
[[ "$(wc -c < "${collect_dest}/coredump.2" | tr -d ' ')" == "512" ]] || fail "bounded collect truncated an in-budget dump"

compose() {
  if [[ "$1" == "exec" ]]; then
    return 1
  fi
  local script="" previous=""
  for argument in "$@"; do
    [[ "${previous}" == "-c" ]] && script="${argument}"
    previous="${argument}"
  done
  [[ -n "${script}" ]] || { echo "compose mock missing -c: $*" >&2; return 1; }
  script="${script//\/diag\/crash-dumps/${fake_dumps}}"
  script="${script//\/diag\/collection-rule-dumps/${fake_dumps}}"
  sh -c "${script}"
}
dd if=/dev/zero of="${fake_dumps}/coredump.4" bs=512 count=1 >/dev/null 2>&1
PERFLAB_CRASH_DUMP_MAX_BYTES=1024 performance_crash_dump_purge_source api \
  || fail "stopped-container dump purge via compose run failed"
[[ ! -f "${fake_dumps}/coredump.4" ]] || fail "stopped-container source dump survived purge"

echo "real dotnet-monitor CollectionRules Triage config, bounded source egress, source purge, and dump acknowledgement passed"
