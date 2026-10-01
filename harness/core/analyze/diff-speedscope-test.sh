#!/usr/bin/env bash
# On-CPU attribution of dotnet-trace Speedscope profiles. dotnet-trace ends each
# stack in a pseudo-frame -- CPU_TIME when managed code ran, UNMANAGED_CODE_TIME
# otherwise (idle threads parked in native waits included). Ranking the leaf as-is
# read S05 as 87% UNMANAGED_CODE_TIME, 13% CPU_TIME and 0% for every method, and a
# CPU diff compared pseudo-frames.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "diff-speedscope-test: $*" >&2; exit 1; }
# shellcheck source=/dev/null
. "${repo}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found"
work="$(mktemp -d "${TMPDIR:-/tmp}/diff-speedscope-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM

# profile <out> <json-weight> <parse-weight>: the grouping roots, a request thread
# spending <json> ms in a JSON method and <parse> ms in a parser (both CPU_TIME),
# plus a thread idle for 900 ms in a native wait (UNMANAGED_CODE_TIME).
profile() {
  "${PYTHON}" - "$@" <<'PY'
import json, sys
out, json_ms, parse_ms = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
frames = ["Process64 App (1)", "(Non-Activities)", "Threads", "Thread (7)", "App!Handle", "Json!Write",
          "Json!Parse", "CPU_TIME", "Thread (8) (.NET ThreadPool)", "CoreLib!WaitHandle.Wait", "UNMANAGED_CODE_TIME"]
def events(stack_ms):
    at, out = 0.0, []
    for stack, ms in stack_ms:
        for f in stack: out.append({"type": "O", "frame": f, "at": at})
        at += ms
        for f in reversed(stack): out.append({"type": "C", "frame": f, "at": at})
    return out, at
busy, end_busy = events([([0, 1, 2, 3, 4, 5, 7], json_ms), ([0, 1, 2, 3, 4, 6, 7], parse_ms)])
idle, end_idle = events([([0, 1, 2, 8, 9, 10], 900.0)])
json.dump({"shared": {"frames": [{"name": n} for n in frames]}, "profiles": [
    {"type": "evented", "startValue": 0, "endValue": end_busy, "events": busy},
    {"type": "evented", "startValue": 0, "endValue": end_idle, "events": idle}]}, open(out, "w"))
PY
}
profile "${work}/base.json" 60 40
profile "${work}/cand.json" 90 10

report="$("${PYTHON}" "${repo}/harness/core/analyze/diff-speedscope.py" --report "${work}/base.json" --top 5)"
grep -q 'on-CPU weight 100.0 of 1000.0 total thread time (10.0%)' <<< "${report}" || fail "on-CPU share is wrong:\n${report}"
awk '/by self/,/^$/' <<< "${report}" | grep -Eq '60\.00% +Json!Write' || fail "the self ranking does not attribute CPU_TIME to its frame:\n${report}"
awk '/by inclusive/,/^$/' <<< "${report}" | grep -Eq '100\.00% +App!Handle' || fail "inclusive time is wrong:\n${report}"
grep -E '^ +[0-9]' <<< "${report}" | grep -Eq '_TIME|Threads|Process64|Thread \(|WaitHandle' \
  && fail "a pseudo-frame, grouping root or idle wait was ranked:\n${report}"

diff="$("${PYTHON}" "${repo}/harness/core/analyze/diff-speedscope.py" "${work}/base.json" "${work}/cand.json" --top 3)"
awk '/HOTTER/,/^$/' <<< "${diff}" | grep -Eq '\+30\.00% +60\.00% -> +90\.00% +Json!Write' \
  || fail "the diff does not compare methods by on-CPU share:\n${diff}"
grep -E '^ +[+-]' <<< "${diff}" | grep -q '_TIME' && fail "the diff compared pseudo-frames:\n${diff}"

echo "diff-speedscope tests passed"
