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
#            $SERVICE_NAME     -> descriptor telemetry service-name regex
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
# Roles whose ABSENCE is a capture failure rather than a property of the
# workload. Under any load a .NET process has CPU, a working set, a GC heap, a
# thread pool and served requests -- an empty series for one of these means the
# scrape, the selector or the instrumentation broke, not that the process was
# idle. Everything else is conditional: database_pool_metrics is legitimately
# empty for a scenario that never touches the database, and calling that
# "missing evidence" would mark a correct package incomplete.
PERFLAB_REQUIRED_METRIC_ROLES="process_cpu working_set gc_heap thread_pool_queue request_duration"

PERFLAB_METRIC_ROLES=(
  'process_cpu|range|rate(dotnet_process_cpu_time_seconds_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}[$RATE_WINDOW])'
  'working_set|range|dotnet_process_memory_working_set_bytes{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'gc_heap|range|dotnet_gc_last_collection_heap_size_bytes{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'thread_pool_queue|range|dotnet_thread_pool_queue_length_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  # $PHASE selects the measured phase when the target verified perflab-baggage-v1
  # (D-P1-8); only the request-duration metric carries that label.
  'request_duration|range|http_server_request_duration_seconds_count{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"$PHASE}'
  'gc_allocation_rate|range|rate(dotnet_gc_heap_allocated_bytes_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}[$RATE_WINDOW])'
  'gc_committed|range|dotnet_gc_last_collection_memory_committed_size_bytes{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'gc_collections|range|dotnet_gc_collections_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'gc_pause|range|rate(dotnet_gc_pause_time_seconds_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}[$RATE_WINDOW])'
  'database_pool_metrics|range|{__name__=~"(db_client_connection_.*|db_client_operation_npgsql_.*|npgsql_.*)",service_instance_id=~"$SERVICE_INSTANCE"}'
  'http_client_metrics|range|{__name__=~"http_client_.*",service_instance_id=~"$SERVICE_INSTANCE"}'
  # Saturation signals the USE-method classifier (analyze/bottleneck.sh) needs and
  # nothing else captured yet. lock_contention is THE bottleneck for this lab's pool
  # scenarios (S21-S26): a rate of Monitor contentions/sec. cpu_count normalizes CPU
  # from "cores busy" (process_cpu) into a utilisation FRACTION (cores_busy/cpu_count),
  # so the classifier can say "CPU-bound" without hardcoding the host core count.
  # thread_count pairs with thread_pool_queue to tell "starved" (queue grows while
  # threads plateau) from "just busy". A runtime without these emits empty files and
  # the classifier degrades that dimension to "not captured" -- never a false verdict.
  'lock_contention|range|rate(dotnet_monitor_lock_contentions_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}[$RATE_WINDOW])'
  'cpu_count|instant|dotnet_process_cpu_count{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  'thread_count|range|dotnet_thread_pool_thread_count_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}'
  # Exceptions thrown per second by type. Exception pressure otherwise reads only
  # as its CPU cost (P11: ~500 InvalidOperationException per request, verdict
  # cpu-bound); the exceptions profile names the call site but is sampled.
  'exceptions|range|sum by(error_type) (rate(dotnet_exceptions_total{job=~"$JOB",service_instance_id=~"$SERVICE_INSTANCE"}[$RATE_WINDOW]))'
  # Server and dependency time from Tempo span metrics, by the dependency a
  # client or producer span calls (the lab Tempo config adds these dimensions).
  # Npgsql metrics measure only PostgreSQL; a Redis, HTTP-upstream or broker
  # wait had no time share (S13, S26). Span metrics carry no instance label, so
  # the measured window scopes them.
  'dependency_time|range|sum by(span_kind,db_system,db_system_name,messaging_system,server_address) (rate(traces_spanmetrics_latency_sum{service=~"$SERVICE_NAME",span_kind=~"SPAN_KIND_(SERVER|CLIENT|PRODUCER)"}[$RATE_WINDOW]))'
  'dependency_calls|range|sum by(span_kind,db_system,db_system_name,messaging_system,server_address) (rate(traces_spanmetrics_calls_total{service=~"$SERVICE_NAME",span_kind=~"SPAN_KIND_(SERVER|CLIENT|PRODUCER)"}[$RATE_WINDOW]))'
)
