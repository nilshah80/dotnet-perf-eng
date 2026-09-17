#!/usr/bin/env bash

PERFLAB_PROJECT="protocol-reliability"
PERFLAB_RUNTIME="dotnet"

PERFLAB_COMPOSE_FILE="labs/protocol-reliability/compose.yaml"
PERFLAB_APP_SERVICES="api-a api-b gateway"
PERFLAB_PRIMARY_APP_SERVICE="api-a"
PERFLAB_BASE_URL="${PERFLAB_BASE_URL:-http://127.0.0.1:18080}"
PERFLAB_READY_URL="${PERFLAB_READY_URL:-http://127.0.0.1:18080/health/ready}"
PERFLAB_INTERNAL_BASE_URL="http://gateway:8080"
PERFLAB_COMPOSE_NETWORK="protocol-reliability_default"

PERFLAB_PROM_JOB_REGEX="protocol-reliability-.*"
PERFLAB_SERVICE_NAME_REGEX="protocol-reliability-(a|b)"
PERFLAB_RUN_ID_ATTR="perf.run.id"
PERFLAB_APP_METRIC_PREFIX="protocol_reliability"

PERFLAB_PROMETHEUS_URL="http://127.0.0.1:19090"
PERFLAB_TEMPO_URL="http://127.0.0.1:13200"
PERFLAB_LOKI_URL="http://127.0.0.1:13100"
PERFLAB_PYROSCOPE_URL="http://127.0.0.1:14040"
PERFLAB_DIAGNOSTICS_URL="http://127.0.0.1:19323"
# The /stacks in-process channel cannot cross Docker network namespaces in this
# shared sidecar topology. Keep the requested kind in provenance and use the
# runtime adapter's sampled-stack trace fallback; dump analysis still captures
# an instantaneous clrstack -all snapshot.
PERFLAB_ENABLE_DOTNET_MONITOR_STACKS="false"
PERFLAB_PYROSCOPE_SERVICES="protocol-reliability-a protocol-reliability-b"
PERFLAB_PYROSCOPE_REQUIRED_SERVICES="protocol-reliability-a protocol-reliability-b"
PERFLAB_PYROSCOPE_ROLE_SERVICES="api-a:protocol-reliability-a api-b:protocol-reliability-b"
PERFLAB_PROFILING_MIN_CORES_THRESHOLD="0.1"
PERFLAB_PROFILING_SERVICE_QUOTAS="api-a=0.5 api-b=0.5"
PERFLAB_PROFILING_QUOTA_SOURCE="compose.cpus"

PERFLAB_DEPENDENCIES=""
PERFLAB_ARTIFACTS_ROOT="artifacts"
PERFLAB_SCENARIOS="labs/protocol-reliability/scenarios.tsv"
PERFLAB_CATALOG="labs/protocol-reliability/catalog.json"
PERFLAB_WORKLOAD_MANIFEST="labs/protocol-reliability/workload-manifest.json"
PERFLAB_LOAD_GENERATOR_DEFAULT="k6"
PERFLAB_K6_SCRIPT="labs/protocol-reliability/loadgen/k6.js"
PERFLAB_JMETER_PLAN="labs/protocol-reliability/loadgen/test-plan.jmx"
PERFLAB_DIAG_TARGETS="api-a:ProtocolReliability.Api api-b:ProtocolReliability.Api"
PERFLAB_DIAG_PRESETS="trace gcdump stacks dump"
PERFLAB_ADMIN_TOKEN="${PERFLAB_ADMIN_TOKEN:-protocol-reliability-local}"
PERF_GRPC_TARGET="${PERF_GRPC_TARGET:-127.0.0.1:18081}"
export PERFLAB_ADMIN_TOKEN PERF_GRPC_TARGET
