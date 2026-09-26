#!/usr/bin/env bash
# The harness login for protected labs. JMeter and wrk used to send no token at
# all, so every request to a JWT-protected lab was an HTTP 401: the run "passed"
# and measured nothing. One harness login now hands the token to every generator.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "workload-login-test: $*" >&2; exit 1; }
# shellcheck source=/dev/null
. "${repo}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found"
command -v jq >/dev/null || fail "jq is required"

work="$(mktemp -d "${TMPDIR:-/tmp}/workload-login-test.XXXXXX")"
server_pid=""
trap '[[ -n "${server_pid}" ]] && kill "${server_pid}" 2>/dev/null; rm -rf "${work}"' EXIT HUP INT TERM

cat > "${work}/server.py" <<'PY'
import http.server, json, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        ok = self.path == "/api/auth/login" and body == {"username": "user1", "password": "Pa\"ss"}
        payload = json.dumps({"token": "eyJhbGciOi.test.token"} if ok else {"error": "invalid"}).encode()
        self.send_response(200 if ok else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def do_GET(self):
        payload = json.dumps({"authorization": self.headers.get("Authorization", "")}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
"${PYTHON}" "${work}/server.py" > "${work}/port" &
server_pid=$!
for _ in $(seq 1 100); do [[ -s "${work}/port" ]] && break; sleep 0.1; done
base="http://127.0.0.1:$(tr -d '\r' < "${work}/port")"

login() { # login <password> [PERF_HEADERS] -> prints PERF_HEADERS, or fails
  PERFLAB_JQ=host PERFLAB_CONFIG="${repo}/labs/ecommerce/lab.config.sh" PERF_LOGIN_USER=user1 PERF_LOGIN_PASSWORD="$1" \
    PERF_HEADERS="${2:-}" bash -c 'source "$1/harness/core/lib/common.sh"; source "$1/harness/core/lib/performance.sh"
      performance_workload_login "$2" && printf "%s" "${PERF_HEADERS}"' _ "${repo}" "${base}"
}

headers="$(login 'Pa"ss' '{"X-Tenant":"t1"}' 2>/dev/null)" || fail "a valid login failed"
jq -e '.Authorization == "Bearer eyJhbGciOi.test.token" and .["X-Tenant"] == "t1"' <<< "${headers}" >/dev/null \
  || fail "the token was not merged into PERF_HEADERS: ${headers}"

# The token reaches the target through target_curl's header file descriptor.
echoed="$(PERFLAB_JQ=host PERFLAB_LAB_OPTIONAL=1 PERF_HEADERS="${headers}" bash -c 'source "$1/harness/core/lib/common.sh"; target_curl -fsS "$2/echo"' _ "${repo}" "${base}")"
jq -e '.authorization == "Bearer eyJhbGciOi.test.token"' <<< "${echoed}" >/dev/null || fail "target_curl did not send the minted header: ${echoed}"

supplied='{"Authorization":"Bearer operator"}'
[[ "$(login wrong "${supplied}" 2>/dev/null)" == "${supplied}" ]] \
  || fail "an operator-supplied token was replaced or a login attempted"

if login wrong > "${work}/refused.out" 2> "${work}/refused.err"; then
  fail "a rejected login was accepted"
fi
grep -q 'login at /api/auth/login failed (HTTP 401)' "${work}/refused.err" \
  || fail "a rejected login did not say why: $(cat "${work}/refused.err")"

# The credentials never leave the target origin through the path.
for path in '@evil.example/x' '//evil.example/x' 'api/auth'; do
  if PERFLAB_JQ=host PERFLAB_LAB_OPTIONAL=1 PERFLAB_LOGIN_PATH="${path}" PERF_LOGIN_USER=user1 PERF_LOGIN_PASSWORD=x bash -c \
      'source "$1/harness/core/lib/common.sh"; source "$1/harness/core/lib/performance.sh"; performance_workload_login "$2"' _ "${repo}" "${base}" 2>/dev/null; then
    fail "login path '${path}' was accepted"
  fi
done

# A lab without a declared login is untouched.
unchanged="$(PERFLAB_JQ=host PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh" PERF_HEADERS="" bash -c \
  'source "$1/harness/core/lib/common.sh"; source "$1/harness/core/lib/performance.sh"; performance_workload_login "$2"; printf "%s" "${PERF_HEADERS:-}"' _ "${repo}" "${base}")"
[[ -z "${unchanged}" ]] || fail "a lab without PERFLAB_LOGIN_PATH was given headers: ${unchanged}"

echo "workload login tests passed"
