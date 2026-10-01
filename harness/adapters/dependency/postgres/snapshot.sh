#!/usr/bin/env bash
# postgres dependency adapter -- post-run snapshot for the evidence package.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?snapshot.sh <artifact-dir>}"
dep="${artifact_dir}/dependencies"; mkdir -p "${dep}"

compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -c \
  "COPY (SELECT queryid, calls, rows, round(total_exec_time::numeric,2) AS total_exec_ms, round(mean_exec_time::numeric,2) AS mean_exec_ms, shared_blks_hit, shared_blks_read, temp_blks_written, left(regexp_replace(query, '\s+', ' ', 'g'), 300) AS query FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname='${pg_db}') ORDER BY total_exec_time DESC LIMIT 50) TO STDOUT WITH CSV HEADER" \
  > "${dep}/postgres-statements.csv"

compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -c \
  "COPY (SELECT pid, application_name, wait_event_type, wait_event, state, backend_start, state_change, left(query,300) AS query FROM pg_stat_activity WHERE datname='${pg_db}' ORDER BY pid) TO STDOUT WITH CSV HEADER" \
  > "${dep}/postgres-activity.csv"

compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -c \
  "COPY (SELECT application_name, state, count(*) AS connections, min(backend_start) AS oldest_backend FROM pg_stat_activity WHERE datname='${pg_db}' GROUP BY application_name, state ORDER BY application_name, state) TO STDOUT WITH CSV HEADER" \
  > "${dep}/postgres-connections.csv"

# Project-specific query-plan probes (EXPLAIN of a named query, checks of a named
# table/index) live in the LAB, not here: <lab>/dependencies/postgres/snapshot.sh.
# The three generic captures above work for any postgres-backed lab.
# Transaction, rollback and deadlock counters, plus the server's connection
# limit. The counters are cumulative since the last stats reset, so the raw file
# carries every earlier run on this stack; postgres-deadlocks-delta.json
# subtracts the post-warm-up baseline written by reset-stats.sh and is the count
# for this measured window (S27's planted deadlock, in any lab).
compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -c \
  "COPY (SELECT datname, numbackends, xact_commit, xact_rollback, deadlocks, current_setting('max_connections')::int AS max_connections FROM pg_stat_database WHERE datname='${pg_db}') TO STDOUT WITH CSV HEADER" \
  > "${dep}/postgres-deadlocks.csv" 2>/dev/null || rm -f "${dep}/postgres-deadlocks.csv"
if [[ -s "${dep}/postgres-deadlocks-preload.csv" && -s "${dep}/postgres-deadlocks.csv" ]]; then
  # A negative difference means the counters were reset in between: no delta.
  awk -F, 'NR == FNR { if (FNR == 2) { c = $3; r = $4; d = $5 } next }
    FNR == 2 {
      if ($3 < c || $4 < r || $5 < d) print "{\"scope\":\"not-comparable\",\"reason\":\"pg_stat_database counters were reset during the run\"}"
      else printf "{\"scope\":\"measured-window\",\"xactCommit\":%d,\"xactRollback\":%d,\"deadlocks\":%d}\n", $3 - c, $4 - r, $5 - d
    }' "${dep}/postgres-deadlocks-preload.csv" "${dep}/postgres-deadlocks.csv" > "${dep}/postgres-deadlocks-delta.json" || true
fi

run_lab_dependency_hook postgres snapshot "${artifact_dir}"
