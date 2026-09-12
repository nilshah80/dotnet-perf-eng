#!/usr/bin/env bash
# Recapture must not rewrite a profiling-off package as profiling-on (or the reverse).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "capture-evidence-profiling-guard-test: $*" >&2; exit 1; }

jq_bin="$(command -v jq || true)"
[[ -n "${jq_bin}" ]] || fail "jq is required"
docker_bin="$(command -v docker || true)"
[[ -n "${docker_bin}" ]] || fail "docker is required"

test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/bin"

cat > "${test_root}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" != "run" ]]; then
  exec "${docker_bin}" "\$@"
fi
shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --rm|--interactive|-i|-t|--tty) shift ;;
    *) break ;;
  esac
done
shift
exec "${jq_bin}" "\$@"
EOF
chmod +x "${test_root}/bin/docker"

parsed="$(printf '{"continuousProfiling":true}\n' | PATH="${test_root}/bin:${PATH}" docker run --rm -i ghcr.io/jqlang/jq:1.7.1 -r '.continuousProfiling')"
[[ "${parsed}" == "true" ]] || fail "jq docker shim failed to parse JSON (got ${parsed})"

write_manifest() {
  local dir="$1" profiling="$2"
  mkdir -p "${dir}"
  cat > "${dir}/manifest.json" <<JSON
{"runId":"run-fixture","telemetryRunId":"run-fixture","scenarioId":"S01","workload":{"loadGenerator":"k6"},"startedEpoch":1700000000,"target":"local","remoteTelemetry":false,"continuousProfiling":${profiling}}
JSON
}

run_capture() {
  local dir="$1" profiling="$2"
  PATH="${test_root}/bin:${PATH}" \
    PERFLAB_LAB=scenariolab \
    PERFLAB_CONTINUOUS_PROFILING="${profiling}" \
    bash "${repo}/harness/core/capture/capture-evidence.sh" "${dir}"
}

assert_guard_only() {
  local out="$1"
  if printf '%s\n' "${out}" | grep -q 'Prometheus'; then
    fail "guard continued into backend capture:\n${out}"
  fi
}

off_pkg="${test_root}/profiling-off"
write_manifest "${off_pkg}" false
if out="$(run_capture "${off_pkg}" 1 2>&1)"; then
  fail "profiling-off package was recaptured with profiling enabled:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'continuousProfiling=false' || fail "missing reverse-mismatch error:\n${out}"
printf '%s\n' "${out}" | grep -q 'rewrite compatibility as profiling-on' || fail "missing rewrite warning:\n${out}"
assert_guard_only "${out}"

on_pkg="${test_root}/profiling-on"
write_manifest "${on_pkg}" true
if out="$(run_capture "${on_pkg}" 0 2>&1)"; then
  fail "profiling-on package was recaptured with profiling disabled:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_CONTINUOUS_PROFILING=1' || fail "missing profiling-on mismatch error:\n${out}"
assert_guard_only "${out}"

echo "capture-evidence profiling guard tests passed"
