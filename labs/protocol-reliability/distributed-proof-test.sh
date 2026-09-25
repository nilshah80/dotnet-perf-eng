#!/usr/bin/env bash
# Case 28 / C-3: two independently listening, authenticated agents run real
# k6 execution segments against the third lab. The target proves the two
# generated data partitions; a missing agent then proves fail-closed and
# explicit partial-loss behavior without averaging percentile summaries.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
project="${root}/source/dotnet/protocol-reliability/ProtocolReliability.Api.csproj"
agent="${root}/harness/core/distributed/agent.py"
for tool in dotnet k6 curl jq lsof rg; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "distributed-proof-test: ${tool} is required" >&2; exit 1; }
done
# shellcheck source=/dev/null
. "${root}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || { echo "distributed-proof-test: a working Python 3 interpreter was not found (tried python3, python)" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/protocol-distributed.XXXXXX")"
app_pid=""
agent_a_pid=""
agent_b_pid=""
cleanup() {
  for pid in "${agent_b_pid}" "${agent_a_pid}" "${app_pid}"; do
    [[ -z "${pid}" ]] || { kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; }
  done
  if [[ "${PERFLAB_DISTRIBUTED_KEEP:-0}" == "1" ]]; then
    echo "distributed-proof-test: retained diagnostic files at ${work}" >&2
  else
    rm -rf "${work}"
  fi
}
trap cleanup EXIT HUP INT TERM

port=""
for candidate in $(seq 18800 18839); do
  if ! lsof -n -iTCP:"${candidate}" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"$((candidate + 1))" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"$((candidate + 2))" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"$((candidate + 100))" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"$((candidate + 3))" -sTCP:LISTEN >/dev/null 2>&1; then
    port="${candidate}"
    break
  fi
done
[[ -n "${port}" ]] || { echo "distributed-proof-test: no free test port set" >&2; exit 1; }
target="http://127.0.0.1:${port}"
agent_a="http://127.0.0.1:$((port + 1))"
agent_b="http://127.0.0.1:$((port + 2))"
missing="http://127.0.0.1:$((port + 3))"

dotnet build "${project}" --no-restore --nologo >/dev/null
app_dll="${root}/source/dotnet/protocol-reliability/bin/Debug/net10.0/ProtocolReliability.Api.dll"
PERFLAB_HTTP_PORT="${port}" PERFLAB_GRPC_PORT="$((port + 100))" INSTANCE_ID=distributed-proof-target \
  dotnet "${app_dll}" >"${work}/target.log" 2>&1 &
app_pid="$!"
for _ in $(seq 1 30); do
  curl -fsS --max-time 2 "${target}/health/ready" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 2 "${target}/health/ready" >/dev/null || {
  cat "${work}/target.log" >&2
  echo "distributed-proof-test: target did not become ready" >&2
  exit 1
}

# This fixture-only token stays in process environment / Authorization headers.
# The controller evidence records only secret://PERFLAB_DISTRIBUTED_TOKEN.
export PERFLAB_DISTRIBUTED_TOKEN=distributed-proof-token
"${PYTHON}" "${agent}" agent --root "${root}" --listen "127.0.0.1:$((port + 1))" \
  --agent-id fixture-agent-a --allow-origin "${target}" >"${work}/agent-a.log" 2>&1 &
agent_a_pid="$!"
"${PYTHON}" "${agent}" agent --root "${root}" --listen "127.0.0.1:$((port + 2))" \
  --agent-id fixture-agent-b --allow-origin "${target}" >"${work}/agent-b.log" 2>&1 &
agent_b_pid="$!"
for _ in $(seq 1 30); do
  grep -q 'distributed-agent-ready' "${work}/agent-a.log" 2>/dev/null &&
    grep -q 'distributed-agent-ready' "${work}/agent-b.log" 2>/dev/null && break
  sleep 0.2
done
grep -q 'distributed-agent-ready' "${work}/agent-a.log" && grep -q 'distributed-agent-ready' "${work}/agent-b.log" || {
  cat "${work}/agent-a.log" "${work}/agent-b.log" >&2
  echo "distributed-proof-test: agents did not start" >&2
  exit 1
}

"${PYTHON}" "${agent}" controller --allow-insecure-local --agents "${agent_a},${agent_b}" --shards 2 \
  --target-origin "${target}" --duration-seconds 3 --connections 2 --run-id distributed-proof \
  --artifact-dir "${work}/complete" >"${work}/complete.out"
jq -e '
  .status == "complete" and .partialLoss == false and .tokenReference == "secret://PERFLAB_DISTRIBUTED_TOKEN" and
  (.generatorFingerprint | test("^sha256:[a-f0-9]{64}$")) and
  ([.agentResults[].generatorFingerprint] | unique | length == 1) and
  .generatorFingerprint == .agentResults[0].generatorFingerprint and
  (.agentResults | length == 2) and (.aggregate.requests > 0) and
  (.aggregate as $aggregate | ($aggregate.histogram.counts | add) == $aggregate.requests) and
  (.aggregate.percentilesMilliseconds.p95 | type == "number") and
  ([.agentResults[].executionSegment] | sort == ["0:1/2", "1/2:1"])
' "${work}/complete/benchmark/distributed-aggregate.json" >/dev/null || {
  cat "${work}/complete/benchmark/distributed-aggregate.json" >&2
  echo "distributed-proof-test: complete merge did not preserve shard histograms/segments" >&2
  exit 1
}
curl -fsS "${target}/api/reliability/distributed/proof" | jq -e '
  .partitionCount == 2 and (.requestsByPartition | keys | length == 2) and
  ([.requestsByPartition | values[]] | all(. > 0))
