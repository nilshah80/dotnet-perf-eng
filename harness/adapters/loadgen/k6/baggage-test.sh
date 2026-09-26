#!/usr/bin/env bash
# D-P1-8: every generator puts the request's run and phase on the wire as W3C
# baggage, and never a value the application would reject. A recording HTTP
# server captures the header each generator actually sent: k6 through the lab
# script and baggage.js, wrk through the lab's wrk.lua. Each generator that is
# not installed on this host is skipped loudly rather than passed silently.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
fail() { echo "baggage-test: $*" >&2; exit 1; }
# shellcheck source=/dev/null
. "${repo}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found"

work="$(mktemp -d "${TMPDIR:-/tmp}/baggage-test.XXXXXX")"
server_pid=""
cleanup() { [[ -n "${server_pid}" ]] && kill "${server_pid}" 2>/dev/null; rm -rf "${work}"; }
trap cleanup EXIT HUP INT TERM

cat > "${work}/server.py" <<'EOF'
import http.server, sys
log = open(sys.argv[1], "a", buffering=1)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        log.write((self.headers.get("baggage") or "<none>") + "\n")
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(sys.argv[2], "w").write(str(server.server_address[1]))
server.serve_forever()
EOF
"${PYTHON}" "${work}/server.py" "${work}/headers" "${work}/port" &
server_pid=$!
for _ in $(seq 1 40); do [[ -s "${work}/port" ]] && break; sleep 0.1; done
[[ -s "${work}/port" ]] || fail "the recording server did not start"
base="http://127.0.0.1:$(tr -d '\r\n' < "${work}/port")"

ran=0
if command -v k6 >/dev/null 2>&1; then
  : > "${work}/headers"
  PERF_BASE_URL="${base}" PERF_PATH=/ PERF_RUN_ID=run-11 PERF_PHASE=measure \
    k6 run --quiet --no-color --vus 1 --iterations 2 "${repo}/labs/scenariolab/loadgen/k6.js" > "${work}/k6.out" 2>&1 \
    || { cat "${work}/k6.out" >&2; fail "k6 did not run the lab script"; }
  [[ "$(sort -u "${work}/headers")" == "perf.run.id=run-11,perf.phase=measure" ]] \
    || fail "k6 sent '$(sort -u "${work}/headers" | tr '\n' ' ')' instead of the run and phase"
  : > "${work}/headers"
  PERF_BASE_URL="${base}" PERF_PATH=/ PERF_RUN_ID='run 11;x' PERF_PHASE=hacked \
    k6 run --quiet --no-color --vus 1 --iterations 1 "${repo}/labs/scenariolab/loadgen/k6.js" > "${work}/k6.out" 2>&1 \
    || { cat "${work}/k6.out" >&2; fail "k6 did not run with rejected values"; }
  [[ "$(sort -u "${work}/headers")" == "<none>" ]] || fail "k6 sent values the application would reject: $(cat "${work}/headers")"
  ran=$((ran + 1))
else
  echo "baggage-test: k6 SKIPPED (not installed)" >&2
fi

if command -v wrk >/dev/null 2>&1; then
  : > "${work}/headers"
  PERF_RUN_ID=run-12 PERF_PHASE=warmup wrk -t1 -c1 -d1s -s "${repo}/labs/scenariolab/loadgen/wrk.lua" "${base}/" > "${work}/wrk.out" 2>&1 \
    || { cat "${work}/wrk.out" >&2; fail "wrk did not run the lab script"; }
  [[ "$(sort -u "${work}/headers")" == "perf.run.id=run-12,perf.phase=warmup" ]] \
    || fail "wrk sent '$(sort -u "${work}/headers" | head -3 | tr '\n' ' ')' instead of the run and phase"
  ran=$((ran + 1))
else
  echo "baggage-test: wrk SKIPPED (not installed)" >&2
fi

echo "generator baggage tests passed (${ran} generator(s) exercised)"
