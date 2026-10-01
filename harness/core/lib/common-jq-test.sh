#!/usr/bin/env bash
# Test the actual jqd implementation with native-style output and jq 1.6 flags.
set -euo pipefail
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
export REAL_JQ="$(command -v jq)"
export JQ_CALL_LOG="${tmp}/calls"
mkdir -p "${tmp}/bin"
cat > "${tmp}/bin/jq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${MSYS_NO_PATHCONV:-unset}" >> "${JQ_CALL_LOG}"
for arg in "$@"; do
  [[ "${arg}" != -b ]] || { echo 'jq 1.6: unknown option -b' >&2; exit 2; }
done
"${REAL_JQ}" "$@" | awk '{printf "%s\r\n", $0}'
STUB
cat > "${tmp}/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Consume run --rm -i image; use the same jq to compare both modes.
shift 4
exec jq "$@"
STUB
cat > "${tmp}/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${JQ_TEST_PLATFORM}"
STUB
chmod +x "${tmp}/bin/"*
export PATH="${tmp}/bin:${PATH}"
unset PERFLAB_CONFIG PERFLAB_LAB MSYS_NO_PATHCONV
export PERFLAB_LAB_OPTIONAL=1
for platform in Linux MINGW64_NT-10.0; do
  for mode in host docker; do
    : > "${JQ_CALL_LOG}"
    JQ_TEST_PLATFORM="${platform}" PERFLAB_JQ="${mode}" bash -s -- "${lib}/common.sh" <<'CASE' \
      || { echo "jqd ${mode}/${platform} case failed" >&2; exit 1; }
set -euo pipefail
# Name the assertion that failed; set -e alone exits without saying which.
trap 'echo "failed: ${BASH_COMMAND}" >&2' ERR
source "$1"
[[ "$(jqd -nr --arg path /stacks '$path')" == /stacks ]]
[[ "$(jqd -nr '"a\rb"')" == ab ]]
[[ "$(printf '{"value":42}' | jqd -r '.value')" == 42 ]]
rc=0
jqd -ne false >/dev/null || rc=$?
[[ "${rc}" == 1 ]]
rc=0
printf '{invalid' | jqd . >/dev/null 2>&1 || rc=$?
[[ "${rc}" != 0 ]]
CASE
    [[ -s "${JQ_CALL_LOG}" ]] || { echo 'jq was never called' >&2; exit 1; }
    if grep -v '^1$' "${JQ_CALL_LOG}"; then
      echo "wrong path conversion guard for ${mode}/${platform}" >&2; exit 1
    fi
  done
done
if JQ_TEST_PLATFORM=Linux PERFLAB_JQ=invalid bash -c 'source "$1"' _ "${lib}/common.sh" > "${tmp}/invalid" 2>&1; then
  echo 'invalid jq mode passed' >&2; exit 1
fi
grep -q "PERFLAB_JQ must be" "${tmp}/invalid"
echo 'jqd compatibility tests passed'
