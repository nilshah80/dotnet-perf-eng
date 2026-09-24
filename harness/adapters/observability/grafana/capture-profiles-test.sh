#!/usr/bin/env bash
set -euo pipefail

adapter="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/capture-profiles.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

fail() { echo "capture-profiles-test: $*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$(dirname "${adapter}")/../../../core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found (tried python3, python)"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

if command -v jq >/dev/null 2>&1; then
  # Delegates to the host jq so the selector under test is the real one, but it
  # must keep BOTH guards common.sh's jqd applies. jq.exe writes CRLF on Windows,
  # so a value read through a bare override carries a trailing CR that corrupts
  # every later comparison and URL built from it; and MSYS rewrites any argument
  # that looks like a POSIX path, so `--arg path /stacks` reaches jq.exe as
  # C:/Program Files/Git/stacks and the lookup silently misses.
  jqd() { MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
else
  echo "capture-profiles-test requires jq" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${adapter}"

populated="$("${PYTHON}" -c 'import json; names=["total","Unknown-Type.Unknown-Method"]+["Frame%d"%i for i in range(40)]; print(json.dumps({"flamebearer":{"names":names,"levels":[[0,10,2,1]],"numTicks":10},"metadata":{"units":"nanoseconds","sampleRate":100}}))')"
empty='{"flamebearer":{"names":[],"levels":[]},"metadata":{"units":"nanoseconds"}}'
truncated="$("${PYTHON}" -c 'import json; names=["n%d"%i for i in range(16384)]; print(json.dumps({"flamebearer":{"names":names,"levels":[[0,1,1,0]]},"metadata":{"units":"nanoseconds"}}))')"
malformed='{"not":"a-profile"'

# Fake curl. mode: ok (HTTP 200 + body), down (connection refused), or an HTTP
# status such as 500 (reachable, body returned, non-2xx). Honors -o/-w like the
# adapter's real invocation and answers the /ready probe consistently.
install_curl() {
  local dir="$1" mode="$2" body="$3"
  mkdir -p "${dir}"
  cat > "${dir}/curl" <<CURL
#!/usr/bin/env bash
set -euo pipefail
mode="${mode}"
payload=$(printf '%q' "${body}")
out=""; want_code=0; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) want_code=1; shift 2 ;;
    --data-urlencode|--max-time) shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
if [[ "\${mode}" == "down" ]]; then exit 7; fi
if [[ "\${url}" == */ready ]]; then exit 0; fi
code=200; [[ "\${mode}" != "ok" ]] && code="\${mode}"
if [[ -n "\${out}" ]]; then printf '%s\n' "\${payload}" > "\${out}"; else printf '%s\n' "\${payload}"; fi
if [[ "\${want_code}" == 1 ]]; then printf '%s' "\${code}"; fi
if [[ "\${code}" != 2* ]]; then exit 22; fi
CURL
  chmod +x "${dir}/curl"
}

run_case() {
  local name="$1" expect="$2" code="$3" body="$4"
  local artifact bin
  artifact="${test_root}/${name}"
  bin="${test_root}/bin-${name}"
  mkdir -p "${artifact}"
  install_curl "${bin}" "${code}" "${body}"
  PATH="${bin}:${PATH}" \
  artifact_dir="${artifact}" \
  continuous_profiling=1 \
  capture_telemetry=1 \
  pyroscope_url="http://127.0.0.1:4040" \
  pyroscope_services="perflab-api" \
  pyroscope_required_services="perflab-api" \
  start_epoch=1 \
  end_epoch=30 \
  telemetry_run_id="run-1" \
  target_mode="local" \
  PYROSCOPE_CAPTURE_ATTEMPTS=1 \
  PYROSCOPE_CAPTURE_SLEEP=0 \
    pyroscope_capture_profiles
  grep -q "\"captureState\":\"${expect}\"" "${artifact}/telemetry/profiles-signal.json" \
    || { echo "${name}: expected ${expect}" >&2; cat "${artifact}/telemetry/profiles-signal.json" >&2; exit 1; }
}

