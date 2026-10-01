#!/usr/bin/env bash
# D-P1-6. External backends use secret-backed headers, CA, and optional mTLS.
# Values stay in the environment; artifacts record handles only.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
fail() { echo "backend-auth-test: $*" >&2; exit 1; }

common="${root}/harness/core/lib/common.sh"
context="${root}/harness/core/lib/lab-context.sh"
[[ -f "${common}" && -f "${context}" ]] || fail "auth helpers are missing"
grep -q 'Authorization: ${PERFLAB_BACKEND_AUTHORIZATION}' "${common}" \
  || fail "backend_curl must send the secret-backed Authorization header"
grep -q -- '--cacert "${PERFLAB_BACKEND_CA_FILE}"' "${common}" \
  || fail "backend_curl must accept a CA file"
grep -q -- '--cert "${PERFLAB_BACKEND_CLIENT_CERT}" --key "${PERFLAB_BACKEND_CLIENT_KEY}"' "${common}" \
  || fail "backend_curl must accept an mTLS client certificate"
grep -q 'Authorization: ${PERFLAB_MONITOR_AUTHORIZATION}' "${common}" \
  || fail "monitor_curl must send the secret-backed Authorization header"
grep -q 'values are never written to artifacts' "${context}" \
  || fail "lab-context.sh must refuse unauthenticated external backends"
! grep -q 'INSECURE=1' "${context}" \
  || fail "remote backend admission must not retain an insecure bypass"
grep -q 'backend_curl -fsS --max-time 10 --max-filesize 1048576' "${context}" \
  || fail "profiler verification must use backend_curl, not a raw curl bypass"
grep -q 'require_remote_endpoint_auth "external telemetry backends"' "${context}" \
  || fail "telemetry admission must be independent of monitor credentials"
grep -q 'require_remote_endpoint_auth "remote diagnostics"' "${context}" \
  || fail "monitor admission must be independent of backend credentials"

work="$(mktemp -d "${TMPDIR:-/tmp}/backend-auth.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"
cat > "${work}/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${PERFLAB_TEST_CURL_ARGS}"
EOF
chmod +x "${work}/bin/curl"
export PATH="${work}/bin:${PATH}"
export PERFLAB_LAB_OPTIONAL=1
export PERFLAB_BACKEND_AUTHORIZATION='Bearer never-write-this-to-artifacts'
export PERFLAB_TEST_CURL_ARGS="${work}/curl-args"
# shellcheck disable=SC1091
source "${common}"
backend_curl -fsS http://127.0.0.1:9 >/dev/null || true
grep -q 'Authorization: Bearer never-write-this-to-artifacts' "${work}/curl-args" \
  || fail "backend_curl did not send the Authorization header"
! grep -q 'never-write-this-to-artifacts' "${root}/harness/core/capture/capture-evidence.sh" \
  || fail "capture-evidence.sh must not hardcode backend tokens"

echo "backend and monitor authentication helpers passed"
