#!/usr/bin/env bash
# postgres dependency adapter -- content fingerprint of the prepared dataset.
#
# A declared seed scale says what was ASKED for; this says what is actually
# there. Two runs over different data are not comparable, and a reset that
# silently half-restored produces the same declared scale as one that worked --
# so the declaration cannot tell them apart and a comparison over it is unsound.
#
# Row counts per user table, in a stable order, excluding the harness's
# perflab_seed snapshot (restore-seed.sql). Not a checksum of every row:
# that would be slow on a large seed and would change with every measurement
# write, which is not what "was the dataset restored" is asking.
#
# Exact count(*), not pg_stat_user_tables.n_live_tup: that column is a
# statistics estimate that autovacuum and ANALYZE revise, so identical data
# produced different fingerprints (products read 282,826 against an exact
# 282,827 after an update-only run) and valid comparisons were refused.
set -euo pipefail
# Failures are NOT suppressed. A fingerprint that silently returns nothing is
# indistinguishable from an empty dataset, and the caller would hash the empty
# result and call the dataset identified.
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"

compose exec -T "${pg_service}" \
  psql -X -v ON_ERROR_STOP=1 -U "${pg_user}" -d "${pg_db}" -At -F':' <<'SQL'
SELECT 'SELECT t, c FROM (' ||
       string_agg(format('SELECT %L AS t, count(*) AS c FROM %I.%I', relname, schemaname, relname), ' UNION ALL ') ||
       ') counts ORDER BY t'
FROM pg_stat_user_tables
WHERE schemaname <> 'perflab_seed'
\gexec
SQL