run_case populated captured ok "${populated}"
[[ "${profiles_incomplete}" == "0" ]] || { echo "populated marked incomplete" >&2; exit 1; }
[[ -s "${test_root}/populated/telemetry/profiles/perflab-api-cpu.json" ]]
[[ -s "${test_root}/populated/telemetry/profiles/query.json" ]]
grep -q '"httpStatus":"200"' "${test_root}/populated/telemetry/profiles-signal.json" || { echo "populated must record HTTP 200" >&2; exit 1; }
grep -q '"ready":true' "${test_root}/populated/telemetry/profiles/query.json" || { echo "populated must record ready=true" >&2; exit 1; }

grep -q '"symbolization":"symbolized"' "${test_root}/populated/telemetry/profiles-signal.json" || { echo "populated must be symbolized" >&2; exit 1; }

half='{"flamebearer":{"names":["total","Unknown-Type.Unknown-Method","Work"],"levels":[[0,10,2,1]],"numTicks":10},"metadata":{"units":"nanoseconds"}}'
run_case half captured ok "${half}"
grep -q '"symbolization":"partial"' "${test_root}/half/telemetry/profiles-signal.json" || { echo "50% unknown must be partial" >&2; exit 1; }

# Samples exist but every frame is Unknown-Type.Unknown-Method: still content
# (captured), but recorded as unsymbolized, never as symbolized evidence.
unsymbolized='{"flamebearer":{"names":["total","Unknown-Type.Unknown-Method"],"levels":[[0,10,0,0],[0,10,10,1]],"numTicks":10},"metadata":{"units":"nanoseconds"}}'
run_case unsymbolized captured ok "${unsymbolized}"
grep -q '"symbolization":"unknown"' "${test_root}/unsymbolized/telemetry/profiles-signal.json" || { echo "unsymbolized profile must record symbolization=unknown" >&2; cat "${test_root}/unsymbolized/telemetry/profiles-signal.json" >&2; exit 1; }
grep -q '"symbolizedNodes":0' "${test_root}/unsymbolized/telemetry/profiles-signal.json" || { echo "symbolizedNodes must be 0" >&2; exit 1; }
grep -q 'no symbolized frames' "${test_root}/unsymbolized/telemetry/profiles-signal.json" || { echo "unsymbolized reason missing" >&2; exit 1; }

run_case empty missing ok "${empty}"
[[ "${profiles_incomplete}" == "1" ]] || { echo "required missing profile must be incomplete" >&2; exit 1; }

stub='{"flamebearer":{"names":["total"],"levels":[[0,0,0,0]]},"metadata":{"units":"samples"}}'
run_case stub missing ok "${stub}"
[[ "${profiles_incomplete}" == "1" ]] || { echo "stub total-only profile must be incomplete" >&2; exit 1; }

run_case truncated truncated ok "${truncated}"
[[ "${profiles_incomplete}" == "0" ]] || { echo "truncated profile must remain usable" >&2; exit 1; }

run_case malformed failed ok "${malformed}"
[[ "${profiles_incomplete}" == "1" ]] || { echo "malformed required profile must be incomplete" >&2; exit 1; }

run_case unreachable failed down ""
[[ "${profiles_incomplete}" == "1" ]] || { echo "unreachable required profile must be incomplete" >&2; exit 1; }
grep -q '"ready":false' "${test_root}/unreachable/telemetry/profiles/query.json" || { echo "unreachable must record ready=false" >&2; exit 1; }
grep -q 'unreachable' "${test_root}/unreachable/telemetry/profiles-signal.json" || { echo "unreachable reason missing" >&2; exit 1; }

# A reachable backend rejecting the selector (HTTP 400/500) is failed WITH the
# status, never mis-reported as unreachable.
run_case rejected failed 500 '{"code":"internal","message":"boom"}'
[[ "${profiles_incomplete}" == "1" ]] || { echo "HTTP 500 required profile must be incomplete" >&2; exit 1; }
grep -q '"httpStatus":"500"' "${test_root}/rejected/telemetry/profiles-signal.json" || { echo "HTTP status not recorded" >&2; cat "${test_root}/rejected/telemetry/profiles-signal.json" >&2; exit 1; }
grep -q 'HTTP 500' "${test_root}/rejected/telemetry/profiles-signal.json" || { echo "HTTP 500 reason missing" >&2; exit 1; }
grep -q 'unreachable' "${test_root}/rejected/telemetry/profiles-signal.json" && { echo "HTTP 500 must not be reported as unreachable" >&2; exit 1; }
grep -q '"ready":true' "${test_root}/rejected/telemetry/profiles/query.json" || { echo "rejected case must record ready=true" >&2; exit 1; }

