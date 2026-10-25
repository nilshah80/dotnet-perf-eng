#!/usr/bin/env bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../../../.." && pwd)"
fail() { echo "capability-test: $*" >&2; exit 1; }
# shellcheck disable=SC1091
PERFLAB_LAB_OPTIONAL=1 source "${root}/harness/core/lib/common.sh"
# shellcheck disable=SC1091
source "${root}/harness/adapters/runtime/dotnet/capability.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-monitor-capability.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
diagnostics_url="http://monitor.invalid"

monitor_curl() {
  local url="${@: -1}"
  case "${url}" in
    */info)
      printf '%s\n' '{"version":"10.0","runtimeVersion":"10.0","diagnosticPortMode":"Listen","diagnosticPortName":"/diag/monitor.sock","capabilities":[{"name":"call_stacks","enabled":true}]}' ;;
    */)
      printf '%s\n' '{"paths":{"/trace":{"get":{}},"/gcdump":{"get":{}},"/dump":{"get":{}},"/stacks":{"get":{}}}}' ;;
    *) return 1 ;;
  esac
}

dotnet_monitor_capability_require "${work}" fixture-uid trace gcdump dump stacks \
  || fail "complete monitor capability report was rejected"
jq -e '.state == "supported" and .targetUid == "fixture-uid" and .requestedCaptures == ["trace","gcdump","dump","stacks"] and .monitor.callStacks == true' \
  "${work}/runtime/capabilities.json" >/dev/null || fail "report omitted verified capabilities"

monitor_curl() {
  local url="${@: -1}"
  case "${url}" in
    */info)
      printf '%s\n' '{"version":"10.0","diagnosticPortMode":"Listen","diagnosticPortName":"/diag/monitor.sock","capabilities":[{"name":"call_stacks","enabled":false}]}' ;;
    */) printf '%s\n' '{"paths":{"/stacks":{"get":{}}}}' ;;
    *) return 1 ;;
  esac
}
if dotnet_monitor_capability_require "${work}" fixture-uid stacks; then
  fail "disabled call_stacks capability was accepted"
fi

monitor_curl() {
  local url="${@: -1}"
  case "${url}" in
    */info) printf '%s\n' '{"version":"10.0","diagnosticPortMode":"Listen","diagnosticPortName":"/diag/monitor.sock","capabilities":[]}' ;;
    */) printf '%s\n' '{"paths":{"/trace":{"get":{}}}}' ;;
    *) return 1 ;;
  esac
}
if dotnet_monitor_capability_require "${work}" fixture-uid dump; then
  fail "missing dump endpoint was accepted"
fi

echo "live monitor capability preflight accepts advertised endpoints and refuses disabled/missing endpoints before capture"
