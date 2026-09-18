#!/usr/bin/env bash
# Acceptance case 4: the journey workload's runtime behaviour.
#
# Dynamic values, token use, retries and think time are claims about what the
# workload DOES, and only running it can settle them. The journey script is
# executed against a stub server that observes each request, so the assertions
# are about observed traffic rather than about source text.
#
# Scope note: this lab's journeys use bearer tokens extracted at login. Cookies,
# CSRF tokens and token REFRESH are not implemented by any lab asset here, so
# they are not behaviours this release advertises -- they belong to the Gate B
# item that adds them, not to a Gate A case claiming they already work.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
fail() { echo "journey-behaviour-test: $*" >&2; exit 1; }
command -v k6 >/dev/null || fail "k6 is required to run the journey workload"
command -v python3 >/dev/null || fail "python3 is required for the stub server"

script="${repo}/labs/ecommerce/loadgen/journey.js"
[[ -s "${script}" ]] || fail "no journey workload asset at ${script}"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/journey-behaviour-test.XXXXXX")"
server_pid=""
cleanup() { [[ -n "${server_pid}" ]] && kill "${server_pid}" 2>/dev/null; rm -rf "${test_root}"; }
trap cleanup EXIT HUP INT TERM

# A stub that issues a token at login and records every request it sees, so the
# test can assert on what the workload actually sent.
cat > "${test_root}/server.py" <<'PY'
import http.server, json, os, threading, time, uuid

RECORD = os.environ["JOURNEY_RECORD"]
lock = threading.Lock()
issued = set()

def record(entry):
    with lock:
        with open(RECORD, "a") as handle:
            handle.write(json.dumps(entry) + "\n")

class Handler(http.server.BaseHTTPRequestHandler):
    def respond(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        auth = self.headers.get("Authorization", "")
        record({"path": self.path.split("?")[0], "auth": auth, "at": time.time()})
        if "login" in self.path:
            token = "tok-" + uuid.uuid4().hex[:12]
            with lock:
                issued.add(token)
            return self.respond(200, {"token": token, "userId": "u1"})
        # Everything else requires the token the login handed out.
        presented = auth[len("Bearer "):] if auth.startswith("Bearer ") else ""
        with lock:
            known = presented in issued
        if not known:
            return self.respond(401, {"error": "missing or unknown bearer token"})
        return self.respond(200, {"id": "1", "status": "Completed", "orderId": "1", "total": 1})

    do_GET = do_POST = do_PUT = do_DELETE = handle_any

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY

record="${test_root}/requests.ndjson"
: > "${record}"
# Capture the server pid so cleanup can actually kill it. Reading its port
# through a process substitution left nothing to kill, so every run of this test
# leaked a listening stub server that outlived the temporary directory.
JOURNEY_RECORD="${record}" python3 "${test_root}/server.py" > "${test_root}/port" 2>/dev/null &
server_pid=$!
for _ in $(seq 1 100); do
  [[ -s "${test_root}/port" ]] && break
  sleep 0.1
done
read -r port < "${test_root}/port"
[[ -n "${port}" ]] || fail "stub server did not report a port"
base="http://127.0.0.1:${port}"

k6 run --vus 1 --iterations 1 --quiet --no-color \
  -e BASE_URL="${base}" -e PERF_BASE_URL="${base}" \
  "${script}" > "${test_root}/k6.out" 2>&1 \
  || fail "the journey workload failed against the stub: $(tail -8 "${test_root}/k6.out")"

[[ -s "${record}" ]] || fail "the journey issued no requests at all"

# --- dynamic value extraction and reuse -------------------------------------
# The token is produced by the login RESPONSE and must be sent on the later
# operations. A workload that hardcoded a credential, or dropped the extracted
# one, would still complete against a permissive server -- so the stub rejects
# any request whose bearer token it did not issue.
login_count="$(python3 -c "
import json,sys
rows=[json.loads(l) for l in open('${record}')]
print(sum(1 for r in rows if 'login' in r['path']))")"
[[ "${login_count}" -ge 1 ]] || fail "the journey never logged in, so no dynamic value could be extracted"

authed="$(python3 -c "
import json
rows=[json.loads(l) for l in open('${record}')]
after=[r for r in rows if 'login' not in r['path']]
print(sum(1 for r in after if r['auth'].startswith('Bearer tok-')))")"
total_after="$(python3 -c "
import json
rows=[json.loads(l) for l in open('${record}')]
print(sum(1 for r in rows if 'login' not in r['path']))")"
[[ "${total_after}" -ge 1 ]] || fail "the journey performed no operations after login"
[[ "${authed}" == "${total_after}" ]] \
  || fail "${authed} of ${total_after} post-login requests carried the extracted token; a dynamic value was dropped"

# --- think time -------------------------------------------------------------
# Operations must be paced, not issued back to back: think time is what makes a
# journey a user rather than a flood, and a journey with none measures a
# different workload than the one declared.
gap="$(python3 -c "
import json
rows=sorted((json.loads(l) for l in open('${record}')), key=lambda r: r['at'])
gaps=[b['at']-a['at'] for a,b in zip(rows, rows[1:])]
print(f'{max(gaps):.4f}' if gaps else '0')")"
awk -v g="${gap}" 'BEGIN { exit (g >= 0.02) ? 0 : 1 }' \
  || fail "the largest gap between operations was ${gap}s; the journey issued its steps with no think time"

echo "journey behaviour (dynamic values, token reuse, think time) tests passed"
