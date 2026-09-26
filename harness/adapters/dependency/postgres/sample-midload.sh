#!/usr/bin/env bash
# postgres dependency adapter -- live sample taken mid-measurement, when pool
# usage and connection state are at their peak (invisible once load stops).
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?sample-midload.sh <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"
fail=0
# A failed sample leaves no file rather than an empty CSV that reads as "no
# connections".
sample() { # sample <file> <query>
  if compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -c "COPY ($2) TO STDOUT WITH CSV HEADER" > "$1.tmp" 2>/dev/null; then
    mv "$1.tmp" "$1"
  else
    rm -f "$1.tmp"; fail=1
  fi
}
# Sessions by state and wait event, with how many are blocked by another
# session: row-lock contention shows as active sessions waiting on Lock behind
# an 'idle in transaction' holder, which a count by state alone cannot show.
sample "${artifact_dir}/dependencies/postgres-connections-midload.csv" \
  "SELECT application_name, state, coalesce(wait_event_type, '') AS wait_event_type, coalesce(wait_event, '') AS wait_event, count(*) AS connections, count(*) FILTER (WHERE cardinality(pg_blocking_pids(pid)) > 0) AS blocked FROM pg_stat_activity WHERE datname='${pg_db}' GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3, 4"
# The sessions others wait behind, with what they hold the transaction open for.
sample "${artifact_dir}/dependencies/postgres-lock-holders-midload.csv" \
  "SELECT h.pid, h.application_name, h.state, round(extract(epoch FROM now() - h.xact_start)::numeric * 1000) AS xact_age_ms, count(*) AS waiters, left(regexp_replace(h.query, '\s+', ' ', 'g'), 200) AS last_query FROM pg_stat_activity w CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS b(pid) JOIN pg_stat_activity h ON h.pid = b.pid WHERE w.datname='${pg_db}' GROUP BY h.pid, h.application_name, h.state, h.xact_start, h.query ORDER BY waiters DESC LIMIT 5"

run_lab_dependency_hook postgres sample-midload "${artifact_dir}" || fail=1
# Exit non-zero if any capture failed so the parent's (non-fatal) mid-load warning
# fires; mid-load evidence is best-effort, so this does NOT mark the package partial.
exit "${fail}"
