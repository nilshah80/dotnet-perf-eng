#!/usr/bin/env bash
# postgres dependency adapter -- post-run snapshot for the evidence package.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?snapshot.sh <artifact-dir>}"
dep="${artifact_dir}/dependencies"; mkdir -p "${dep}"

compose exec -T postgres psql -U perflab -d perflab -c \
  "COPY (SELECT queryid, calls, rows, round(total_exec_time::numeric,2) AS total_exec_ms, round(mean_exec_time::numeric,2) AS mean_exec_ms, shared_blks_hit, shared_blks_read, temp_blks_written, left(regexp_replace(query, '\s+', ' ', 'g'), 300) AS query FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname='perflab') ORDER BY total_exec_time DESC LIMIT 50) TO STDOUT WITH CSV HEADER" \
  > "${dep}/postgres-statements.csv"

compose exec -T postgres psql -U perflab -d perflab -c \
  "COPY (SELECT pid, application_name, wait_event_type, wait_event, state, backend_start, state_change, left(query,300) AS query FROM pg_stat_activity WHERE datname='perflab' ORDER BY pid) TO STDOUT WITH CSV HEADER" \
  > "${dep}/postgres-activity.csv"

compose exec -T postgres psql -U perflab -d perflab -c \
  "COPY (SELECT application_name, state, count(*) AS connections, min(backend_start) AS oldest_backend FROM pg_stat_activity WHERE datname='perflab' GROUP BY application_name, state ORDER BY application_name, state) TO STDOUT WITH CSV HEADER" \
  > "${dep}/postgres-connections.csv"

compose exec -T postgres psql -U perflab -d perflab -t -A -c \
  "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id, created_at, total, status FROM orders WHERE customer_id=1 ORDER BY created_at DESC, id DESC OFFSET 2475 LIMIT 25" \
  > "${dep}/postgres-order-plan.json"
