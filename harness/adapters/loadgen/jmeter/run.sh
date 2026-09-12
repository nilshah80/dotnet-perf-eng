#!/usr/bin/env bash
# JMeter load adapter -- JMeter is NOT installed on the host; it runs via the
# pinned PerfLab container image. run.sh <artifact-dir> <phase>
# phase = warmup | measure | diagnostic
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"

artifact_dir="${1:?run.sh <artifact-dir> <phase>}"
phase="${2:?phase required (warmup|measure|diagnostic)}"

# The compatibility envelope of a MEASURED package is immutable evidence. A
# diagnostic replay that runs inside a measured package (isolated non-campaign
# diagnostics) publishes its own envelope beside it instead of overwriting it;
# a fresh campaign-load directory still receives compatibility.json.
compatibility_target() {
  local target="${artifact_dir}/benchmark/compatibility.json"
  if [[ "${phase}" == "diagnostic" && -s "${target}" ]]; then
    target="${artifact_dir}/benchmark/diagnostic-compatibility.json"
  fi
  printf '%s' "${target}"
}
mkdir -p "${artifact_dir}/benchmark" "${artifact_dir}/.scratch/${phase}"

jmeter_image="${PERFLAB_JMETER_IMAGE:-}"
[[ -n "${jmeter_image}" ]] || { echo "PERFLAB_JMETER_IMAGE is not set; JMeter runs via Docker." >&2; exit 2; }

case "${phase}" in
  warmup|measure|diagnostic) ;;
  *) echo "Unknown phase '${phase}' (use warmup|measure|diagnostic)." >&2; exit 2 ;;
esac
if [[ "${load_profile:-steady}" != "steady" ]]; then
  echo "JMeter supports PERFLAB_PROFILE=steady only; received '${load_profile}'." >&2
  exit 2
fi

