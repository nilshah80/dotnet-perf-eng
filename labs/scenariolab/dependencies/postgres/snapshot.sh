#!/usr/bin/env bash
# scenariolab PROJECT probe -- postgres snapshot phase.
#
# Captures the deep-page order query plan for the order-history scenarios
# (GET /api/customers/<id>/orders), derived from PERF_METHOD/PERF_PATH exported
# by run-scenario.sh. Previously it EXPLAINed one fixed order query for EVERY
# scenario, so catalog, runtime/threading, runtime/memory, cache, pool, and
# order-publish scenarios -- none of which run this query -- were all given an
# orders plan that misrepresented them. Now non-order scenarios get an explicit
# skip marker instead of a misleading plan. Lives in the lab because the
# `orders` table, its columns, and the OFFSET are scenariolab schema knowledge.
#
# Output: dependencies/postgres-query-plan.json -- either an EXPLAIN (ANALYZE,
# BUFFERS, FORMAT JSON) array, or {"skipped":true,"reason":...}.
set -euo pipefail
# The shared adapter that invokes this hook exports PERFLAB_HARNESS_ROOT.
# shellcheck disable=SC1091
source "${PERFLAB_HARNESS_ROOT}/core/lib/common.sh"   # compose, pg_* config
artifact_dir="${1:?snapshot hook needs <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"
plan_file="${artifact_dir}/dependencies/postgres-query-plan.json"

# Deadlock + rollback counters -- the definitive evidence for the deadlock
# scenario (S27), captured for every scenario (deadlocks=0 for the rest). These
# are cumulative since the last stats reset, so on a fresh stack the count
# reflects this run; read it as a delta if the stack has served earlier runs.
compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -c \
  "COPY (SELECT datname, numbackends, xact_commit, xact_rollback, deadlocks FROM pg_stat_database WHERE datname='${pg_db}') TO STDOUT WITH CSV HEADER" \
  > "${artifact_dir}/dependencies/postgres-deadlocks.csv" 2>/dev/null || true

method="${PERF_METHOD:-GET}"
full_path="${PERF_PATH:-}"
base_path="${full_path%%\?*}"
query_string=""
[[ "${full_path}" == *\?* ]] && query_string="${full_path#*\?}"

qs_param() { local name="$1"; printf '%s' "${query_string}" | tr '&' '\n' | sed -n "s/^${name}=//p" | head -1; }
clamp() {
  local v="$1" lo="$2" hi="$3"
  [[ "${v}" =~ ^[0-9]+$ ]] || { printf '%s' "${lo}"; return; }
  v=$((10#${v}))
  (( v < lo )) && v="${lo}"
  (( v > hi )) && v="${hi}"
  printf '%s' "${v}"
}
emit_skip() {
  printf '{"skipped":true,"reason":"%s","scenarioId":"%s","method":"%s","path":"%s"}\n' \
    "$(json_escape "$1")" "$(json_escape "${PERF_SCENARIO:-}")" "$(json_escape "${method}")" "$(json_escape "${full_path}")" \
    > "${plan_file}"
}

# Only the order-history read scenarios (GET /api/customers/<id>/orders) run the
# query this plan represents.
if [[ "${method}" == "GET" && "${base_path}" == /api/customers/*/orders ]]; then
  cust="${base_path#/api/customers/}"; cust="${cust%%/*}"
  [[ "${cust}" =~ ^[0-9]+$ ]] || cust=1
  page="$(clamp "$(qs_param page)" 1 100000)"
  page_size="$(clamp "$(qs_param pageSize)" 1 1000)"
  offset=$(( (page - 1) * page_size ))
  sql="SELECT id, created_at, total, status FROM orders WHERE customer_id=${cust} ORDER BY created_at DESC, id DESC OFFSET ${offset} LIMIT ${page_size}"
  # Wrap with the query + a caveat: this is only the PARENT order query. The
  # order-history scenarios' headline cost (e.g. S07's N+1 item queries) lives in
  # additional statements not visible in a single plan -- see pg_stat_statements.
  explain_json="$(compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -t -A -c \
    "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${sql}" 2>/dev/null || true)"
  if [[ "${explain_json}" == \[* ]]; then
    printf '{"query":"%s","note":"%s","plan":%s}\n' \
      "$(json_escape "${sql}")" \
      "$(json_escape "Parent order query only; per-order child queries (N+1) and other statements are not visible in one plan -- consult postgres-statements.csv (pg_stat_statements).")" \
      "${explain_json}" > "${plan_file}"
  else
    emit_skip "EXPLAIN returned no plan for this scenario"
  fi
else
  emit_skip "no order-history query for path ${base_path}"
fi
