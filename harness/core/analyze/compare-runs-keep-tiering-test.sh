#!/usr/bin/env bash
# compare-runs must refuse profiling-on packages that disagree on keep-tiering.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "compare-runs-keep-tiering-test: $*" >&2; exit 1; }

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

write_facts() {
  local path="$1" keep="$2"
  cat > "${path}" <<JSON
{"observations":[{"name":"requests_per_second","value":100}],"continuousProfiling":true,"profilingKeepTiering":${keep},"compatibility":{"continuousProfiling":true,"profilingKeepTiering":${keep}}}
JSON
}

compare() {
  PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab \
    bash "${repo}/harness/core/analyze/compare-runs.sh" "$@"
}

default_a="${test_root}/default-a.json"
default_b="${test_root}/default-b.json"
keep_b="${test_root}/keep-b.json"
legacy="${test_root}/legacy.json"
write_facts "${default_a}" false
write_facts "${default_b}" false
write_facts "${keep_b}" true
cat > "${legacy}" <<'JSON'
{"observations":[{"name":"requests_per_second","value":100}],"continuousProfiling":true,"compatibility":{"continuousProfiling":true}}
JSON

if out="$(compare "${default_a}" "${keep_b}" 2>&1)"; then
  fail "keep-tiering mismatch was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'profilingKeepTiering' || fail "missing keep-tiering mismatch error:\n${out}"
printf '%s\n' "${out}" | grep -q 'PERFLAB_PROFILING_KEEP_TIERING' || fail "missing keep-tiering rerun hint:\n${out}"

out="$(compare "${default_a}" "${default_b}" 2>&1)" \
  || fail "matching keep-tiering packages were rejected:\n${out}"
printf '%s\n' "${out}" | grep -q 'no regression' || fail "expected a successful comparison:\n${out}"

out="$(compare "${default_a}" "${legacy}" 2>&1)" \
  || fail "legacy package missing profilingKeepTiering was treated as incompatible:\n${out}"
printf '%s\n' "${out}" | grep -q 'no regression' || fail "legacy default should compare as keep-tiering=false:\n${out}"

echo "compare-runs keep-tiering tests passed"