' >/dev/null || { echo "distributed-proof-test: target did not observe two unique data partitions" >&2; exit 1; }

# The controller proof above exercises the native protocol directly. Exercise
# the product runner too: P14 must take the same closed agent route through
# run-scenario.sh rather than quietly falling back to one local k6 process.
native_artifacts="${work}/native-runner"
PERFLAB_LAB=protocol-reliability \
PERFLAB_TARGET=remote \
PERFLAB_BASE_URL="${target}" \
PERFLAB_READY_URL="${target}/health/ready" \
PERFLAB_ARTIFACT_DIR="${native_artifacts}" \
PERFLAB_WARMUP_SECONDS=1 \
PERFLAB_PROFILE=steady \
PERFLAB_RECORD_TREND=0 \
PERFLAB_DISTRIBUTED=1 \
PERFLAB_SHARDS=2 \
PERFLAB_DISTRIBUTED_AGENT_URLS="${agent_a},${agent_b}" \
PERFLAB_DISTRIBUTED_ALLOW_INSECURE_LOCAL=1 \
  bash "${root}/harness/core/run/run-scenario.sh" P14 3 >"${work}/native-runner.out"
jq -e '
  .distributed.enabled == true and .distributed.protocol == "perflab-distributed/v1" and
  .distributed.shards == 2 and .distributed.tokenReference == "secret://PERFLAB_DISTRIBUTED_TOKEN"
' "${native_artifacts}/manifest.json" >/dev/null || {
  cat "${native_artifacts}/manifest.json" >&2
  echo "distributed-proof-test: native runner did not record the closed distributed plan" >&2
  exit 1
}
jq -e '
  .status == "complete" and .partialLoss == false and (.agentResults | length == 2) and
  (.generatorFingerprint | test("^sha256:[a-f0-9]{64}$")) and
  ([.agentResults[].generatorFingerprint] | unique | length == 1) and
  .generatorFingerprint == .agentResults[0].generatorFingerprint and
  (.aggregate.requests > 0) and (.aggregate.histogram.counts | add) == .aggregate.requests
' "${native_artifacts}/benchmark/distributed-aggregate.json" >/dev/null || {
  cat "${native_artifacts}/benchmark/distributed-aggregate.json" >&2
  echo "distributed-proof-test: native runner did not retain its complete distributed aggregate" >&2
  exit 1
}
jq -e --slurpfile aggregate "${native_artifacts}/benchmark/distributed-aggregate.json" '
  .generator == "k6" and .distributedProtocol == "perflab-distributed/v1" and
  (.generatorFingerprint | test("^sha256:[a-f0-9]{64}$")) and
  .generatorFingerprint == $aggregate[0].generatorFingerprint and
  (.workloadContentHash | test("^[a-f0-9]{64}$")) and
  (.configurationHash | test("^[a-f0-9]{64}$")) and
  .networkPath == "distributed-agent" and .agentCount == 2 and .partialLoss == false
' "${native_artifacts}/benchmark/compatibility.json" >/dev/null || {
  cat "${native_artifacts}/benchmark/compatibility.json" >&2
  echo "distributed-proof-test: native runner did not publish fingerprint-bound compatibility evidence" >&2
  exit 1
}
if rg -F 'distributed-proof-token' "${native_artifacts}" >/dev/null; then
  echo "distributed-proof-test: native runner leaked the fixture token into evidence" >&2
  exit 1
fi

# A lost agent must abort the whole merge by default. No successful shard is
# relabeled as a complete distributed result.
if "${PYTHON}" "${agent}" controller --allow-insecure-local --agents "${agent_a},${missing}" --shards 2 \
    --target-origin "${target}" --duration-seconds 1 --connections 2 --run-id distributed-closed \
    --artifact-dir "${work}/closed" >"${work}/closed.out" 2>&1; then
  echo "distributed-proof-test: missing agent did not fail closed" >&2
  exit 1
fi
jq -e '.status == "failed-closed" and (.lostAgents | length == 1) and .aggregate? == null' \
  "${work}/closed/benchmark/distributed-aggregate.json" >/dev/null || {
  cat "${work}/closed/benchmark/distributed-aggregate.json" >&2
  echo "distributed-proof-test: failed-closed evidence is incomplete" >&2
  exit 1
}

# Partial aggregation is an explicit opt-in and remains visibly partial.
"${PYTHON}" "${agent}" controller --allow-insecure-local --allow-partial --agents "${agent_a},${missing}" --shards 2 \
  --target-origin "${target}" --duration-seconds 1 --connections 2 --run-id distributed-partial \
  --artifact-dir "${work}/partial" >"${work}/partial.out"
jq -e '.status == "partial" and .partialLoss == true and (.lostAgents | length == 1) and (.aggregate.requests > 0)' \
  "${work}/partial/benchmark/distributed-aggregate.json" >/dev/null || {
  cat "${work}/partial/benchmark/distributed-aggregate.json" >&2
  echo "distributed-proof-test: explicit partial merge was not marked partial" >&2
  exit 1
}

echo "distributed proof passed: native controller and run-scenario executed authenticated k6 segments with target-proven unique partitions, histogram merge, fail-closed loss, and explicit partial-loss evidence"
