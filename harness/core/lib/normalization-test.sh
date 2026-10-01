#!/usr/bin/env bash
# The merge that carries a single-kind dump's extended SOS failure into the
# package normalization record: this is the record for that path, and the
# adapter test only proves the adapter wrote the limitations file.
set -euo pipefail
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
jqd() { MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
# shellcheck source=/dev/null
. "${lib}/normalization.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "normalization-test: $*" >&2; exit 1; }

record="${tmp}/normalization.json"
printf '{"startedAt":"2026-09-25T10:00:00Z","completedAt":"2026-09-25T10:00:05Z","status":"captured"}\n' > "${record}"

# 1. No limitations file: the record is untouched.
normalization_merge_limitations "${record}" "${tmp}/absent.json" || fail "an absent limitations file must be a no-op"
jq -e 'has("limitations") | not' "${record}" >/dev/null || fail "an absent file added limitations"

# 2. A recorded limitation lands in the record with the status preserved.
printf '["runtime/api/process.dmp: extended SOS commands (dumpasync, syncblk, analyzeoom) failed; the thread and heap listing is retained"]\n' > "${tmp}/limitations.json"
normalization_merge_limitations "${record}" "${tmp}/limitations.json" || fail "a valid limitations file was refused"
jq -e '.status == "captured" and (.limitations | length) == 1 and (.limitations[0] | test("extended SOS commands"))' "${record}" >/dev/null \
  || fail "the limitation was not merged: $(cat "${record}")"
[[ ! -e "${record}.tmp" ]] || fail "a temporary record was left behind"

# 3. A malformed file is refused, keeps what the record had, and marks the
#    record as carrying an unmerged limitation rather than reading as clean.
printf '{"not":"an array"}\n' > "${tmp}/bad.json"
if normalization_merge_limitations "${record}" "${tmp}/bad.json" 2>/dev/null; then
  fail "a malformed limitations file was accepted"
fi
jq -e '.status == "captured" and (.limitations | length) == 2 and (.limitations[0] | test("extended SOS")) and (.limitations[1] | test("malformed"))' "${record}" >/dev/null \
  || fail "a refused merge must keep the record and note the malformed file: $(cat "${record}")"
[[ ! -e "${record}.tmp" ]] || fail "a refused merge left a temporary record behind"

echo "normalization merge tests passed"
