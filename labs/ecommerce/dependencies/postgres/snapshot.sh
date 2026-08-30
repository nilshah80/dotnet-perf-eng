#!/usr/bin/env bash
# ecommerce PROJECT probe -- postgres snapshot phase.
#
# Captures the query plan of the LIST query the current scenario actually
# measures, derived from PERF_METHOD/PERF_PATH (exported by run-scenario.sh).
# Previously this always EXPLAINed one fixed deep-page products query, so every
# scenario -- login, orders, users, get-by-id, and writes included -- was given a
# products plan that did not represent it, and the search scenario (E05) got a
# plan with no ILIKE predicate. Now the plan matches the scenario's own dominant
# query, or is skipped with an explicit marker when the scenario has no
# representative list query (writes, get-by-id, /users/me, login). Lives in the
# lab, not the shared adapter, because the tables/columns are ecommerce schema.
#
# Output: dependencies/postgres-query-plan.json -- either an EXPLAIN (ANALYZE,
# BUFFERS, FORMAT JSON) array, or {"skipped":true,"reason":...}.
set -euo pipefail
# shellcheck disable=SC1091
source "${PERFLAB_HARNESS_ROOT}/core/lib/common.sh"   # compose, pg_* config
artifact_dir="${1:?snapshot hook needs <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"
plan_file="${artifact_dir}/dependencies/postgres-query-plan.json"

method="${PERF_METHOD:-GET}"
full_path="${PERF_PATH:-}"
base_path="${full_path%%\?*}"
query_string=""
[[ "${full_path}" == *\?* ]] && query_string="${full_path#*\?}"

# First value of a query-string parameter; the lab's scenario values are ASCII so
# no URL-decoding is needed.
qs_param() { local name="$1"; printf '%s' "${query_string}" | tr '&' '\n' | sed -n "s/^${name}=//p" | head -1; }

# Clamp to the app's own bounds (Program.cs Math.Clamp: page 1..100000,
# pageSize 1..100); 10# forces base-10 so a value like 08 is not read as octal.
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

if [[ "${method}" != "GET" ]]; then
  emit_skip "no read query plan for a ${method} write scenario"
  exit 0
fi

page="$(clamp "$(qs_param page)" 1 100000)"
page_size="$(clamp "$(qs_param pageSize)" 1 100)"
offset=$(( (page - 1) * page_size ))
search="$(qs_param search)"

sql=""
case "${base_path}" in
  /api/products)
    predicate="is_active"
    if [[ -n "${search}" ]]; then
      esc="${search//\'/\'\'}"   # escape single quotes for the SQL string literal
      predicate="is_active AND name ILIKE '%${esc}%'"
    fi
    sql="SELECT id, name, description, price, stock, category_id FROM products WHERE ${predicate} ORDER BY id OFFSET ${offset} LIMIT ${page_size}"
    ;;
  /api/orders)
    sql="SELECT id, created_at FROM orders WHERE user_id = 1 ORDER BY created_at DESC, id DESC OFFSET ${offset} LIMIT ${page_size}"
    ;;
  /api/users)
    sql="SELECT id FROM users ORDER BY id OFFSET ${offset} LIMIT ${page_size}"
    ;;
  *)
    emit_skip "no representative list query for path ${base_path}"
    exit 0
    ;;
esac

compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -t -A -c \
  "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${sql}" \
  > "${plan_file}"