# Required captured + optional idle secondary: signal stays captured, per-service
# states are retained, and the package is complete.
mixed_bin="${test_root}/bin-mixed"; mkdir -p "${mixed_bin}"
cat > "${mixed_bin}/curl" <<CURL
#!/usr/bin/env bash
set -euo pipefail
out=""; want_code=0; url=""; sel=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) want_code=1; shift 2 ;;
    --data-urlencode) [[ "\$2" == query=* ]] && sel="\$2"; shift 2 ;;
    --max-time) shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
if [[ "\${url}" == */ready ]]; then exit 0; fi
if [[ "\${sel}" == *perflab-api* ]]; then body=$(printf '%q' "${populated}"); else body=$(printf '%q' "${stub}"); fi
printf '%s\n' "\${body}" > "\${out}"
[[ "\${want_code}" == 1 ]] && printf '200'
CURL
chmod +x "${mixed_bin}/curl"
artifact="${test_root}/mixed"; mkdir -p "${artifact}"
PATH="${mixed_bin}:${PATH}" artifact_dir="${artifact}" continuous_profiling=1 capture_telemetry=1 \
pyroscope_url="http://127.0.0.1:4040" pyroscope_services="perflab-api perflab-worker" \
pyroscope_required_services="perflab-api" start_epoch=1 end_epoch=30 telemetry_run_id="run-1" target_mode="local" \
PYROSCOPE_CAPTURE_ATTEMPTS=1 PYROSCOPE_CAPTURE_SLEEP=0 \
  pyroscope_capture_profiles
grep -q '^{"captureState":"captured"' "${artifact}/telemetry/profiles-signal.json" || { echo "optional idle worker must not degrade the signal" >&2; cat "${artifact}/telemetry/profiles-signal.json" >&2; exit 1; }
grep -q '"service":"perflab-worker".*"captureState":"missing"' "${artifact}/telemetry/profiles-signal.json" || { echo "optional worker state not retained" >&2; exit 1; }
[[ "${profiles_incomplete}" == "0" ]] || { echo "optional idle worker must not make the package incomplete" >&2; exit 1; }

artifact="${test_root}/multi-type"; mkdir -p "${artifact}"
PATH="${mixed_bin}:${PATH}" artifact_dir="${artifact}" continuous_profiling=1 capture_telemetry=1 \
PERFLAB_PROFILING_TYPES="cpu,wall,allocation,lock,exception,live-heap" \
pyroscope_url="http://127.0.0.1:4040" pyroscope_services="perflab-api" \
pyroscope_required_services="perflab-api" start_epoch=1 end_epoch=30 telemetry_run_id="run-1" target_mode="local" \
PYROSCOPE_CAPTURE_ATTEMPTS=1 PYROSCOPE_CAPTURE_SLEEP=0 \
  pyroscope_capture_profiles
for profile_type in cpu wall allocation lock exception live-heap; do
  [[ -s "${artifact}/telemetry/profiles/perflab-api-${profile_type}.json" ]] || fail "missing ${profile_type} profile"
  grep -q "\"profileCategory\":\"${profile_type}\"" "${artifact}/telemetry/profiles-signal.json" || fail "missing ${profile_type} state"
done
grep -q '"profileTypes":\["cpu","wall","allocation","lock","exception","live-heap"\]' "${artifact}/telemetry/profiles/query.json" || fail "multi-type query manifest"

artifact="${test_root}/disabled"
mkdir -p "${artifact}"
artifact_dir="${artifact}" continuous_profiling=0 capture_telemetry=1 \
pyroscope_url="http://127.0.0.1:4040" pyroscope_services="perflab-api" \
pyroscope_required_services="perflab-api" start_epoch=1 end_epoch=30 \
telemetry_run_id="run-1" target_mode="local" \
  pyroscope_capture_profiles
grep -q '"captureState":"not-applicable"' "${artifact}/telemetry/profiles-signal.json"
[[ ! -d "${artifact}/telemetry/profiles" ]]
[[ "${profiles_incomplete}" == "0" ]]

echo "capture-profiles tests passed"