inspect_json="$(docker image inspect --format '{{json .}}' "${jmeter_image}" 2>/dev/null || true)"
[[ -n "${inspect_json}" ]] || {
  echo "JMeter image ${jmeter_image} is not present locally. Load it with docker pull ${jmeter_image} or package-plugin.sh jmeter (never pulled during a run)." >&2
  exit 2
}
image_id="$(printf '%s' "${inspect_json}" | jqd -r '.Id // empty')"
[[ "${image_id}" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo "docker inspect omitted a content-addressed image ID for ${jmeter_image}." >&2; exit 2; }

asserted_digest=""
case "${jmeter_image}" in
  sha256:*)
    [[ "${image_id}" == "${jmeter_image}" ]] || { echo "local image ID ${image_id} does not match declared ${jmeter_image}." >&2; exit 2; }
    asserted_digest="${image_id}"
    ;;
  *@sha256:*)
    declared_digest="${jmeter_image##*@}"
    repo="${jmeter_image%@*}"
    matched="$(printf '%s' "${inspect_json}" | jqd -r --arg d "${declared_digest}" --arg repo "${repo}" '
      def canon: sub("^docker.io/"; "") | sub("^index.docker.io/"; "");
      ($repo | canon) as $want
      | (.RepoDigests // [])[]?
      | select((split("@")[1] // "") == $d)
      | split("@")[0]
      | select(canon == $want)
    ' 2>/dev/null || true)"
    [[ -n "${matched}" ]] || { echo "image ${jmeter_image} is present but RepoDigests do not contain ${declared_digest} for repository ${repo}. docker pull ${jmeter_image}" >&2; exit 2; }
    asserted_digest="${declared_digest}"
    ;;
  *)
    echo "PERFLAB_JMETER_IMAGE must be a digest pin (name@sha256:...) or local image ID (sha256:64)." >&2
    exit 2
    ;;
esac

cpus="2"
memory="2147483648"
export PERFLAB_PLUGIN_ID="perflab.load.jmeter"
export PERFLAB_PLUGIN_VERSION="0.1.0"
export PERFLAB_PLUGIN_IMAGE_DIGEST="${asserted_digest}"
export PERFLAB_PLUGIN_CPUS="${cpus}"
export PERFLAB_PLUGIN_MEMORY_BYTES="${memory}"
export PERFLAB_JMETER_PROP_BASE_URL="${PERFLAB_JMETER_PROP_BASE_URL:-perflab.base_url}"
export PERFLAB_JMETER_PROP_THREADS="${PERFLAB_JMETER_PROP_THREADS:-perflab.threads}"
export PERFLAB_JMETER_PROP_DURATION_SECONDS="${PERFLAB_JMETER_PROP_DURATION_SECONDS:-perflab.duration_seconds}"
export PERFLAB_JMETER_PROP_RUN_ID="${PERFLAB_JMETER_PROP_RUN_ID:-perflab.run_id}"
export PERFLAB_JMETER_PROP_SCENARIO="${PERFLAB_JMETER_PROP_SCENARIO:-perflab.scenario}"

version_json="$(MSYS_NO_PATHCONV=1 docker run --rm --pull=never \
  --env PERFLAB_PLUGIN_ID --env PERFLAB_PLUGIN_VERSION --env PERFLAB_PLUGIN_IMAGE_DIGEST \
  --env PERFLAB_PLUGIN_CPUS --env PERFLAB_PLUGIN_MEMORY_BYTES \
  "${jmeter_image}" version --json)"
reported_digest="$(printf '%s' "${version_json}" | jqd -r '.imageDigest // empty')"
reported_cpus="$(printf '%s' "${version_json}" | jqd -r '.cpus // 0')"
reported_memory="$(printf '%s' "${version_json}" | jqd -r '.memoryBytes // 0')"
reported_max="$(printf '%s' "${version_json}" | jqd -r '.maxThreads // 0')"
[[ -n "${reported_digest}" ]] || { echo "version --json omitted imageDigest; host must pass PERFLAB_PLUGIN_IMAGE_DIGEST." >&2; exit 2; }
[[ "${reported_digest}" == "${asserted_digest}" ]] || { echo "adapter image digest '${reported_digest}' does not match inspect '${asserted_digest}'." >&2; exit 2; }
[[ "${reported_cpus}" == "${cpus}" && "${reported_memory}" == "${memory}" ]] || { echo "adapter CPU/memory ${reported_cpus}/${reported_memory} do not match host assertion ${cpus}/${memory}." >&2; exit 2; }
[[ "${reported_max}" == "256" ]] || { echo "adapter maxThreads ${reported_max} is not the Phase 2 ceiling of 256." >&2; exit 2; }

conns="${PERFLAB_CONNECTIONS:?PERFLAB_CONNECTIONS not set}"
[[ "${conns}" =~ ^[1-9][0-9]*$ ]] || { echo "PERFLAB_CONNECTIONS must be a positive integer." >&2; exit 2; }
if (( conns > 256 )); then
  echo "JMeter connections ${conns} exceed the 256 thread ceiling." >&2
  exit 2
fi

warmup_seconds="${PERFLAB_WARMUP_SECONDS:-10}"
dur="${PERFLAB_DURATION_SECONDS:-}"
case "${phase}" in
  warmup)
    [[ "${warmup_seconds}" =~ ^[1-9][0-9]*$ ]] || { echo "PERFLAB_WARMUP_SECONDS must be a positive integer." >&2; exit 2; }
    threads="${conns}"
    (( threads > 16 )) && threads=16
    export PERFLAB_CONNECTIONS="${threads}"
    export PERFLAB_DURATION_SECONDS="${warmup_seconds}"
    export PERF_RUN_MODE="warmup"
    timeout_secs=$(( warmup_seconds + 90 ))
    ;;
  measure)
    [[ "${dur}" =~ ^[1-9][0-9]*$ ]] || { echo "PERFLAB_DURATION_SECONDS must be a positive integer." >&2; exit 2; }
    export PERF_RUN_MODE="measure"
    timeout_secs=$(( dur + 90 ))
    ;;
  diagnostic)
    [[ "${dur}" =~ ^[1-9][0-9]*$ ]] || { echo "PERFLAB_DURATION_SECONDS must be a positive integer." >&2; exit 2; }
    export PERF_RUN_MODE="diagnose"
    timeout_secs=$(( dur + 60 ))
    ;;
esac

plan_rel="${PERFLAB_JMETER_PLAN:-}"
if [[ -z "${plan_rel}" ]]; then
  script="$(loadgen_script)"
  plan_rel="$(relative_to_repo "${script}")"
fi
[[ -n "${plan_rel}" && -f "${repo_root}/${plan_rel}" ]] || { echo "JMeter plan '${plan_rel}' is missing under the repository root." >&2; exit 2; }
workload_root="${repo_root}"
file_flags=()
files_json='[]'
if [[ -n "${PERFLAB_JMETER_FILES:-}" ]]; then
  files_json="$(printf '%s' "${PERFLAB_JMETER_FILES}" | jqd -c 'if type=="array" then map(tostring) else error("PERFLAB_JMETER_FILES must be a JSON array") end')" || {
    echo "PERFLAB_JMETER_FILES must be a JSON array of repository-relative paths." >&2
    exit 2
  }
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    [[ -f "${repo_root}/${rel}" ]] || { echo "JMeter supporting file '${rel}' is missing under the repository root." >&2; exit 2; }
    file_flags+=(--file "${rel}")
  done < <(printf '%s' "${files_json}" | jqd -r '.[]')
fi

