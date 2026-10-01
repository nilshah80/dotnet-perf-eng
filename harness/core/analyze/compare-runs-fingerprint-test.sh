#!/usr/bin/env bash
# compare-runs must refuse packages whose capture conditions differ.
#
# Profiling on/off and keep-tiering are already refused elsewhere. Two runs can
# still differ in ways that change every number while both look comparable:
#
#   profilingTypes  an all-diagnostic run carries five more profilers than a
#                   cpu-only one, each taking its own samples from the process
#   traceSampler    a 25%-sampled trace window sees a different tail than a
#                   100% one, so p99 is not measuring the same population
#
# Comparing across either is comparing two different experiments and calling the
# difference a regression. The refusal must also say which knob to re-run with,
# because "not comparable" without a remedy just gets overridden.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "compare-runs-fingerprint-test: $*" >&2; exit 1; }

jq_bin="$(command -v jq || true)"; [[ -n "${jq_bin}" ]] || fail "jq is required"
docker_bin="$(command -v docker || true)"; [[ -n "${docker_bin}" ]] || fail "docker is required"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/compare-fingerprint-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT HUP INT TERM
mkdir -p "${test_root}/bin"

cat > "${test_root}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" != "run" ]]; then exec "${docker_bin}" "\$@"; fi
shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in --rm|--interactive|-i|-t|--tty) shift ;; *) break ;; esac
done
shift
exec "${jq_bin}" "\$@"
EOF
chmod +x "${test_root}/bin/docker"

# write_facts <path> <profilingTypes> <sampler> <samplerArg>
# An empty value omits the field entirely, which is how a package captured
# before these were recorded looks on disk.
write_facts() {
  local path="$1" types="$2" sampler="$3" arg="$4" fields=""
  [[ -n "${types}" ]]   && fields+=",\"profilingTypes\":\"${types}\""
  [[ -n "${sampler}" ]] && fields+=",\"traceSampler\":\"${sampler}\",\"traceSamplerArg\":\"${arg}\""
  cat > "${path}" <<JSON
{"observations":[{"name":"requests_per_second","value":100}],
 "continuousProfiling":true,"profilingKeepTiering":false,
 "compatibility":{"continuousProfiling":true,"profilingKeepTiering":false}${fields}}
JSON
}

compare() {
  PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab \
    bash "${repo}/harness/core/analyze/compare-runs.sh" "$@"
}

cpu_only="${test_root}/cpu-only.json"
cpu_only_b="${test_root}/cpu-only-b.json"
all_diag="${test_root}/all-diagnostic.json"
sampled="${test_root}/sampled.json"
legacy="${test_root}/legacy.json"
write_facts "${cpu_only}"   "cpu"                             parentbased_traceidratio 1.0
write_facts "${cpu_only_b}" "cpu"                             parentbased_traceidratio 1.0
write_facts "${all_diag}"   "cpu,wall,alloc,lock,exception"   parentbased_traceidratio 1.0
write_facts "${sampled}"    "cpu"                             parentbased_traceidratio 0.25
write_facts "${legacy}"     ""                                "" ""

# 1. Same conditions compare normally. Without this the refusals below could be
#    satisfied by a script that refuses everything.
out="$(compare "${cpu_only}" "${cpu_only_b}" 2>&1)" \
  || fail "two identically-captured packages were refused:\n${out}"
printf '%s\n' "${out}" | grep -q 'no regression' || fail "expected a clean comparison:\n${out}"

# 2. A different profiler set is a different experiment.
if out="$(compare "${cpu_only}" "${all_diag}" 2>&1)"; then
  fail "a cpu-only run was compared against an all-diagnostic run:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'profilingTypes' || fail "the refusal must name the field:\n${out}"
printf '%s\n' "${out}" | grep -q 'PERFLAB_PROFILING_POLICY' \
  || fail "the refusal must say which setting to re-run with:\n${out}"

# 3. A different trace sampler sees a different tail.
if out="$(compare "${cpu_only}" "${sampled}" 2>&1)"; then
  fail "a 100%-sampled run was compared against a 25%-sampled run:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'trace sampler' || fail "the refusal must name the sampler:\n${out}"
printf '%s\n' "${out}" | grep -q 'PERFLAB_TRACE_SAMPLE_RATIO' \
  || fail "the refusal must say which setting to re-run with:\n${out}"
printf '%s\n' "${out}" | grep -q '0.25' || fail "the refusal must show the differing values:\n${out}"

# 4. A package captured before these fields existed must still compare. A guard
#    that rejected every older package would be worked around rather than fixed,
#    and the absent field is genuinely unknown rather than known-different.
out="$(compare "${cpu_only}" "${legacy}" 2>&1)" \
  || fail "a package predating these fields was treated as incompatible:\n${out}"
printf '%s\n' "${out}" | grep -q 'no regression' \
  || fail "an unrecorded fingerprint should not block the comparison:\n${out}"

# --- dataset identity ------------------------------------------------------
# The fingerprint exists so two runs over different data cannot compare as
# equal. A fingerprint nobody reads, or one that only warns, leaves that
# comparison possible -- which is the whole failure it was added to prevent.
dataset_pkg() { # dataset_pkg <name> <state> <sha>
  local dir="${test_root}/$1"
  mkdir -p "${dir}/data"
  write_facts "${dir}/facts.json" "cpu" parentbased_traceidratio 1.0
  printf '{"datasetIdentity":"seedScale=default","contentFingerprint":{"captureState":"%s","sha256":"%s"}}\n' \
    "$2" "$3" > "${dir}/data/dataset.json"
  printf '%s' "${dir}/facts.json"
}
same_a="$(dataset_pkg ds-a captured aaaa000000000000000000000000000000000000000000000000000000000000)"
same_b="$(dataset_pkg ds-b captured aaaa000000000000000000000000000000000000000000000000000000000000)"
diff_b="$(dataset_pkg ds-c captured bbbb000000000000000000000000000000000000000000000000000000000000)"
failed_b="$(dataset_pkg ds-d failed "")"

out="$(compare "${same_a}" "${same_b}" 2>&1)" \
  || fail "two runs over the same dataset were refused:\n${out}"

if out="$(compare "${same_a}" "${diff_b}" 2>&1)"; then
  fail "two runs over DIFFERENT datasets compared as equal:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'measured different datasets' \
  || fail "the refusal does not say the datasets differ:\n${out}"

# A fingerprint that could not be captured is not evidence of a match. Warning
# and continuing leaves the comparison exactly as unsound as no check at all.
if out="$(compare "${same_a}" "${failed_b}" 2>&1)"; then
  fail "a run whose dataset could not be identified was compared anyway:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'failed to capture' \
  || fail "the refusal does not name the capture failure:\n${out}"

# Both refusals are overridable by the same flag: the operator is making one
# judgement -- proceed without knowing the data matched.
out="$(compare "${same_a}" "${diff_b}" --allow-dataset-mismatch 2>&1)" \
  || fail "--allow-dataset-mismatch did not permit a known mismatch:\n${out}"
out="$(compare "${same_a}" "${failed_b}" --allow-dataset-mismatch 2>&1)" \
  || fail "--allow-dataset-mismatch did not permit an unidentifiable dataset:\n${out}"

# A package captured before the fingerprint existed has no state at all.
# Refusing those would make every older baseline unusable.
out="$(compare "${cpu_only}" "${cpu_only_b}" 2>&1)" \
  || fail "packages predating the dataset fingerprint were refused:\n${out}"

echo "compare-runs fingerprint tests passed"
