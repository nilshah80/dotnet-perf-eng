#!/usr/bin/env bash
# dotnet runtime adapter -- Prometheus metric map.
#
# capture-evidence.sh (core) sources this file and iterates PERFLAB_METRIC_ROLES.
# Each entry is "file|type|promql":
#   file   output name under telemetry/metrics/<file>.json
#   type   range  -> query_range over the run window (gauges and rates)
#          instant-> instant query at capture time (cumulative counters, label sets)
#   promql placeholders substituted by the core:
#            $JOB              -> descriptor telemetry.promJobRegex
#            $RUN_ID           -> telemetry run id
#            $SERVICE_INSTANCE -> service_instance_id regex derived from the run
#
# Single-quoted entries keep $JOB/$RUN_ID/$SERVICE_INSTANCE literal until the
# core substitutes them.
#
# Range vs instant is deliberate: gauges and rates must be read over the run
# window, because an instant query taken after the load stops reports an idle
# process and hides the peak the metric exists to show (thread-pool queueing,
# heap growth, CPU saturation). Cumulative counters are already run totals at a
# single read, so they stay instant.
#
# To port this adapter to another runtime, copy this file and swap the metric
# names for that runtime's exporter (e.g. nodejs_*, process_runtime_go_*,
# jvm_*). The core, facts.json, and the AI phase never see these names.

# Every selector is scoped by BOTH job and service_instance_id. The instance
# filter ($SERVICE_INSTANCE, derived by the core from this run's app metrics) is
# essential: the observability backend is long-lived and Prometheus keeps stale
# gauge series (working_set, gc_heap, thread_pool_queue) from earlier restarted
# app processes for the staleness window. A job-only selector therefore returns
# several dead instances alongside the live one, and any cross-instance
# aggregation is wrong. Scoping to the correlated instance keeps each file to the
# process this run actually measured.
PERFLAB_METRIC_ROLES=(
  'process_cpu|range|rate(dotnet_process_cpu_time_seconds_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}[1m])'
  'working_set|range|dotnet_process_memory_working_set_bytes{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'gc_heap|range|dotnet_gc_last_collection_heap_size_bytes{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'thread_pool_queue|range|dotnet_thread_pool_queue_length_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'request_duration|range|http_server_request_duration_seconds_count{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'gc_allocation_rate|range|rate(dotnet_gc_heap_allocated_bytes_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}[1m])'
  'gc_committed|range|dotnet_gc_last_collection_memory_committed_size_bytes{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'gc_collections|range|dotnet_gc_collections_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'gc_pause|range|rate(dotnet_gc_pause_time_seconds_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}[1m])'
  'database_pool_metrics|instant|{__name__=~"(db_client_connection_.*|db_client_operation_npgsql_.*|npgsql_.*)",service_instance_id=~"$SERVICE_INSTANCE"}'
  'http_client_metrics|instant|{__name__=~"http_client_.*",service_instance_id=~"$SERVICE_INSTANCE"}'
)