if [[ "${target_mode:-local}" == "remote" ]]; then
  network_args=()
  export PERF_BASE_URL="${base_url}"
  network_path="remote-bridge"
  case "${PERF_BASE_URL}" in
    *"://127."*|*"://localhost"*|*"://[::1]"*|*"://0.0.0.0"*|*"://[::]"*)
      echo "JMeter cannot reach an unroutable generator URL (${PERF_BASE_URL}) from inside its container." >&2
      exit 2 ;;
  esac
else
  network_args=(--network "${compose_network}")
  export PERF_BASE_URL="${internal_base_url}"
  network_path="compose-network"
fi
export PERFLAB_GENERATOR_NETWORK_PATH="${network_path}"
export PERFLAB_PROFILE="${load_profile:-steady}"

user_args=()
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) user_args=(--user "$(id -u):$(id -g)") ;;
esac

plugin_env=(
  --env PERFLAB_PLUGIN_ID --env PERFLAB_PLUGIN_VERSION --env PERFLAB_PLUGIN_IMAGE_DIGEST
  --env PERFLAB_PLUGIN_CPUS --env PERFLAB_PLUGIN_MEMORY_BYTES
  --env PERFLAB_JMETER_PROP_BASE_URL --env PERFLAB_JMETER_PROP_THREADS
  --env PERFLAB_JMETER_PROP_DURATION_SECONDS --env PERFLAB_JMETER_PROP_RUN_ID --env PERFLAB_JMETER_PROP_SCENARIO
  --env PERF_BASE_URL --env PERF_METHOD --env PERF_PATH --env PERF_BODY
  --env PERF_RUN_ID --env PERF_SCENARIO --env PERF_RUN_MODE --env PERF_HEADERS
  --env PERFLAB_CONNECTIONS --env PERFLAB_DURATION_SECONDS --env PERFLAB_PROFILE
  --env PERFLAB_GENERATOR_NETWORK_PATH
)

MSYS_NO_PATHCONV=1 docker run --rm --pull=never --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m --cap-drop ALL --security-opt no-new-privileges \
  "${user_args[@]}" "${network_args[@]}" \
  --cpus "${cpus}" --memory "${memory}" \
  --add-host host.docker.internal:host-gateway \
  -v "${workload_root}:/workload:ro" \
  -v "${artifact_dir}:/results" \
  "${plugin_env[@]}" \
  "${jmeter_image}" run-once \
    --phase "${phase}" \
    --output-dir /results \
    --timeout "${timeout_secs}s" \
    --workload-root /workload \
    --plan "${plan_rel}" \
    "${file_flags[@]}"

[[ "${phase}" == "warmup" ]] && exit 0
if [[ "${phase}" == "measure" ]]; then
  [[ -s "${artifact_dir}/benchmark/observations.json" ]] || { echo "JMeter measure phase did not publish observations.json." >&2; exit 4; }
  p95="$(jqd -r '.[] | select(.name=="http.latency.p95") | .value' < "${artifact_dir}/benchmark/observations.json" 2>/dev/null || true)"
  [[ -n "${p95}" && "${p95}" != "null" ]] || { echo "JMeter observations.json omitted http.latency.p95." >&2; exit 4; }
  summary="${artifact_dir}/benchmark/jmeter-summary-v1.json"
else
  summary="${artifact_dir}/benchmark/jmeter-diagnostic-summary-v1.json"
fi
[[ -s "${summary}" ]] || { echo "JMeter ${phase} phase did not publish $(basename "${summary}")." >&2; exit 4; }
script_hash="$(jqd -r '.scriptHash // empty' < "${summary}")"
fingerprint="$(printf '%s' "${version_json}" | jqd -r '.fingerprint // empty')"
[[ -n "${script_hash}" && "${#script_hash}" -eq 64 ]] || { echo "JMeter summary omitted scriptHash; refusing facts.json." >&2; exit 4; }
[[ -n "${fingerprint}" && "${fingerprint}" == adapter=* ]] || { echo "JMeter version --json omitted a composite fingerprint; refusing facts.json." >&2; exit 4; }
duration_hash="${PERFLAB_DURATION_SECONDS}"
timeout_hash="${timeout_secs}s"
prep_seconds="${PERFLAB_WARMUP_SECONDS:-10}"
prep_threads="${conns}"
(( prep_threads > 16 )) && prep_threads=16
prep_enabled="false"
[[ "${phase}" == "measure" || -n "${PERFLAB_DIAGNOSTIC_PRESET:-}" ]] && prep_enabled="true"
[[ "${prep_seconds}" =~ ^[1-9][0-9]*$ ]] || { echo "PERFLAB_WARMUP_SECONDS must be a positive integer to record JMeter preparation." >&2; exit 4; }
header_names='[]'
if [[ -n "${PERF_HEADERS:-}" ]]; then
  header_names="$(printf '%s' "${PERF_HEADERS}" | jqd -c 'if type=="object" then keys|sort else error("PERF_HEADERS must be an object") end')"
