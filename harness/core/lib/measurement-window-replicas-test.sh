#!/usr/bin/env bash
# Per-replica measurement-window attestation. Behind a balancing gateway one probe
# reached one replica, so a restart of the other went unseen. Each named replica
# is now probed (X-Perf-Replica) at both boundaries; a same-name recycle is a
# restart, and a gateway that ignores the header is refused.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "measurement-window-replicas-test: $*" >&2; exit 1; }
# shellcheck source=/dev/null
. "${repo}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found"
work="$(mktemp -d "${TMPDIR:-/tmp}/measurement-window-replicas-test.XXXXXX")"
server_pid=""
trap '[[ -n "${server_pid}" ]] && kill "${server_pid}" 2>/dev/null; rm -rf "${work}"' EXIT HUP INT TERM

# generation.json maps replica -> process start; "ignore" answers as api-a for all.
printf '{"api-a":1000,"api-b":2000}\n' > "${work}/generation.json"
cat > "${work}/server.py" <<'PY'
import http.server, json, sys
state = sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        generation = json.load(open(state + "/generation.json"))
        replica = self.headers.get("X-Perf-Replica", "")
        if generation.get("ignore"):
            replica = "api-a"
        payload = json.dumps({"contractVersion": "perflab-measurement-window-v1", "runId": self.headers["X-Perf-Run-Id"],
            "measurementWindowId": self.headers["X-Perf-Measurement-Window"], "instanceId": replica,
            "processStartedAtUnixMilliseconds": generation[replica]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
"${PYTHON}" "${work}/server.py" "${work}" > "${work}/port" &
server_pid=$!
for _ in $(seq 1 100); do [[ -s "${work}/port" ]] && break; sleep 0.1; done
base="http://127.0.0.1:$(tr -d '\r' < "${work}/port")"

window() { # window <name> <mutation-between-boundaries> -> analysis dir
  mkdir -p "${work}/$1"
  PERFLAB_JQ=host PERFLAB_LAB_OPTIONAL=1 PERFLAB_MEASUREMENT_WINDOW_PROBE_PATH=/window PERFLAB_MEASUREMENT_WINDOW_REPLICAS="api-a api-b" \
    bash -c 'source "$1/harness/core/lib/common.sh"; source "$1/harness/core/lib/performance.sh"
      performance_measurement_window_open "$2" run-1 mw-1 "$3" && eval "$4" && performance_measurement_window_close "$2" run-1 mw-1 "$3"' \
    _ "${repo}" "${base}" "${work}/$1" "$2"
}

window stable true || fail "a stable replica set was refused"
jq -e '.restartDetected == false and .scope == "exact-boundary-replica-set" and ([.replicas[].replica] == ["api-a","api-b"])' \
  "${work}/stable/measurement-window.json" >/dev/null || fail "stable window: $(cat "${work}/stable/measurement-window.json")"

window recycled "printf '{\"api-a\":1000,\"api-b\":3000}\n' > '${work}/generation.json'" || fail "a recycled replica was refused"
jq -e '.restartDetected == true and ([.replicas[] | .restartDetected] == [false, true])' "${work}/recycled/measurement-window.json" >/dev/null \
  || fail "a same-name recycle of api-b was not a restart: $(cat "${work}/recycled/measurement-window.json")"

printf '{"api-a":1000,"api-b":2000,"ignore":true}\n' > "${work}/generation.json"
if window ignored true 2> "${work}/ignored.err"; then fail "a gateway that ignored X-Perf-Replica was attested"; fi
grep -q "did not route by X-Perf-Replica" "${work}/ignored.err" || fail "the refusal does not say why: $(cat "${work}/ignored.err")"

echo "measurement-window replica tests passed"