fi
if command -v openssl >/dev/null 2>&1; then
  body_hash="$(printf '%s' "${PERF_BODY:-}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
else
  body_hash="$(printf '%s' "${PERF_BODY:-}" | shasum -a 256 | awk '{print $1}')"
fi
[[ "${body_hash}" =~ ^[a-f0-9]{64}$ ]] || { echo "JMeter request-body identity could not be computed." >&2; exit 4; }
config_json="$(jqd -n \
  --arg connections "${PERFLAB_CONNECTIONS}" \
  --arg duration "${duration_hash}" \
  --arg timeout "${timeout_hash}" \
  --arg profile "${PERFLAB_PROFILE}" \
  --arg scenario "${PERF_SCENARIO:-}" \
  --arg base "${PERF_BASE_URL}" \
  --arg method "${PERF_METHOD:-}" \
  --arg path "${PERF_PATH:-}" \
  --arg body_hash "${body_hash}" \
  --argjson header_names "${header_names}" \
  --arg network "${network_path}" \
  --arg plan "${plan_rel}" \
  --argjson files "${files_json}" \
  --argjson prep_enabled "${prep_enabled}" \
  --argjson prep_threads "${prep_threads}" \
  --argjson prep_seconds "${prep_seconds}" \
  --arg prop_base "${PERFLAB_JMETER_PROP_BASE_URL}" \
  --arg prop_threads "${PERFLAB_JMETER_PROP_THREADS}" \
  --arg prop_duration "${PERFLAB_JMETER_PROP_DURATION_SECONDS}" \
  --arg prop_run "${PERFLAB_JMETER_PROP_RUN_ID}" \
  --arg prop_scenario "${PERFLAB_JMETER_PROP_SCENARIO}" \
  --arg run_id "${PERF_RUN_ID:-}" \
  '{
    connections:($connections|tonumber),
    durationSeconds:($duration|tonumber),
    timeout:$timeout,
    profile:$profile,
    scenario:$scenario,
    baseUrl:$base,
    method:$method,
    path:$path,
    bodyHash:$body_hash,
    headerNames:$header_names,
    networkPath:$network,
    arguments:[],
    files: ([$plan] + $files | unique | sort),
    preparation: {enabled:$prep_enabled, threads:$prep_threads, durationSeconds:$prep_seconds},
    propertyBindings: {
      ($prop_base): $base,
      ($prop_threads): $connections,
      ($prop_duration): $duration,
      ($prop_run): "{{run_id}}",
      ($prop_scenario): $scenario
    }
  }')"
canonical_json="$(printf '%s' "${config_json}" | jqd -c 'walk(if type=="object" then to_entries|sort_by(.key)|from_entries else . end)')"
config_hash="$(printf '%s' "${canonical_json}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
if [[ -z "${config_hash}" ]]; then
  config_hash="$(printf '%s' "${canonical_json}" | shasum -a 256 | awk '{print $1}')"
fi
[[ -n "${config_hash}" ]] || { echo "JMeter configurationHash could not be computed." >&2; exit 4; }
jqd -n \
  --arg generator "jmeter" \
  --arg fp "${fingerprint}" \
  --arg content "${script_hash}" \
  --arg config "${config_hash}" \
  --arg network "${network_path}" \
  --arg timeout "${timeout_hash}" \
  --argjson duration "${duration_hash}" \
  --argjson connections "${PERFLAB_CONNECTIONS}" \
  --arg scenario "${PERF_SCENARIO:-}" \
  --arg profile "${PERFLAB_PROFILE}" \
  --arg base "${PERF_BASE_URL}" \
  --arg method "${PERF_METHOD:-}" \
  --arg path "${PERF_PATH:-}" \
  --argjson prep_enabled "${prep_enabled}" \
  --argjson prep_threads "${prep_threads}" \
  --argjson prep_seconds "${prep_seconds}" \
  --argjson files "$(printf '%s' "${config_json}" | jqd -c '.files')" \
  --argjson bindings "$(printf '%s' "${config_json}" | jqd -c '.propertyBindings')" \
  '{generator:$generator,generatorFingerprint:$fp,workloadContentHash:$content,configurationHash:$config,networkPath:$network,timeout:$timeout,durationSeconds:$duration,connections:$connections,scenario:$scenario,profile:$profile,baseUrl:$base,method:$method,path:$path,files:$files,propertyBindings:$bindings,preparation:{enabled:$prep_enabled,threads:$prep_threads,durationSeconds:$prep_seconds}}' \
  > "$(compatibility_target)"
