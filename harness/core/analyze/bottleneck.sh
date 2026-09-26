#!/usr/bin/env bash
# USE-method bottleneck classifier. Every signal a performance engineer reads to
# answer "what IS the bottleneck?" is already captured (CPU, GC, thread-pool queue,
# lock contention, DB pool, per-request efficiency) and dashboarded -- but the
# ANSWER is left to a human eyeballing panels or to the non-deterministic AI phase.
# This turns the captured evidence into a reproducible verdict.
#
# It reads facts.json (per-request efficiency + client latency/throughput) and the
# captured runtime metric files (telemetry/metrics/*.json), decomposes a typical
# request into CPU / GC-pause / DB / other time, and combines that with the
# Utilization + Saturation signals per resource (Brendan Gregg's USE method):
#   CPU        util = cores_busy/cpu_count;      saturation = thread-pool queue
#   GC/memory  util = pause fraction;            saturation = pause fraction high
#   thread pool                                  saturation = queue length > 0
#   locks                                        saturation = contentions / request
#   DB pool    util = used/max;                  saturation = pending requests > 0
#   dependency util = DB-time share of a request
# then names the resource with the strongest evidence. It reports; it never blames a
# resource whose signal was not captured (that dimension degrades to "not captured").
# Writes analysis/bottleneck.json.
#
#   bottleneck.sh <run-dir>
# Tunable gates (env): PERFLAB_USE_CPU_SAT (0.85), _TPQ_SAT (2), _GC_SAT (0.10),
#   _LOCK_SAT (1.0 contentions/req), _DEP_SHARE (0.50); wait-bound:
#   PERFLAB_WAIT_CPU_SHARE (0.10), PERFLAB_WAIT_MIN_P50_MS (50); notes:
#   PERFLAB_ALLOC_BYTES_PER_REQUEST_NOTE (1 MiB) with PERFLAB_ALLOC_RATE_NOTE
#   (100 MiB/s), PERFLAB_EXCEPTIONS_PER_REQUEST_NOTE (1); database:
#   PERFLAB_DEADLOCK_SAT (0.01 of transactions), PERFLAB_ROWLOCK_MIN_WAITERS (4);
#   PERFLAB_STAMPEDE_MISSES_PER_EXPIRY (10); blocked threads:
#   PERFLAB_THREAD_BLOCK_MIN (32) and PERFLAB_THREAD_BLOCK_PER_CORE (16);
#   amplification: PERFLAB_AMPLIFICATION_PER_REQUEST (10); database time outside
#   the server: PERFLAB_DB_SERVER_SHARE (0.25).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"

run_arg="${1:?bottleneck.sh <run-dir>}"
[[ -d "${run_arg}" ]] || { echo "bottleneck: '${run_arg}' is not a run directory." >&2; exit 2; }
facts="${run_arg}/facts.json"
[[ -s "${facts}" ]] || { echo "bottleneck: no facts.json under '${run_arg}'." >&2; exit 2; }
mdir="${run_arg}/telemetry/metrics"
mkdir -p "${run_arg}/analysis"
out="${run_arg}/analysis/bottleneck.json"

scenario="$(jqd -r '.scenarioId // ""' < "${facts}" 2>/dev/null || echo "")"
run_id="$(jqd -r '.telemetryRunId // .runId // ""' < "${facts}" 2>/dev/null || echo "")"
status="$(jqd -r '.status // "unknown"' < "${facts}" 2>/dev/null || echo unknown)"

# Browser HTTP subrequests do not certify backend load-generator capacity.
if jqd -e 'any(.observations[]?; .name == "browser.visits.total")' < "${facts}" >/dev/null; then
  jqd -n --arg runId "${run_id}" --arg scenarioId "${scenario}" '{kind:"bottleneck",runId:$runId,scenarioId:$scenarioId,verdict:"not-applicable",confidence:"low",reason:"browser synthetic metrics are separate from backend load-generator SLIs"}' > "${out}"
  exit 0
fi

# --- observation scalars from facts.json (one jqd call) ---------------------
obs() { jqd -r --arg n "$1" '((.observations // [])[]? | select(.name==$n) | .value) // empty' < "${facts}" 2>/dev/null | head -1; }
rps="$(obs http.requests_per_second)"
p50="$(obs http.latency.p50)"; p99="$(obs http.latency.p99)"
errate="$(obs http.error_rate)"; dropped="$(obs http.dropped_iterations)"
eff_cpu="$(obs efficiency.cpu_ms_per_request)"
eff_gc="$(obs efficiency.gc_pause_ms_per_request)"
eff_db="$(obs efficiency.db_ms_per_request)"
eff_alloc="$(obs efficiency.alloc_bytes_per_request)"

# --- captured-metric scalars ------------------------------------------------
# All numeric points from either a range (.values) or instant (.value) result.
jq_points='[ .data.result[]? as $r | (($r.values // (if $r.value then [$r.value] else [] end)))[] | .[1] ] | map(tonumber)'
mstat() { # <file> <max|avg|last> -> scalar or "" if the file/series is absent/empty
  local f="${mdir}/$1.json"; [[ -s "${f}" ]] || return 0
  jqd -r "${jq_points} | if length==0 then empty elif \"$2\"==\"max\" then max elif \"$2\"==\"avg\" then (add/length) else .[-1] end" < "${f}" 2>/dev/null | head -1
}
# Sum ACROSS series per timestamp before reducing. process_cpu.json carries separate
# cpu_mode="user" and cpu_mode="system" series; total cores busy is user+system aligned
# per timestamp, so taking max over the individual series (mstat) understates CPU and
# can miss a saturated core (verified on S04: 75.8% single-series vs 98.6% summed).
mstat_sum() { # <file> <max|avg>
  local f="${mdir}/$1.json"; [[ -s "${f}" ]] || return 0
  jqd -r "[ .data.result[]? as \$r | (\$r.values // (if \$r.value then [\$r.value] else [] end))[] | {t:.[0], v:(.[1]|tonumber)} ]
    | group_by(.t) | map(reduce .[] as \$x (0; .+\$x.v))
    | if length==0 then empty elif \"$2\"==\"max\" then max else (add/length) end" < "${f}" 2>/dev/null | head -1
}
# DB pool utilisation must be used/max WITHIN a pool. A scenario can run a bounded pool
# (e.g. Max Pool Size=2) beside the default (20); taking max(used)/max(size) across ALL
# pools pairs used=2 with size=20 (10%) and hides a 2/2 saturation. Join by
# db_client_connection_pool_name; rank by PENDING first (waiters are the actual
# saturation signal), then utilisation -- so a 19/20 pool with 50 waiters is picked over
# a full-but-idle 1/1 pool with none. Report that pool's own used/max/pending.
#
# The per-state "used" gauge alone can contradict the saturation it is quoted
# for: S09's leaked connections sat outside the pool's accounting (used 0/20,
# 64 waiting), so the pool is also described by its acquisition timeouts in the
# window, the connections it has created, and how many commands were executing.
# Npgsql counts a returned connection idle until the waiter's continuation takes
# it, so the "used" peak understates a full pool while requests wait (E12: 14
# used, 20 connections, 6 waiting). Used plus idle at one sample is the pool's
# connection count; waiting requests imply it is at its maximum.
dbpool_worst() { # -> "usedPeak maxCfg pendingPeak timeouts createdTotal executingPeak idlePeak createdInWindow totalPeak" (one per line)
  local f="${mdir}/database_pool_metrics.json"; [[ -s "${f}" ]] || return 0
  jqd -r '
    def points: (.values // (if .value then [.value] else [] end)) | sort_by(.[0]) | map(.[1]|tonumber);
    def increase: . as $a | if length < 2 then 0 else reduce range(1; length) as $i (0;
      . + (if $a[$i] >= $a[$i-1] then $a[$i] - $a[$i-1] else $a[$i] end)) end;
    [ .data.result[]?
      | points as $p
      | { pool: (.metric.db_client_connection_pool_name // "default"),
          inst: (.metric.service_instance_id // ""),
          nm:   (.metric.__name__ // ""),
          st:   (.metric.db_client_connection_state // ""),
          peak: ($p | if length==0 then 0 else max end),
          last: ($p | if length==0 then 0 else last end),
          grew: ($p | increase),
          pts: (if (.metric.__name__ // "") == "db_client_connection_count" then (.values // []) else [] end) } ]
    # Replicas and workers share a connection string: each process has its own pool.
    | group_by([.pool, .inst])
    | map({ used: ([ .[] | select(.nm=="db_client_connection_count" and .st=="used") | .peak ] | max // 0),
            idle: ([ .[] | select(.nm=="db_client_connection_count" and .st=="idle") | .peak ] | max // 0),
            madewin: ([ .[] | select(.nm | test("create_time_seconds_count$")) | .grew ] | add // 0),
            maxc: ([ .[] | select(.nm=="db_client_connection_max") | .peak ] | max // 0),
            pend: ([ .[] | select(.nm | test("pending_requests")) | .peak ] | max // 0),
            tmo:  ([ .[] | select(.nm | test("timeouts_total$")) | .grew ] | add // 0),
            made: ([ .[] | select(.nm | test("create_time_seconds_count$")) | .last ] | add // 0),
            exec: ([ .[] | select(.nm | test("operation(_npgsql)?_executing$")) | .peak ] | max // -1),
            total: ([ .[] | .pts[] ] | group_by(.[0]) | map(map(.[1]|tonumber) | add) | max // 0) })
    | map(. + {util: (if .maxc>0 then .used/.maxc else 0 end)})
    # pending dominates the ranking; utilisation breaks ties.
    | (sort_by([.pend, .util]) | last) // {used:0,maxc:0,pend:0,tmo:0,made:0,exec:-1,idle:0,madewin:0,total:0}
    | "\(.used)\n\(.maxc)\n\(.pend)\n\(.tmo)\n\(.made)\n\(.exec)\n\(.idle)\n\(.madewin)\n\(.total)"' < "${f}" 2>/dev/null
}

# Upstream (HttpClient) connection pool. The exact analogue of dbpool_worst for
# the other pooled resource a request can block on: http_client_request_time_in_queue
# is literally "how long this request waited for a connection", so it needs no
# inference from depth the way the thread-pool queue does.
#
# Ranked by mean wait, which also selects the right pool: the app's own telemetry
# exporter is an HttpClient too, and a run must not be diagnosed on the OTLP
# client's idle connections instead of the dependency the workload calls.
upstream_worst() { # -> "meanWaitSeconds\tactiveRequestsPeak\topenConnectionsPeak\tpool"
  local f="${mdir}/http_client_metrics.json"; [[ -s "${f}" ]] || return 0
  {
    cat "${f}"
    if [[ -s "${run_arg}/environment/measurement-start/resource-limits.json" ]]; then
      cat "${run_arg}/environment/measurement-start/resource-limits.json"
    else printf '[]\n'; fi
  } | jqd -rs '
    def counter_delta($points):
      if ($points|length) < 2 then ($points[0][1]|tonumber)
      else reduce range(1; $points|length) as $i (0;
        ($points[$i][1]|tonumber) as $v | ($points[$i-1][1]|tonumber) as $before |
        . + (if $v >= $before then $v-$before else $v end)) end;
    [.[1][]? | .telemetryExporterAuthority | select(. != null and . != "")] as $exporters |
    [ .[0].data.result[]?
      | select((.metric.server_address // "") as $host |
          (($host + (if .metric.server_port then ":" + .metric.server_port else "" end))) as $authority |
          ($exporters | index($authority)) == null)
      | (.values // (if .value then [.value] else [] end) | sort_by(.[0])) as $points
      | select(($points|length) > 0)
      | { pool: (.metric.server_address // .metric.http_client_connection_pool_name // "default"),
          port: (.metric.server_port // ""), nm:(.metric.__name__ // ""),
          peak: (if (.metric.__name__ // "" | test("time_in_queue_seconds_(sum|count)$"))
            then counter_delta($points) else ($points | map(.[1]|tonumber) | max) end),
          pts: (if (.metric.__name__ // "") == "http_client_open_connections" then $points else [] end) } ]
    | group_by([.pool,.port])
    | map({pool:.[0].pool,
        qsum:([.[]|select(.nm=="http_client_request_time_in_queue_seconds_sum")|.peak]|add // 0),
        qcnt:([.[]|select(.nm=="http_client_request_time_in_queue_seconds_count")|.peak]|add // 0),
        act:([.[]|select(.nm=="http_client_active_requests")|.peak]|max // 0),
        # Open connections are split by state (active/idle). The pool size at an
        # instant is their sum at one timestamp; adding each state peak counted a
        # 2-connection pool as 4, because the idle peak follows the active one.
        conn:([.[]|select(.nm=="http_client_open_connections")|.pts[]] | group_by(.[0])
          | map(map(.[1]|tonumber) | add) | max // 0)})
    | map(. + {wait:(if .qcnt>0 then .qsum/.qcnt else 0 end)})
    | (sort_by(.wait)|last) // empty
    | "\(.wait)\t\(.act)\t\(.conn)\t\(.pool)"' 2>/dev/null | head -1
}

# CPU modes are summed WITHIN an instance and timestamp. Rank instance
# utilization using its own runtime capacity and captured fractional quota.
# Summing replicas against one instance's rounded ProcessorCount is invalid.
cpu_worst() {
  [[ -s "${mdir}/process_cpu.json" ]] || return 0
  {
    cat "${mdir}/process_cpu.json"
    if [[ -s "${mdir}/cpu_count.json" ]]; then cat "${mdir}/cpu_count.json"; else printf '{}\n'; fi
    if [[ -s "${run_arg}/environment/measurement-start/resource-limits.json" ]]; then
      cat "${run_arg}/environment/measurement-start/resource-limits.json"
    else printf '[]\n'; fi
  } | jqd -s '
    def points: [.data.result[]? as $r | ($r.values // (if $r.value then [$r.value] else [] end))[]
      | {instance:($r.metric.service_instance_id // $r.metric.instance // $r.metric.service_name // "default"),
         service:($r.metric.service_name // ""), at:.[0], value:(.[1]|tonumber?)}];
    (.[0]|points) as $usage | (.[1]|points) as $capacity | .[2] as $limits |
    [$usage | group_by([.instance,.at])[] | .[0] as $point | (map(.value)|add) as $busy |
      ([$capacity[] | select(.instance == $point.instance) | .value] | min) as $runtime |
      ([$limits[]? | select(.telemetryService == $point.service and .telemetryService != "" and (.cpuLimit // 0) > 0) | .cpuLimit] | unique) as $quotas |
      (if ($quotas|length) == 1 then $quotas[0] else null end) as $quota |
      ([$runtime,$quota] | map(select(. != null and . > 0)) | min) as $cores |
      select($cores != null) | {instance:$point.instance,service:$point.service,atEpoch:$point.at,
        coresBusy:$busy,capacityCores:$cores,utilization:($busy/$cores),runtimeCores:$runtime,containerQuotaCores:$quota}]
    | sort_by(.utilization) | last // {}' 2>/dev/null
}
cpu_busy_peak=""; cpu_count=""
cpu_evidence="$(cpu_worst || true)"
if [[ -n "${cpu_evidence}" ]]; then
  printf '%s\n' "${cpu_evidence}" > "${run_arg}/analysis/cpu-utilization.json"
  cpu_busy_peak="$(printf '%s' "${cpu_evidence}" | jqd -r '.coresBusy // empty')"
  cpu_count="$(printf '%s' "${cpu_evidence}" | jqd -r '.capacityCores // empty')"
fi
# Require backlog in successive observations of the same process. A single
# spike during a load step is queue pressure, not sustained starvation.
queue_persistence() {
  local f="${mdir}/thread_pool_queue.json"; [[ -s "${f}" ]] || return 0
  jqd -r --argjson rps "${rps:-0}" --argjson depth "${PERFLAB_USE_TPQ_SAT:-2}" --argjson wait "${PERFLAB_USE_TPQ_WAIT_SAT:-0.05}" '
    [.data.result[]? | (.values // (if .value then [.value] else [] end))
      | unique_by(.[0]) | sort_by(.[0])
      | reduce .[] as $point ({count:0,current:0,longest:0};
          .count += 1 |
          if (($point[1]|tonumber) >= $depth and ($rps <= 0 or ($point[1]|tonumber)/$rps >= $wait))
          then .current += 1 else .current = 0 end |
          .longest = ([.longest,.current]|max))]
    | if ([.[].count]|max // 0) < 2 then empty else ([.[]|select(.count>=2)|.longest]|max) end' < "${f}" 2>/dev/null
}
tpq_persistence="$(queue_persistence)"
tpq_peak="$(mstat thread_pool_queue max)"; tpq_avg="$(mstat thread_pool_queue avg)"
thread_peak="$(mstat thread_count max)"
gc_pause_peak="$(mstat gc_pause max)"
alloc_rate_peak="$(mstat gc_allocation_rate max)"
lock_rate_peak="$(mstat lock_contention max)"
db_used_peak=""; db_max=""; db_pending_peak=""; db_timeouts=""; db_created=""; db_exec_peak=""; db_idle_peak=""; db_created_window=""; db_total_peak=""
# `read` returns non-zero at EOF, so an absent or empty database_pool_metrics.json
# (no database in this lab, or a failed Prometheus query) would abort the whole
# classifier under `set -e` -- exit 1, no message, no verdict at all. A signal
# that was not captured must degrade that ONE dimension to "not captured", not
# destroy the diagnosis of every other resource.
if read_fields 9 2>/dev/null < <(dbpool_worst); then
  db_used_peak="${TSV_FIELDS[0]}"; db_max="${TSV_FIELDS[1]}"; db_pending_peak="${TSV_FIELDS[2]}"
  db_timeouts="${TSV_FIELDS[3]}"; db_created="${TSV_FIELDS[4]}"
  [[ "${TSV_FIELDS[5]}" == "-1" ]] || db_exec_peak="${TSV_FIELDS[5]}"
  db_idle_peak="${TSV_FIELDS[6]}"; db_created_window="${TSV_FIELDS[7]}"; db_total_peak="${TSV_FIELDS[8]}"
fi
up_wait=""; up_active=""; up_conns=""; up_pool=""
if read_fields 4 2>/dev/null < <(upstream_worst | tr '\t' '\n'); then
  up_wait="${TSV_FIELDS[0]}"; up_active="${TSV_FIELDS[1]}"
  up_conns="${TSV_FIELDS[2]}"; up_pool="${TSV_FIELDS[3]}"
fi

# Managed-heap RETENTION. A leak is not a latency bottleneck, so it must never
# compete for the primary verdict -- but a package whose heap grew by orders of
# magnitude while nothing saturated would otherwise read as "no problem found".
# The in-process before/after gcdump pair (normalize-runtime auto-diffs it) is
# the only honest retention source: a within-window metric slope cannot see a
# leak that already saturated during warm-up. Absent gcdump -> not captured.
retain_growth=""
retain_diff="${run_arg}/analysis/runtime/diff-gcdump-before-after.txt"
if [[ -s "${retain_diff}" ]]; then
  retain_growth="$(awk -F'[()%+]' '/total delta:/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/ && $0 ~ /%/) v=$i } END { if (v!="") printf "%.4f", v/100 }' "${retain_diff}" 2>/dev/null || true)"
fi

# Server responses by class over the window (cumulative counts per route and
# status): client errors (4xx but 429), shedding (429/503) and server errors
# (5xx but 503). An HTTP 401 on every request is a broken workload, not an
# overloaded system, and a 429 is the target refusing load by design.
status_mix() { # -> "total client shed server topClientCode topClientCount"
  local f="${mdir}/request_duration.json"; [[ -s "${f}" ]] || return 0
  jqd -r '
    # A status series that first appears after the others began inside the
    # window: its first sample counts from zero (5,000 401s in one scrape were 0).
    ([ .data.result[]? | (.values // [])[0][0] // empty ] | min) as $start
    | [ .data.result[]? | select((.metric.__name__ // "") | endswith("_count"))
      | (.values // []) as $v
      | { code: (.metric.http_response_status_code // ""),
          n: ($v | map(.[1]|tonumber) | if length == 0 then 0
               elif ($v[0][0] > $start) then last
               elif length < 2 then 0 else ((last - first) | if . < 0 then 0 else . end) end) } ]
    | group_by(.code) | map({code: .[0].code, n: (map(.n) | add)})
    | (map(.n) | add // 0) as $total
    | (map(select(.code | test("^4") and . != "429"))) as $client
    | ($client | max_by(.n) // {code:"", n:0}) as $top
    | "\($total)\t\($client | map(.n) | add // 0)\t\(map(select(.code == "429" or .code == "503")) | map(.n) | add // 0)\t\(map(select(.code | test("^5") and . != "503")) | map(.n) | add // 0)\t\($top.code)\t\($top.n)"' < "${f}" 2>/dev/null | head -1
}
st_total=""; st_client=""; st_shed=""; st_server=""; st_top_code=""; st_top_n=""
if read_fields 6 2>/dev/null < <(status_mix | tr '\t' '\n'); then
  st_total="${TSV_FIELDS[0]}"; st_client="${TSV_FIELDS[1]}"; st_shed="${TSV_FIELDS[2]}"
  st_server="${TSV_FIELDS[3]}"; st_top_code="${TSV_FIELDS[4]}"; st_top_n="${TSV_FIELDS[5]}"
fi

# A dependency fault inside the measured window puts the outage into every peak.
fault_note=""
if [[ -s "${run_arg}/benchmark/fault-proof.json" ]]; then
  fault_note="$(jqd -r 'select(.applied == true) | "a dependency fault (\(.action) \(.service)) was injected inside the measured window, so the resource peaks include the outage; analysis/fault.json has the outage and the recovery."' < "${run_arg}/benchmark/fault-proof.json" 2>/dev/null || true)"
fi

# Generator-host port exhaustion: when the host held TIME_WAIT sockets toward the
# target near its ephemeral range, connections failed on the load generator, so
# errors, throughput and latency describe the generator, not the target.
gen_tw_peak=""; gen_range=""; gen_host=""
if [[ -s "${run_arg}/analysis/generator-ports.json" ]]; then
  gen_range="$(jqd -r '.ephemeralRange // empty' < "${run_arg}/analysis/generator-ports.json" 2>/dev/null || true)"
  gen_host="$(jqd -r '.host // ""' < "${run_arg}/analysis/generator-ports.json" 2>/dev/null || true)"
  gen_tw_peak="$(cat "${run_arg}"/dependencies/*-sockets-series.ndjson 2>/dev/null | jqd -rs '[.[] | .generatorTimeWait? // empty] | max // empty' 2>/dev/null || true)"
fi

# --- database server, cache and exception evidence ----------------------------
dep="${run_arg}/dependencies"
# Measured-window transactions and deadlocks (postgres adapter snapshot delta).
pg_deadlocks=""; pg_rollbacks=""; pg_commits=""; pg_max_conn=""
if read_fields 3 2>/dev/null < <(jqd -r 'select(.scope == "measured-window") | "\(.deadlocks)\n\(.xactRollback)\n\(.xactCommit)"' \
    < "${dep}/postgres-deadlocks-delta.json" 2>/dev/null); then
  pg_deadlocks="${TSV_FIELDS[0]}"; pg_rollbacks="${TSV_FIELDS[1]}"; pg_commits="${TSV_FIELDS[2]}"
fi
[[ -s "${dep}/postgres-deadlocks.csv" ]] && pg_max_conn="$(awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "max_connections") c = i }
  NR == 2 && c { print $c + 0 }' "${dep}/postgres-deadlocks.csv")"
# Mid-load sessions of the application (the harness's own psql excluded): all
# backends, active, idle in transaction, active waiting on a row lock
# (transactionid/tuple, not advisory or relation locks), blocked.
pg_backends=""; pg_active=""; pg_idle_tx=""; pg_lock_wait=""; pg_blocked=""
if read_fields 5 2>/dev/null < <(awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $col["application_name"] == "psql" { next }
    { n = $col["connections"] + 0; backends += n
      if ($col["state"] == "active") active += n
      if ($col["state"] ~ /^idle in transaction/) idletx += n
      if (("wait_event_type" in col) && $col["state"] == "active" && $col["wait_event_type"] == "Lock" && $col["wait_event"] ~ /^(transactionid|tuple)$/) lockwait += n
      if ("blocked" in col) blocked += $col["blocked"] }
    END { if (NR > 1) printf "%d\n%d\n%d\n%s\n%s\n", backends, active, idletx,
      (("wait_event_type" in col) ? lockwait : ""), (("blocked" in col) ? blocked : "") }' "${dep}/postgres-connections-midload.csv" 2>/dev/null); then
  pg_backends="${TSV_FIELDS[0]}"; pg_active="${TSV_FIELDS[1]}"; pg_idle_tx="${TSV_FIELDS[2]}"
  pg_lock_wait="${TSV_FIELDS[3]}"; pg_blocked="${TSV_FIELDS[4]}"
fi
# The session most others wait behind: state, open-transaction age, waiters.
# awk: split a CSV row's first <n> comma-free fields into f[1..n] and return the
# free-text last column, unquoted (psql COPY quotes it when it holds commas).
awk_csv_tail='function csv_tail(line, n, f,   i, p) { for (i = 1; i <= n; i++) { p = index(line, ","); f[i] = substr(line, 1, p - 1); line = substr(line, p + 1) }
  gsub(/^"|"$/, "", line); gsub(/""/, "\"", line); return line }'
first_row_tail() { # <n> <csv> -> the first data row's <n> fields and its tail (120 chars), one per line
  awk -v n="$1" "${awk_csv_tail}"' NR == 2 { tail = csv_tail($0, n, f); for (i = 1; i <= n; i++) print f[i]; print substr(tail, 1, 120) }' "$2"
}
holder_state=""; holder_age_ms=""; holder_waiters=""; BN_HOLDER_QUERY=""
if [[ -s "${dep}/postgres-lock-holders-midload.csv" ]] && read_fields 6 2>/dev/null < <(first_row_tail 5 "${dep}/postgres-lock-holders-midload.csv"); then
  holder_state="${TSV_FIELDS[2]}"; holder_age_ms="${TSV_FIELDS[3]}"; holder_waiters="${TSV_FIELDS[4]}"; BN_HOLDER_QUERY="${TSV_FIELDS[5]}"
fi
# Application statements from pg_stat_statements (harness catalog queries
# excluded), by total execution time. <misses> also finds the statement whose
# call count matches the cache misses (a refresh per miss). The most-called
# statement shows query amplification (S07: one order_items query per order,
# 50 per request), DISCARD ALL counts pool resets (one per leased connection),
# and the execution total of every application statement is the database
# server's share of the time requests spend in database calls.
statements() { # <cache-misses> -> "total calls mean query matchCalls matchQuery mostCalls mostCalledQuery discards serverMs rows"
  [[ -s "${dep}/postgres-statements.csv" ]] || return 0
  awk -v misses="$1" "${awk_csv_tail}"' NR > 1 { line = csv_tail($0, 8, f)
      if (line ~ /pg_stat|pg_catalog|^COPY |^SELECT 1$/) next
      server += f[4]
      if (line ~ /^DISCARD ALL/) discards += f[2]
      if (line ~ /^(BEGIN|COMMIT|ROLLBACK|SET |DISCARD)/) next
      if (f[4] + 0 > best) { best = f[4] + 0; calls = f[2]; mean = f[5]; rows = f[3]; q = substr(line, 1, 120) }
      if (f[2] + 0 > most) { most = f[2] + 0; mostq = substr(line, 1, 120) }
      d = f[2] - misses; if (d < 0) d = -d
      if (misses >= 100 && d <= misses * 0.1 && (mq == "" || d < md)) { md = d; mc = f[2]; mq = substr(line, 1, 120) } }
    END { if (best > 0) printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%d\n%s\n%s\n", best, calls, mean, q, (mq == "" ? "" : mc), mq, most, mostq, discards, server, rows }' "${dep}/postgres-statements.csv"
}
# Redis counters are reset at measurement start, so INFO after the load is the
# window's hits, misses, evictions and accepted connections.
cache_hits=""; cache_misses=""; cache_evicted=""; cache_expired=""; cache_conns=""; cache_keys=""; cache_expiring=""; cache_clients_mid=""
if [[ -s "${dep}/redis-info.txt" ]] && read_fields 7 2>/dev/null < <(tr -d '\r' < "${dep}/redis-info.txt" | awk -F: '
    $1 == "keyspace_hits" { h = $2 } $1 == "keyspace_misses" { m = $2 } $1 == "evicted_keys" { e = $2 } $1 == "expired_keys" { x2 = $2 }
    $1 == "total_connections_received" { c = $2 }
    $1 ~ /^db[0-9]+$/ { n = split($2, kv, ","); for (i = 1; i <= n; i++) { split(kv[i], pair, "="); if (pair[1] == "keys") k += pair[2]; if (pair[1] == "expires") x += pair[2] } }
    END { printf "%d\n%d\n%d\n%d\n%d\n%d\n%d\n", h, m, e, c, k, x, x2 }'); then
  cache_hits="${TSV_FIELDS[0]}"; cache_misses="${TSV_FIELDS[1]}"; cache_evicted="${TSV_FIELDS[2]}"
  cache_conns="${TSV_FIELDS[3]}"; cache_keys="${TSV_FIELDS[4]}"; cache_expiring="${TSV_FIELDS[5]}"; cache_expired="${TSV_FIELDS[6]}"
fi
[[ -s "${dep}/redis-clients-midload.txt" ]] && cache_clients_mid="$(tr -d '\r' < "${dep}/redis-clients-midload.txt" | awk -F: '$1 == "connected_clients" { print $2 + 0 }')"
stmt_total=""; stmt_calls=""; stmt_mean=""; BN_STMT_QUERY=""; refresh_calls=""; BN_REFRESH_QUERY=""
stmt_most=""; BN_MOST_QUERY=""; stmt_discards=""; stmt_server_ms=""; stmt_rows=""
if read_fields 11 2>/dev/null < <(statements "${cache_misses:-0}"); then
  stmt_total="${TSV_FIELDS[0]}"; stmt_calls="${TSV_FIELDS[1]}"; stmt_mean="${TSV_FIELDS[2]}"; BN_STMT_QUERY="${TSV_FIELDS[3]}"
  refresh_calls="${TSV_FIELDS[4]}"; BN_REFRESH_QUERY="${TSV_FIELDS[5]}"
  stmt_most="${TSV_FIELDS[6]}"; BN_MOST_QUERY="${TSV_FIELDS[7]}"; stmt_discards="${TSV_FIELDS[8]}"; stmt_server_ms="${TSV_FIELDS[9]}"; stmt_rows="${TSV_FIELDS[10]}"
fi
# The scenario's representative plan (EXPLAIN ANALYZE): the rows its scans read
# against the rows it returns. A deep OFFSET or a filter without an index reads
# rows only to discard them (E03: 12,500 read for 25 returned).
plan_scanned=""; plan_returned=""; BN_PLAN_NODE=""
if [[ -s "${dep}/postgres-query-plan.json" ]] && read_fields 3 2>/dev/null < <(jqd -r '
    (.plan[0].Plan // empty) as $root
    | ($root["Actual Rows"] * ($root["Actual Loops"] // 1)) as $returned
    | [$root | .. | objects | select((.["Node Type"] // "") | test("Scan$"))
        | {rows: (((.["Actual Rows"] // 0) + (.["Rows Removed by Filter"] // 0)) * (.["Actual Loops"] // 1)),
           node: (.["Node Type"] + (if .["Relation Name"] then " on " + .["Relation Name"] else "" end))}]
    | max_by(.rows) // empty
    | "\(.rows)\n\($returned)\n\(.node)"' < "${dep}/postgres-query-plan.json" 2>/dev/null); then
  plan_scanned="${TSV_FIELDS[0]}"; plan_returned="${TSV_FIELDS[1]}"; BN_PLAN_NODE="${TSV_FIELDS[2]}"
fi
requests_total="$(obs http.requests.total)"
# Exceptions thrown per second, summed across types, and the type thrown most.
exc_peak="$(mstat_sum exceptions max)"; exc_mean="$(mstat_sum exceptions avg)"
BN_EXC_TYPE=""
[[ -s "${mdir}/exceptions.json" ]] && BN_EXC_TYPE="$(jqd -r '[.data.result[]? | {t: (.metric.error_type // "unknown"),
  p: ([(.values // [])[] | .[1] | tonumber] | max // 0)}] | max_by(.p) | .t // empty' < "${mdir}/exceptions.json" 2>/dev/null || true)"
api_tw_peak="$(cat "${dep}"/*-sockets-series.ndjson 2>/dev/null | jqd -rs '[.[] | .timeWait? // empty] | max // empty' 2>/dev/null || true)"
# Application processes (API, worker, replicas): one multiplexed Redis client
# opens one connection per process, so clients per process above a few mean
# several multiplexers (S24: 34 clients for 2 processes).
processes=""
[[ -s "${mdir}/process_cpu.json" ]] && processes="$(jqd -r '[.data.result[]?.metric.service_instance_id // empty] | unique | length' < "${mdir}/process_cpu.json" 2>/dev/null || true)"
# RabbitMQ connections and channels opened in the window (broker counters
# baselined after warm-up). A broker restarted inside the window (the async
# reconciliation reads node uptime) restarted its counters, so no difference
# describes the window.
rabbit_opened() { # <metric> -> opened in the window
  local before after
  [[ -s "${run_arg}/analysis/async-reconciliation.json" ]] \
    && jqd -e '.scope == "broker-restarted"' < "${run_arg}/analysis/async-reconciliation.json" >/dev/null 2>&1 && return 0
  before="$(awk -v m="$1" '$1 == m { print $2 + 0; exit }' "${dep}/rabbitmq-broker-metrics-preload.txt" 2>/dev/null)"
  after="$(awk -v m="$1" '$1 == m { print $2 + 0; exit }' "${dep}/rabbitmq-broker-metrics.txt" 2>/dev/null)"
  [[ -n "${before}" && -n "${after}" ]] && (( ${after%.*} >= ${before%.*} )) && printf '%s' "$(( ${after%.*} - ${before%.*} ))"
  return 0
}
rabbit_conns="$(rabbit_opened rabbitmq_connections_opened_total)"
rabbit_channels="$(rabbit_opened rabbitmq_channels_opened_total)"
# The lab's own resource pools (<prefix>_pool_wait_duration_milliseconds, with
# pool_name and pool_configured_size): the pool whose waits add up to the most
# time, its mean wait in the window, and its peak leases (S23: one exclusive
# multiplexer, 4,726 ms mean wait of a 5,000 ms median).
app_pool() { # -> "name size meanWaitMs waits activePeak"
  [[ -s "${mdir}/application_metrics.json" ]] || return 0
  jqd -r '
    def increase: (.values // []) | sort_by(.[0]) | map(.[1]|tonumber) as $a
      | if ($a|length) < 2 then 0 else reduce range(1; $a|length) as $i (0; . + (if $a[$i] >= $a[$i-1] then $a[$i]-$a[$i-1] else $a[$i] end)) end;
    [.data.result[]? | (.metric.__name__ // "") as $n | select($n | test("_pool_(wait_duration_milliseconds_(sum|count)|active_leases)$"))
      | {pool: (.metric.pool_name // "default"), size: (.metric.pool_configured_size // ""), inst: (.metric.service_instance_id // ""),
         kind: ($n | capture("_pool_(?<k>wait_duration_milliseconds_sum|wait_duration_milliseconds_count|active_leases)$").k),
         grew: increase, peak: ([(.values // [])[] | .[1] | tonumber] | max // 0)}]
    | group_by([.pool, .inst])
    | map({pool: .[0].pool, size: .[0].size,
        sum: ([.[] | select(.kind == "wait_duration_milliseconds_sum") | .grew] | add // 0),
        count: ([.[] | select(.kind == "wait_duration_milliseconds_count") | .grew] | add // 0),
        active: ([.[] | select(.kind == "active_leases") | .peak] | max // 0)})
    | map(select(.count > 0)) | max_by(.sum) // empty
    | "\(.pool)\n\(.size)\n\(.sum / .count)\n\(.count)\n\(.active)"' < "${mdir}/application_metrics.json" 2>/dev/null
}
BN_APP_POOL=""; app_pool_size=""; app_pool_wait=""; app_pool_waits=""; app_pool_active=""
if read_fields 5 2>/dev/null < <(app_pool); then
  BN_APP_POOL="${TSV_FIELDS[0]}"; app_pool_size="${TSV_FIELDS[1]}"; app_pool_wait="${TSV_FIELDS[2]}"
  app_pool_waits="${TSV_FIELDS[3]}"; app_pool_active="${TSV_FIELDS[4]}"
fi
# Dependency time from span metrics: the client/producer span time of each
# dependency over the server span time in the window (a ratio of sums, which
# head sampling leaves unbiased), its span time and calls per second, and the
# server spans per second. PostgreSQL is left to the Npgsql dimensions above;
# the telemetry exporter is never a dependency.
dependency_top() { # -> "system share timePerSecond callsPerSecond serverCallsPerSecond" of the non-database dependency with the most time
  [[ -s "${mdir}/dependency_time.json" ]] || return 0
  {
    cat "${mdir}/dependency_time.json"
    if [[ -s "${mdir}/dependency_calls.json" ]]; then cat "${mdir}/dependency_calls.json"; else printf '{}\n'; fi
    if [[ -s "${run_arg}/environment/measurement-start/resource-limits.json" ]]; then
      cat "${run_arg}/environment/measurement-start/resource-limits.json"
    else printf '[]\n'; fi
  } | jqd -rs '
    def samples: [(.values // (if .value then [.value] else [] end))[] | .[1] | tonumber];
    def avg: if length == 0 then 0 else add / length end;
    def system: (.metric.db_system_name // .metric.db_system // "") as $db | (.metric.messaging_system // "") as $mq |
      if $db != "" then $db elif $mq != "" then $mq elif (.metric.server_address // "") != "" then "http:" + .metric.server_address else "" end;
    [.[2][]? | .telemetryExporterAuthority | select(. != null and . != "") | sub(":[0-9]+$"; "")] as $exporters |
    def dependencies: [.data.result[]? | select(.metric.span_kind != "SPAN_KIND_SERVER")
      | select((.metric.server_address // "") as $host | ($exporters | index($host)) == null)
      | {sys: system, v: samples} | select(.sys != "" and .sys != "postgresql")];
    ([.[0].data.result[]? | select(.metric.span_kind == "SPAN_KIND_SERVER") | samples | avg] | add // 0) as $server |
    ([.[1].data.result[]? | select(.metric.span_kind == "SPAN_KIND_SERVER") | samples | avg] | add // 0) as $servercalls |
    (.[0] | dependencies | group_by(.sys) | map({sys: .[0].sys, t: ([.[].v | avg] | add)})) as $time |
    (.[1] | dependencies | group_by(.sys) | map({key: .[0].sys, value: ([.[].v | avg] | add)}) | from_entries) as $calls |
    if $server <= 0 or ($time | length) == 0 then empty
    else ($time | max_by(.t)) as $top | "\($top.sys)\n\($top.t / $server)\n\($top.t)\n\($calls[$top.sys] // 0)\n\($servercalls)" end' 2>/dev/null
}
dep_system=""; dep_share=""; dep_time=""; dep_calls=""; dep_server_calls=""
if read_fields 5 2>/dev/null < <(dependency_top); then
  dep_system="${TSV_FIELDS[0]}"; dep_share="${TSV_FIELDS[1]}"; dep_time="${TSV_FIELDS[2]}"
  dep_calls="${TSV_FIELDS[3]}"; dep_server_calls="${TSV_FIELDS[4]}"
fi
# Traces are head-sampled per request. For a local lab the harness sets the
# ratio the app samples with, so sampled span totals divided by it are the
# requests' own: calls per request and span time per request against the entry
# requests the load generator counted. A server-span denominator counts a
# request that calls its own service twice (S26 upstream: 609 server spans per
# second for 1,206 requests), and a remote app's ratio is not known, where the
# sampled server spans are the fallback.
sample_ratio=""
[[ -s "${run_arg}/manifest.json" ]] && sample_ratio="$(jqd -r 'select(.target == "local" and ((.traceSampler // "") | test("traceidratio$"))) | .traceSamplerArg // empty' < "${run_arg}/manifest.json" 2>/dev/null || true)"
[[ "${sample_ratio}" =~ ^(0?\.[0-9]+|1(\.0+)?)$ ]] || sample_ratio=""
# A window shorter than the rate lookback: the rate-derived resources describe
# partly the time before the measurement, so they are not established for it.
rate_note=""
if [[ -s "${run_arg}/telemetry/rate-window.json" ]] && jqd -e '.established == false' < "${run_arg}/telemetry/rate-window.json" >/dev/null 2>&1; then
  rate_note="$(jqd -r '"the measured window (\(.measuredSeconds) s) is shorter than the \(.rateWindowSeconds) s rate window, so rate-derived resources (CPU, GC, allocation, locks, exceptions, dependency time) are not established for it and were not classified; measure for at least \(.rateWindowSeconds) s."' \
    < "${run_arg}/telemetry/rate-window.json")"
  cpu_busy_peak=""; cpu_count=""; gc_pause_peak=""; alloc_rate_peak=""; lock_rate_peak=""; exc_peak=""; exc_mean=""
  dep_system=""; dep_share=""; dep_time=""; dep_calls=""; dep_server_calls=""
  rm -f "${run_arg}/analysis/cpu-utilization.json"
fi
export BN_HOLDER_QUERY BN_STMT_QUERY BN_REFRESH_QUERY BN_EXC_TYPE BN_MOST_QUERY BN_PLAN_NODE BN_APP_POOL

# --- decision + JSON (awk; -1 == not captured) ------------------------------
d() { [[ -n "$1" ]] && printf '%s' "$1" || printf -- '-1'; }
json="$(awk \
  -v scen="${scenario}" -v runid="${run_id}" -v status="${status}" \
  -v rps="$(d "${rps}")" -v p50="$(d "${p50}")" -v p99="$(d "${p99}")" \
  -v errate="$(d "${errate}")" -v dropped="$(d "${dropped}")" \
  -v effcpu="$(d "${eff_cpu}")" -v effgc="$(d "${eff_gc}")" -v effdb="$(d "${eff_db}")" -v effalloc="$(d "${eff_alloc}")" \
  -v cpubusy="$(d "${cpu_busy_peak}")" -v cpucount="$(d "${cpu_count}")" \
  -v tpqpersistence="$(d "${tpq_persistence}")" -v tpqpeak="$(d "${tpq_peak}")" -v tpqavg="$(d "${tpq_avg}")" -v threadpeak="$(d "${thread_peak}")" \
  -v gcpause="$(d "${gc_pause_peak}")" -v allocrate="$(d "${alloc_rate_peak}")" -v lockrate="$(d "${lock_rate_peak}")" \
  -v dbpending="$(d "${db_pending_peak}")" -v dbused="$(d "${db_used_peak}")" -v dbmax="$(d "${db_max}")" \
  -v upwait="$(d "${up_wait}")" -v upactive="$(d "${up_active}")" -v upconns="$(d "${up_conns}")" -v uppool="${up_pool:-}" \
  -v UP_WAIT_SAT="${PERFLAB_USE_UPSTREAM_WAIT_SAT:-0.05}" \
  -v CPU_SAT="${PERFLAB_USE_CPU_SAT:-0.85}" -v TPQ_SAT="${PERFLAB_USE_TPQ_SAT:-2}" \
  -v TPQ_WAIT_SAT="${PERFLAB_USE_TPQ_WAIT_SAT:-0.05}" -v RETAIN_SAT="${PERFLAB_USE_RETAIN_SAT:-0.25}" \
  -v retaingrowth="$(d "${retain_growth}")" \
  -v sttotal="$(d "${st_total}")" -v stclient="$(d "${st_client}")" -v stshed="$(d "${st_shed}")" -v stserver="$(d "${st_server}")" \
  -v sttopcode="${st_top_code}" -v sttopn="$(d "${st_top_n}")" -v CLIENT_ERR_SAT="${PERFLAB_CLIENT_ERROR_SAT:-0.5}" \
  -v faultnote="${fault_note}" \
  -v dbtmo="$(d "${db_timeouts}")" -v dbmade="$(d "${db_created}")" -v dbexec="$(d "${db_exec_peak}")" \
  -v dbidle="$(d "${db_idle_peak}")" -v dbmadewin="$(d "${db_created_window}")" -v dbtotal="$(d "${db_total_peak}")" \
  -v stmtrows="$(d "${stmt_rows}")" -v stmtmost="$(d "${stmt_most}")" -v stmtdiscards="$(d "${stmt_discards}")" -v stmtserver="$(d "${stmt_server_ms}")" \
  -v planscanned="$(d "${plan_scanned}")" -v planreturned="$(d "${plan_returned}")" \
  -v excmean="$(d "${exc_mean}")" -v procs="$(d "${processes}")" -v rbconns="$(d "${rabbit_conns}")" -v rbchan="$(d "${rabbit_channels}")" \
  -v apsize="${app_pool_size}" -v apwait="$(d "${app_pool_wait}")" -v apwaits="$(d "${app_pool_waits}")" -v apactive="$(d "${app_pool_active}")" \
  -v deptime="$(d "${dep_time}")" -v depsrvcalls="$(d "${dep_server_calls}")" -v sampleratio="$(d "${sample_ratio}")" \
  -v THREAD_BLOCK_MIN="${PERFLAB_THREAD_BLOCK_MIN:-32}" -v THREAD_BLOCK_PER_CORE="${PERFLAB_THREAD_BLOCK_PER_CORE:-16}" \
  -v AMPLIFY="${PERFLAB_AMPLIFICATION_PER_REQUEST:-10}" -v DB_SERVER_SHARE="${PERFLAB_DB_SERVER_SHARE:-0.25}" \
  -v pgdl="$(d "${pg_deadlocks}")" -v pgrb="$(d "${pg_rollbacks}")" -v pgcm="$(d "${pg_commits}")" -v pgmax="$(d "${pg_max_conn}")" \
  -v pgback="$(d "${pg_backends}")" -v pgact="$(d "${pg_active}")" -v pgidletx="$(d "${pg_idle_tx}")" \
  -v pglock="$(d "${pg_lock_wait}")" -v pgblocked="$(d "${pg_blocked}")" \
  -v hstate="${holder_state}" -v hage="$(d "${holder_age_ms}")" -v hwait="$(d "${holder_waiters}")" \
  -v stmttot="$(d "${stmt_total}")" -v stmtcalls="$(d "${stmt_calls}")" -v stmtmean="$(d "${stmt_mean}")" -v refcalls="$(d "${refresh_calls}")" \
  -v chits="$(d "${cache_hits}")" -v cmiss="$(d "${cache_misses}")" -v cevict="$(d "${cache_evicted}")" -v cconns="$(d "${cache_conns}")" \
  -v ckeys="$(d "${cache_keys}")" -v cexp="$(d "${cache_expiring}")" -v cexpired="$(d "${cache_expired}")" -v cclients="$(d "${cache_clients_mid}")" -v apitw="$(d "${api_tw_peak}")" \
  -v reqtotal="$(d "${requests_total}")" -v excpeak="$(d "${exc_peak}")" \
  -v depsys="${dep_system}" -v depshare="$(d "${dep_share}")" -v depcalls="$(d "${dep_calls}")" \
  -v ratenote="${rate_note}" \
  -v DEADLOCK_SAT="${PERFLAB_DEADLOCK_SAT:-0.01}" -v ROWLOCK_MIN="${PERFLAB_ROWLOCK_MIN_WAITERS:-4}" -v STAMPEDE_MISSES="${PERFLAB_STAMPEDE_MISSES_PER_EXPIRY:-10}" \
  -v WAIT_CPU_SHARE="${PERFLAB_WAIT_CPU_SHARE:-0.10}" -v WAIT_MIN_P50="${PERFLAB_WAIT_MIN_P50_MS:-50}" \
  -v ALLOC_NOTE="${PERFLAB_ALLOC_BYTES_PER_REQUEST_NOTE:-1048576}" -v ALLOC_RATE_NOTE="${PERFLAB_ALLOC_RATE_NOTE:-104857600}" -v EXC_NOTE="${PERFLAB_EXCEPTIONS_PER_REQUEST_NOTE:-1}" \
  -v gentw="$(d "${gen_tw_peak}")" -v genrange="$(d "${gen_range}")" -v genhost="${gen_host}" -v GEN_PORT_SAT="${PERFLAB_GENERATOR_PORT_SAT:-0.5}" \
  -v GC_SAT="${PERFLAB_USE_GC_SAT:-0.10}" -v LOCK_SAT="${PERFLAB_USE_LOCK_SAT:-1.0}" -v DEP_SHARE="${PERFLAB_USE_DEP_SHARE:-0.50}" \
  'function has(x){ return (x+0) >= 0 && x != "" }
   function share(ms){ return (has(ms) && has(p50) && p50+0>0) ? (ms+0)/(p50+0) : -1 }
   function jnum(x){ return (has(x) ? sprintf("%.4f", x+0) : "null") }
   function jpct(x){ return (x>=0 ? sprintf("%.1f", x*100) : "null") }
   function lesser(a, b){ return (a+0 < b+0 ? a+0 : b+0) }
   # The statement with the most database time, with rows per call when a call
   # returns many (S11: 12,000 rows per call from the whole tracked graph).
   function stmt_text(){ return sprintf("\"%s\" (%d calls, mean %.2f ms%s)", ENVIRON["BN_STMT_QUERY"], stmtcalls+0, stmtmean+0, ((has(stmtrows) && stmtcalls+0>0 && (stmtrows+0)/(stmtcalls+0)>=100) ? sprintf(", %.0f rows per call", (stmtrows+0)/(stmtcalls+0)) : "")) }
   # What the dependency spans cover: a share of the server span time, with the
   # time and calls per entry request when the sampling ratio is known.
   function span_cover(   s){
     s=sprintf("%s spans cover ~%.0f%% of server time", span_target, dshare*100);
     if (dep_ms_req>=0) s=s sprintf(" (%.1f ms per request", dep_ms_req) (span_per_req>=0 ? sprintf(", %.1f calls per request)", span_per_req) : ")");
     else if (span_per_req>=0) s=s sprintf(" (%.1f calls per request)", span_per_req);
     if (nested_per_req>=0.2) s=s sprintf("; the service also served %.1f nested request(s) per request, which that server time includes, so the share of the entry request is higher", nested_per_req);
     return s }
   BEGIN{
     # ----- per-resource utilisation / saturation -----
     cpu_util = (has(cpubusy) && has(cpucount) && cpucount+0>0) ? (cpubusy+0)/(cpucount+0) : -1;
     cpu_share = share(effcpu); gc_share = share(effgc); db_share = share(effdb);
     lock_per_req = (has(lockrate) && has(rps) && rps+0>0) ? (lockrate+0)/(rps+0) : -1;
     dbpool_util = (has(dbused) && has(dbmax) && dbmax+0>0) ? (dbused+0)/(dbmax+0) : -1;
     # "other" latency = time not attributable to CPU/GC/DB (framework, lock waits,
     # network, queueing). Only meaningful when the three shares are known.
     other_share = -1;
     if (cpu_share>=0 && gc_share>=0 && db_share>=0){ other_share = 1 - (cpu_share+gc_share+db_share); if(other_share<0) other_share=0 }

     # ----- saturation booleans (hard evidence) -----
     cpu_sat  = (cpu_util>=0 && cpu_util>=CPU_SAT);
     # A thread-pool queue is a bottleneck only when the backlog represents real
     # WAITING TIME, not merely a non-zero depth. Depth alone is throughput-blind:
     # 10 queued items at 19.6k rps drains in ~0.5 ms (noise), while 125 queued at
     # 294 rps is ~425 ms of backlog (the actual defect). Gate on depth/throughput
     # seconds so a fast server is never called "starved" for a transient queue.
     tpq_wait = (has(tpqpeak) && has(rps) && rps+0>0) ? (tpqpeak+0)/(rps+0) : -1;
     tpq_sat  = (has(tpqpeak) && tpqpeak+0>=TPQ_SAT && (tpq_wait<0 || tpq_wait>=TPQ_WAIT_SAT) && (!has(tpqpersistence) || tpqpersistence+0>=2));
     # Blocked pool threads (S02): the runtime injects threads while work items
     # block them, so a pool far larger than the cores is synchronous waiting on
     # pool threads (S03 async waits held 5 threads at the same wait share). The
     # queue itself may only spike once the pool has grown.
     tp_blocked = (has(threadpeak) && has(cpucount) && cpucount+0>0 && threadpeak+0>=THREAD_BLOCK_MIN && threadpeak+0>=THREAD_BLOCK_PER_CORE*(cpucount+0));
     gc_sat   = (has(gcpause) && gcpause+0>=GC_SAT);
     lock_sat = (lock_per_req>=0 && lock_per_req>=LOCK_SAT);
     dbp_sat  = (has(dbpending) && dbpending+0>0);
     dep_dom  = (db_share>=0 && db_share>=DEP_SHARE);
     # Retention is captured but deliberately NOT a candidate (see notes below).
     retain_sat = (has(retaingrowth) && retaingrowth+0>=RETAIN_SAT);
     # Upstream connection pool. Unlike the thread-pool queue this needs no
     # depth/throughput inference: the runtime reports the wait directly, so the
     # gate is the wait itself. Same 50 ms threshold, for the same reason -- a
     # few milliseconds of connection acquisition is normal pooling.
     up_sat = (has(upwait) && upwait+0>=UP_WAIT_SAT);
     up_share = (has(upwait) && has(p50) && p50+0>0) ? (upwait+0)/((p50+0)/1000) : -1;
     # Database server. Deadlocks in the window are a failure with their own
     # cause (S27 read as dependency-bound-db: the lock waits until the deadlock
     # timeout were the "DB time"). At least half the active sessions waiting on
     # a row lock explain a saturated pool (S10/E08 read only as db-pool-saturated).
     dl_txn = (has(pgrb) && has(pgcm)) ? (pgrb+0)+(pgcm+0) : 0;
     dl_share = (has(pgdl) && dl_txn>0) ? (pgdl+0)/dl_txn : -1;
     dl_sat = (dl_share>=DEADLOCK_SAT);
     rowlock = (has(pglock) && pglock+0>=ROWLOCK_MIN && (pglock+0)*2 >= (pgact+0));
     holder = (hstate != "" ? sprintf(" behind a session %s for %.0f ms with %d waiter(s)", hstate, hage+0, hwait+0) : "");
     # Waiting, not computing: the share of a typical request that no captured
     # resource accounts for (S03/S23: 3-4 ms of CPU in a ~5 s request).
     wait_share = (other_share>=0 ? other_share : (cpu_share>=0 ? 1-cpu_share : -1));
     if (wait_share>1) wait_share=1;
     # Per request from the window means; the peak rate stays beside it (S27: the
     # peak over the mean rate read 28 per request, the means 23).
     exc_per_req = (has(excmean) && has(rps) && rps+0>0) ? (excmean+0)/(rps+0) : -1;
     cache_ops = (has(chits) && has(cmiss)) ? (chits+0)+(cmiss+0) : -1;
     # A dependency other than the database that holds most of the server time
     # (S26: ~100 ms of a 104 ms request in one HTTP upstream call). With the
     # sampling ratio known, sampled span totals over it are per entry request
     # (S10 read 0.2 publishes per request against the unsampled rate); the
     # sampled server spans per entry request beyond one are nested requests the
     # service served itself (S26: 2 per request), which the server time includes.
     entry = (has(sampleratio) && sampleratio+0>0 && has(rps) && rps+0>0);
     dep_ms_req = (entry && has(deptime)) ? (deptime+0)/(sampleratio+0)/(rps+0)*1000 : -1;
     nested_per_req = (entry && has(depsrvcalls)) ? (depsrvcalls+0)/(sampleratio+0)/(rps+0) - 1 : -1;
     dshare = (has(depshare) ? depshare+0 : -1);
     span_dom = (depsys != "" && dshare >= DEP_SHARE);
     span_kind = depsys; span_target = depsys;
     if (depsys ~ /^http:/){ span_kind = "http"; span_target = "HTTP upstream " substr(depsys, 6) }
     span_per_req = (entry && has(depcalls)) ? (depcalls+0)/(sampleratio+0)/(rps+0) : ((has(depcalls) && has(depsrvcalls) && depsrvcalls+0>0) ? (depcalls+0)/(depsrvcalls+0) : -1);
     # The execution time on the database server against the time requests spend in
     # database calls: on a CPU-starved client a lease lasts through round trips
     # and the client processing (E13: 0.06 ms executed of 3.4 ms per request).
     srv_ms_req = (has(stmtserver) && has(reqtotal) && reqtotal+0>0) ? (stmtserver+0)/(reqtotal+0) : -1;
     srv_share = (srv_ms_req>=0 && has(effdb) && effdb+0>0) ? srv_ms_req/(effdb+0) : -1;
     db_outside = (srv_share>=0 && srv_share<DB_SERVER_SHARE);
     # The pool of the lab holds most of a waiting request (S23).
     app_wait = (ENVIRON["BN_APP_POOL"] != "" && has(apwait) && has(p50) && p50+0>0 && apwait+0 >= 0.5*(p50+0));

     # ----- rank candidates. Saturation signals outweigh mere utilisation/shares;
     # among shares, the largest slice of the request wins. Score in [0,~2]. -----
     n=0;
     if (dl_sat){ cand[++n]="db-deadlock"; sc[n]=2.5 }
     # Row-lock waiting is the cause of the pool saturation it produces, so it
     # replaces the pool candidate (just above its score) instead of competing with it.
     # One mid-load sample is corroborated by a saturated pool; alone it ranks as
     # a share-level candidate (medium confidence).
     if (rowlock){ cand[++n]="db-lock-contention"; sc[n]=(dbp_sat ? 1.55 + (has(dbpending)?dbpending+0:0)/100 : 0.9) }
     # A queue for connections that the database barely uses, beside a saturated
     # CPU, follows the CPU (E14): a concurrent bottleneck ranked after the CPU.
     else if (dbp_sat){ cand[++n]="db-pool-saturated"; sc[n]=((cpu_sat && db_outside) ? 0.95*(1.0+cpu_util) : 1.5 + (has(dbpending)?dbpending+0:0)/100) }
     # A thread-pool queue is only its OWN bottleneck (sync-over-async / blocking
     # starvation, threads parked not busy) when CPU is NOT saturated. When CPU is also
     # saturated the queue is a SYMPTOM of CPU starvation, so cpu-bound must win -- do not
     # add a competing threadpool-starved candidate whose queue score would overpower it.
     # A thread-pool queue behind a saturated upstream pool is a SYMPTOM: the
     # threads are waiting on connection acquisition, not starved by blocking
     # work of their own. Scored above threadpool-starved so the measured wait
     # wins over the queue that the wait produced.
     if (up_sat){ cand[++n]="upstream-pool-saturated"; sc[n]=1.45 + (upwait+0) }
     if ((tpq_sat || tp_blocked) && !cpu_sat){ cand[++n]="threadpool-starved"; sc[n]=1.3 + (tpq_sat ? (tpqpeak+0)/100 : 0.05) }
     if (lock_sat){ cand[++n]="lock-bound"; sc[n]=1.2 + lock_per_req/10 }
     if (cpu_sat){ cand[++n]="cpu-bound"; sc[n]=1.0 + cpu_util }
     if (gc_sat){ cand[++n]="gc-bound"; sc[n]=1.0 + (gcpause+0) }
     # dependency-bound-db means the request time is DB EXECUTION, not pool WAITING -- its
     # reason explicitly assumes the pool is NOT saturated. So it is mutually exclusive with
     # db-pool-saturated: only a candidate when the pool is not saturated.
     if (dep_dom && !dbp_sat && !dl_sat && !rowlock){ cand[++n]="dependency-bound-db"; sc[n]=0.5 + db_share }
     if (span_dom){ cand[++n]="dependency-bound-" span_kind; sc[n]=0.5 + depshare }
     # utilisation-only fallbacks (no hard saturation, but a resource clearly dominates)
     # Aggregate CPU cost divided by median request latency is not saturation.
     # Parallel work, exporter work and connection setup can make that ratio >1.
     if (n==0 && gc_share>=0.3){ cand[++n]="gc-bound"; sc[n]=0.4+gc_share }
     if (n==0 && cpu_util>=0.6){ cand[++n]="cpu-bound"; sc[n]=0.3+cpu_util }
     # Not when the rates are unestablished: "nothing saturated" is then unknown.
     if (n==0 && ratenote=="" && cpu_share>=0 && cpu_share<=WAIT_CPU_SHARE && has(p50) && p50+0>=WAIT_MIN_P50){ cand[++n]="wait-bound"; sc[n]=0.45 }

     # Rank by score (selection sort; n is tiny). The winner is the PRIMARY, but >=2 HARD
     # saturations within 10% of the top are CONCURRENT bottlenecks -- report them together
     # (composite verdict) and list every saturated resource, so an N+1 scenario saturating
     # CPU AND the DB pool AND locks at once is not reduced to a single "cpu-bound".
     for(i=1;i<=n;i++) ord[i]=i;
     for(i=1;i<=n;i++){ mxj=i; for(j=i+1;j<=n;j++){ if(sc[ord[j]]>sc[ord[mxj]]) mxj=j } t2=ord[i]; ord[i]=ord[mxj]; ord[mxj]=t2 }
     verdict="no-clear-bottleneck"; conf="low"; bi=(n>0?ord[1]:0); best=(n>0?sc[ord[1]]:0);
     # ONE set drives everything: PRIMARY = candidates within 10% of the top score. The
     # composite verdict, contributors, concurrent flag and the reason all use this SAME
     # set, so they never disagree. Resources saturated OUTSIDE the band are listed
     # separately (saturatedResources + "also saturated" in the reason) -- surfaced, but
     # not conflated with the primary verdict.
     ncontrib=0; composite=""; primlist=""; contribjson="";
     for(i=1;i<=n;i++){
       if(best>0 && sc[ord[i]] >= best*0.90){ ncontrib++;
         composite=composite (ncontrib>1?"+":"") cand[ord[i]];
         primlist=primlist (ncontrib>1?", ":"") cand[ord[i]];
         contribjson=contribjson (ncontrib>1?",":"") "\"" cand[ord[i]] "\"" } }
     concurrent=(ncontrib>=2 ? 1 : 0);
     if (bi>0) verdict=(ncontrib>=2 ? composite : cand[ord[1]]);
     # saturatedResources is derived DIRECTLY from the hard-saturation booleans, NOT the
     # ranked candidates: it MUST include a resource that is saturated even when it is not a
     # bottleneck candidate (the thread-pool queue when CPU is also saturated is a CPU
     # symptom, so not a candidate, but still saturated), and MUST EXCLUDE the utilisation
     # fallbacks and dependency dominance, which never cross a saturation threshold. Names
     # match the resources.<key> objects so the two always agree.
     nsatres=0; satresjson=""; satreslist="";
     if (cpu_sat){ nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"cpu\"";        satreslist=satreslist (nsatres>1?", ":"") "cpu" }
     if (tpq_sat || tp_blocked){ nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"threadPool\""; satreslist=satreslist (nsatres>1?", ":"") "threadPool" }
     if (gc_sat) { nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"gc\"";         satreslist=satreslist (nsatres>1?", ":"") "gc" }
     if (lock_sat){ nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"locks\"";     satreslist=satreslist (nsatres>1?", ":"") "locks" }
     if (dbp_sat){ nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"dbPool\"";     satreslist=satreslist (nsatres>1?", ":"") "dbPool" }
     if (up_sat) { nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"upstreamPool\""; satreslist=satreslist (nsatres>1?", ":"") "upstreamPool" }
     if (dl_sat || rowlock){ nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"dbServer\""; satreslist=satreslist (nsatres>1?", ":"") "dbServer" }

     # any resource signal captured at all?
     any = (cpu_util>=0) || has(tpqpeak) || has(gcpause) || (lock_per_req>=0) || has(dbpending) || (db_share>=0) || has(upwait) || has(pgdl) || has(pglock) || has(depshare);
     if (!any) verdict="insufficient-data";
     gen_ratio = (has(gentw) && has(genrange) && genrange+0>0) ? (gentw+0)/(genrange+0) : -1;
     gen_sat = (gen_ratio>=0 && gen_ratio>=GEN_PORT_SAT);
     if (gen_sat) verdict="generator-limited";
     client_share = (has(sttotal) && sttotal+0>0) ? (stclient+0)/(sttotal+0) : -1;
     shed_share   = (has(sttotal) && sttotal+0>0) ? (stshed+0)/(sttotal+0) : -1;
     client_sat = (client_share>=0 && client_share>=CLIENT_ERR_SAT);
     if (client_sat && !gen_sat) verdict="client-errors";

     # ----- confidence -----
     if (verdict=="insufficient-data") conf="low";
     else if (gen_sat || client_sat) conf="high";
     else if (dbp_sat || tpq_sat || tp_blocked || up_sat || (cpu_util>=0.9) || (gc_sat && gcpause+0>=0.2) || lock_sat || dl_sat || (rowlock && dbp_sat)) conf="high";
     else if (bi>0 && sc[bi]>=1.0) conf="high";
     else if (bi>0) conf="medium";
     else conf="low";
     if (status!="captured") conf="low";  # partial evidence never rates high
     # Dropped iterations mean the GENERATOR, not the server, set the pace: the
     # offered load was never delivered, so every server-side number describes a
     # workload that did not happen. A note saying so was not enough -- the
     # verdict beside it still read "high", and a reader acts on the verdict.
     # This matches the completeness cap in PerfLab, so the two products do not
     # disagree about how much to trust the same evidence.
     if (has(dropped) && dropped+0>0) conf="low";
     # Requests the generator counted failed that the application never recorded:
     # they failed on the path between them (P02: a connection per iteration
     # through a container port forwarder), so no application capacity is shown.
     # Only when the count of the application covers the requests the generator saw
     # succeed: a request metric that misses the traffic (P02 WebSocket upgrades
     # without baggage in a phase-selected query: 0 recorded, 9% succeeded)
     # says nothing about the failures.
     failed = (has(sttotal) ? (stclient+0)+(stshed+0)+(stserver+0) : -1);
     reached = (has(sttotal) && ratenote=="") ? sttotal+0 : -1;
     unreached = (reached>=0 && has(reqtotal)) ? (reqtotal+0) - reached : -1;
     succeeded = (has(reqtotal) && has(errate)) ? (reqtotal+0)*(1-(errate+0)) : -1;
     path_fail = (unreached>=0 && errate+0>=0.5 && unreached>=0.5*(reqtotal+0) && reached>=0.5*succeeded && failed < 0.1*(reqtotal+0)*(errate+0));
     if (path_fail) conf="low";
     if (verdict=="threadpool-starved" && !tp_blocked && !has(tpqpersistence)) conf="low";

     # ----- notes -----
     nn=0;
     if (has(errate) && errate+0>0.01) {
       if (client_sat) ;
       else if (path_fail) notes[++nn]=sprintf("error_rate=%.3f -- %.0f of %.0f requests never reached the application (it recorded %.0f): they failed between the load generator and the application (generator host ports, a container port forwarder or a gateway), so the error rate describes that path, not the capacity of the application.", errate+0, unreached, reqtotal+0, reached);
       else if (failed>0 && (stshed+0)*2 >= failed) notes[++nn]=sprintf("error_rate=%.3f -- %.0f%% of requests were answered 429/503: the target shed load explicitly (backpressure), so the accepted rate is ~%.0f rps; this is overload handled by design, not unexplained failure.", errate+0, shed_share*100, (has(rps)?(rps+0)*(1-(failed/(sttotal+0))):0));
       else if (faultnote != "") notes[++nn]=sprintf("error_rate=%.3f -- requests failed while a dependency fault was injected; analysis/fault.json has the outage and the recovery.", errate+0);
       else notes[++nn]=sprintf("error_rate=%.3f -- the system is failing requests (see the gate)%s.", errate+0, (bi>0 ? "; the verdict names the resource that fails them" : ""));
     }
     if (has(dropped) && dropped+0>0) notes[++nn]=sprintf("%d dropped iteration(s) -- scheduled load was not delivered; inspect generator capacity, connection/setup time and target pressure before identifying the limit.", dropped+0);
     if (tpq_sat && cpu_sat) notes[++nn]="thread-pool queue AND CPU are both saturated -- the queue is most likely CPU starvation, not sync-over-async blocking.";
     if (tp_blocked && cpu_sat) notes[++nn]=sprintf("the thread pool grew to %.0f threads on %s core(s) beside the saturated CPU: some work also blocks pool threads synchronously; stacks show the blocking call.", threadpeak+0, sprintf("%.3g",cpucount+0));
     # Only when nothing else explains the queue. A saturated upstream pool
     # already accounts for parked threads, and emitting both notes tells the
     # reader to look for blocking calls AND for the pool limit that is the real
     # cause -- two contradictory instructions from one report.
     if (tpq_sat && !cpu_sat && !up_sat && !tp_blocked) notes[++nn]="thread-pool backlog is high while CPU is not saturated; inspect time-aligned stacks for blocked work before attributing it to sync-over-async.";
     if (verdict=="dependency-bound-db" && dbp_sat) notes[++nn]="most request time is DB AND the pool is saturated -- the DB dependency is the bottleneck via pool exhaustion.";
     if (verdict=="no-clear-bottleneck" && any) notes[++nn]="no captured resource crossed a saturation gate; this alone does not establish headroom or successful delivery.";
     # Retention is reported, never ranked: a leak is a stability defect, not a
     # latency bottleneck, so it must not win the verdict -- but "nothing
     # saturated" must not be the last word when the heap grew by orders of
     # magnitude. Sourced from the in-process before/after gcdump diff.
     if (up_sat) notes[++nn]=sprintf("~%.0f ms of a typical request is spent waiting for an upstream HTTP connection (%.0f in flight, %.0f open) -- the connection pool is the constraint, not the code behind it. Raise MaxConnectionsPerServer / SocketsHttpHandler limits, or reduce concurrency.", (upwait+0)*1000, (has(upactive)?upactive+0:0), (has(upconns)?upconns+0:0));
     if (up_sat && tpq_sat) notes[++nn]="the thread-pool queue is behind a saturated upstream connection pool -- it is a symptom of connection waiting, not independent starvation.";
     if (retain_sat) notes[++nn]=sprintf("managed heap grew %.1f%% between the in-process before/after GC dumps -- RETENTION, not a latency bottleneck; read analysis/runtime/diff-gcdump-before-after.txt for the growing types.", (retaingrowth+0)*100);
     if (tpq_sat==0 && has(tpqpeak) && tpqpeak+0>=TPQ_SAT && tpq_wait>=0 && tpq_wait<TPQ_WAIT_SAT) notes[++nn]=sprintf("thread-pool queue peaked at %d but drains in ~%.1f ms at %.0f rps -- transient depth, not starvation.", tpqpeak+0, tpq_wait*1000, rps+0);
     if (!tp_blocked && has(tpqpeak) && tpqpeak+0>=TPQ_SAT && has(tpqpersistence) && tpqpersistence+0<2 && (tpq_wait<0 || tpq_wait>=TPQ_WAIT_SAT)) notes[++nn]="thread-pool backlog was isolated to individual samples; the captured series does not establish sustained starvation.";
     if (tpq_sat && !has(tpqpersistence)) notes[++nn]="thread-pool backlog persistence is unknown because fewer than two samples were captured; confidence is low.";
     if (faultnote != "") notes[++nn]=faultnote;
     if (ratenote != "") notes[++nn]=ratenote;
     # Why the pool saturated: connections leased across non-database work, or
     # connections busy executing a statement (S22/S21 vs E05).
     # The pool is full when its connections (used plus idle at one sample) reach
     # the maximum: a returned connection counts idle until a waiter takes it, so
     # the used peak alone understates a full pool (E12).
     pool_agrees = (has(dbmax) && dbmax+0>0 && ((has(dbtotal) && dbtotal+0 >= 0.9*(dbmax+0)) || (has(dbused) && dbused+0 >= 0.9*(dbmax+0))));
     if (dbp_sat && !rowlock && pool_agrees && has(dbexec)) {
       if (dbexec+0 <= 0.5*(dbmax+0)) notes[++nn]=sprintf("connections are held outside database commands: the pool held %.0f of its %.0f connections but at most %.0f commands were executing%s -- the lease spans non-database work (an await or a remote call); open the connection just around the command. A larger pool only moves the queue and multiplies server backends.", ((has(dbtotal) && dbtotal+0>0) ? lesser(dbtotal, dbmax) : dbused+0), dbmax+0, dbexec+0, ((has(effdb) && db_share>=0) ? sprintf(", and database time is %.1f ms per request (%.0f%% of the median)", effdb+0, db_share*100) : ""));
       else if (db_outside) notes[++nn]=sprintf("up to %.0f commands were executing on %.0f pool connections, but the database server executes only %.2f ms of the %.1f ms each request spends in database calls -- the command time is round trips and processing in the client, not the queries (the one with the most database time is %s).", lesser(dbexec, dbmax), dbmax+0, srv_ms_req, effdb+0, stmt_text());
       else if (has(stmttot)) notes[++nn]=sprintf("the leased connections are busy executing (up to %.0f commands on %.0f pool connections); the statement with the most database time is %s -- fix the query, not the pool size.", lesser(dbexec, dbmax), dbmax+0, stmt_text());
     }
     if (dbp_sat && cpu_sat && db_outside) notes[++nn]=sprintf("the pool queue follows the saturated CPU: the database server executes %.2f ms of the %.1f ms each request spends in database calls, so connections are held while the starved process does the rest -- relieve the CPU before resizing the pool.", srv_ms_req, effdb+0);
     # The database holds most of a request without a pool queue: name its work (E03).
     if (dep_dom && !dbp_sat && has(stmttot)) notes[++nn]=sprintf("the statement with the most database time is %s.", stmt_text());
     # Only where the database does the work: most of the request (E03) or a full
     # pool executing its queries (E05, E09) -- not a pool held elsewhere (S09).
     db_working = ((dep_dom && !dbp_sat) || (dbp_sat && pool_agrees && has(dbexec) && dbexec+0 > 0.5*(dbmax+0) && !db_outside));
     if (db_working && has(planscanned) && has(planreturned) && planscanned+0>=1000 && planscanned+0 >= 10*((planreturned+0)>1 ? planreturned+0 : 1)) notes[++nn]=sprintf("the representative query plan of the scenario reads %d rows to return %d (%s): rows read only to be discarded -- an index on the filter or sort, or keyset pagination instead of OFFSET, avoids them.", planscanned+0, planreturned+0, ENVIRON["BN_PLAN_NODE"]);
     # Query amplification (S07): the most-called statement per request.
     if (has(stmtmost) && has(reqtotal) && reqtotal+0>0 && (stmtmost+0)/(reqtotal+0) >= AMPLIFY) notes[++nn]=sprintf("query amplification: \"%s\" ran %.0f times per request (%d calls for %d requests)%s -- a query per item of a list (N+1); load the items in one query.", ENVIRON["BN_MOST_QUERY"], (stmtmost+0)/(reqtotal+0), stmtmost+0, reqtotal+0, ((has(stmtdiscards) && stmtdiscards+0 >= 2*(reqtotal+0)) ? sprintf(", with %.0f connection resets (DISCARD ALL) per request: each query leased and returned its own connection", (stmtdiscards+0)/(reqtotal+0)) : ""));
     if (has(pgback) && has(pgmax) && pgmax+0>0 && pgback+0 >= 0.25*(pgmax+0)) notes[++nn]=sprintf("the application held %d PostgreSQL backends mid-load (%d not active) against max_connections %d -- every pooled connection is a server process; size pools to the work the server can run, not to request concurrency.", pgback+0, (pgback+0)-(pgact+0), pgmax+0);
     if (has(pgdl) && pgdl+0>0 && !dl_sat) notes[++nn]=sprintf("%d PostgreSQL deadlock(s) in the measured window (%.2f%% of %d transactions): below the %.0f%% that makes deadlocks the bottleneck, but each one aborted a transaction.", pgdl+0, (dl_share>=0 ? dl_share*100 : 0), dl_txn, DEADLOCK_SAT*100);
     if (rowlock && verdict != "db-lock-contention") notes[++nn]=sprintf("row-lock contention: %d of %d active database sessions wait on a row lock%s (last statement: %s) -- the database finding is lock waiting; any pool saturation is its consequence.", pglock+0, pgact+0, holder, ENVIRON["BN_HOLDER_QUERY"]);
     if (has(effalloc) && effalloc+0 >= ALLOC_NOTE && (!has(allocrate) || allocrate+0 >= ALLOC_RATE_NOTE)) notes[++nn]=sprintf("allocation pressure: %.1f MB allocated per request%s -- allocation drives GC and CPU work even while pauses stay short%s; the allocation profile names the allocating call sites (arrays of 85,000 bytes or more go to the large object heap).", (effalloc+0)/1048576, (has(allocrate) ? sprintf(" (peak %.0f MB/s)", (allocrate+0)/1048576) : ""), (gc_sat ? "" : " (GC pauses stayed below the saturation gate)"));
     # Dependency health (reported, never ranked): an ineffective cache, eviction
     # without TTLs, a database refresh per miss, a new connection per request.
     if (cache_ops>=100 && (chits+0)/cache_ops < 0.1) notes[++nn]=sprintf("the Redis cache is ineffective: %d hits against %d misses (%.1f%% hit ratio%s).", chits+0, cmiss+0, (chits+0)*100/cache_ops, ((has(reqtotal) && reqtotal+0>0) ? sprintf(", %.2f misses per request", (cmiss+0)/(reqtotal+0)) : ""));
     if (has(cevict) && cevict+0>0 && has(cexp) && cexp+0==0) notes[++nn]=sprintf("Redis evicted %d keys while none of its %d keys has a TTL: the cache fills to maxmemory and relies on eviction, so hot keys are evicted with cold ones.", cevict+0, ckeys+0);
     # One database read per miss is plain cache-aside. Many misses per expired
     # key, each refreshed, is concurrent requests repeating the same refresh
     # (S12: 2,058 misses for 13 expirations).
     if (has(refcalls) && refcalls+0>0 && has(cexpired) && cexpired+0>0 && (cmiss+0)/(cexpired+0)>=STAMPEDE_MISSES) notes[++nn]=sprintf("cache stampede: %d misses for %d expired keys (~%.0f per expiry), each refreshed from the database by \"%s\" (%d calls) -- concurrent requests that miss the same expired key all repeat the refresh; coalesce refreshes per key or refresh ahead of expiry.", cmiss+0, cexpired+0, (cmiss+0)/(cexpired+0), ENVIRON["BN_REFRESH_QUERY"], refcalls+0);
     redis_churn = (has(cconns) && has(reqtotal) && reqtotal+0>0 && cconns+0>=100 && (cconns+0)/(reqtotal+0)>=0.5);
     if (redis_churn) notes[++nn]=sprintf("%d new Redis connections for %d requests (%.2f per request)%s: the client connects per operation instead of reusing one multiplexer.", cconns+0, reqtotal+0, (cconns+0)/(reqtotal+0), (has(apitw) ? sprintf(", API TIME_WAIT peaked at %d", apitw+0) : ""));
     # Connection footprint (S24, S26): sockets the application holds open.
     if (!redis_churn && has(cclients) && has(procs) && procs+0>0 && (cclients+0)/(procs+0)>=4) notes[++nn]=sprintf("Redis held %d client connections mid-load for %d application process(es): one multiplexer needs one per process, so the application runs several multiplexers or pools of them; each is a socket and server-side client state.", cclients+0, procs+0);
     if (has(upconns) && upconns+0>=32) notes[++nn]=sprintf("the application held %.0f open connections to %s at peak: each is a socket on both ends; bound the handler to the connections the upstream needs (MaxConnectionsPerServer).", upconns+0, (uppool==""?"the upstream":uppool));
     if (has(rbconns) && has(reqtotal) && reqtotal+0>0 && rbconns+0>=100 && (rbconns+0)/(reqtotal+0)>=0.5) notes[++nn]=sprintf("%d RabbitMQ connections and %d channels opened for %d requests (%.2f per request): the client opens a connection per publish instead of reusing one connection and its channels.", rbconns+0, rbchan+0, reqtotal+0, (rbconns+0)/(reqtotal+0));
     if (span_dom && verdict != "dependency-bound-" span_kind) notes[++nn]=sprintf("%s, though %s ranks higher.", span_cover(), verdict);
     # Dependency amplification (S13: 100 sequential Redis reads per request).
     # Redis counts every key lookup itself, so its count per request is the
     # authority; spans are sampled and the application exporter drops them when
     # it cannot keep up (S13: span metrics saw 18-63 of the 100 lookups).
     lookups_req = (cache_ops>=0 && has(reqtotal) && reqtotal+0>0) ? cache_ops/(reqtotal+0) : -1;
     if (lookups_req >= AMPLIFY) notes[++nn]=sprintf("dependency amplification: Redis served ~%.0f key lookups per request (%d for %d requests) -- lookups issued one after another add their round trips; fetch them in one call (MGET or pipelining), or cache the assembled value.", lookups_req, cache_ops, reqtotal+0);
     else if (depsys != "" && span_per_req >= AMPLIFY) notes[++nn]=sprintf("dependency amplification: each request makes ~%.0f %s calls%s -- calls issued one after another add their round trips; batch or pipeline them, or fetch the data once.", span_per_req, span_target, (dep_ms_req>=0 ? sprintf(" (%.1f ms per request in their spans)", dep_ms_req) : ""));
     if (depsys == "redis" && span_per_req>=0 && lookups_req>=1 && span_per_req < 0.8*lookups_req) notes[++nn]=sprintf("span metrics saw ~%.0f Redis calls per request against the ~%.0f key lookups per request Redis served: spans were lost before Tempo (the application span exporter drops spans when it cannot keep up), so the Redis share of server time (%.0f%%) is a lower bound.", span_per_req, lookups_req, dshare*100);
     if (exc_per_req>=EXC_NOTE) notes[++nn]=sprintf("exception pressure: ~%.0f exceptions per request (peak %.0f/s, mostly %s) -- every throw captures a stack trace and unwinds; the exceptions profile names the throwing call site.", exc_per_req, excpeak+0, (ENVIRON["BN_EXC_TYPE"]=="" ? "of an unknown type" : ENVIRON["BN_EXC_TYPE"]));
     if (nsatres>=2) notes[++nn]=sprintf("%d resources saturated at once (%s); primary bottleneck(s): %s. Address them together, not just the top-scored one; see resources.* for each.", nsatres, satreslist, primlist);

     # ----- reason line: describe the PRIMARY (top) resource; a composite verdict lists
     # the concurrent ones as a prefix so nothing is hidden. -----
     if (verdict=="insufficient-data") reason="no runtime resource signals were captured (black-box run, or metrics missing) -- cannot classify.";
     else if (client_sat && !gen_sat) reason=sprintf("the target rejected most requests as client errors (HTTP %s on %.0f%% of %d requests): the workload is invalid (authentication, authorization or request contract), so no capacity conclusion is possible.", sttopcode, (sttopn+0)/(sttotal+0)*100, sttotal+0);
     else if (gen_sat) reason=sprintf("the load generator exhausted its ports: %d sockets in TIME_WAIT toward %s (%.0f%% of the %d-port ephemeral range). Connections failed on the generator host, so errors, throughput and latency describe the generator, not the target; reuse connections or spread the load across generator hosts.", gentw+0, (genhost==""?"the target":genhost), gen_ratio*100, genrange+0);
     else if (bi==0) reason="no resource crossed a saturation threshold at this load.";
     else {
       if (cand[bi]=="cpu-bound") reason=sprintf("CPU utilisation peaked at %.0f%% of %s core(s); aggregate CPU cost is %.2f ms per completed operation.", (cpu_util>=0?cpu_util*100:0), (has(cpucount)?sprintf("%.3g",cpucount+0):"?"), (has(effcpu)?effcpu+0:0));
       else if (cand[bi]=="threadpool-starved" && tp_blocked) reason=sprintf("the thread pool grew to %.0f threads on %s core(s) while CPU peaked at %.0f%%: requests block pool threads synchronously (sync-over-async or blocking I/O) and the runtime injects threads to keep up; time-aligned stacks show the blocking call.", threadpeak+0, sprintf("%.3g",cpucount+0), (cpu_util>=0?cpu_util*100:0));
       else if (cand[bi]=="threadpool-starved") reason=sprintf("thread-pool queue peaked at %.0f work items waiting for a worker thread.", tpqpeak+0);
       else if (cand[bi]=="lock-bound") reason=sprintf("~%.1f Monitor lock contention(s) per request (%.0f/s peak).", lock_per_req, (has(lockrate)?lockrate+0:0));
       else if (cand[bi]=="gc-bound") reason=sprintf("the GC paused ~%.0f%% of wall-clock (peak); ~%.0f%% of a request is GC pause.", (gcpause+0)*100, (gc_share>=0?gc_share*100:0));
       else if (cand[bi]=="db-deadlock") reason=sprintf("%d PostgreSQL deadlock(s) in the measured window (%.1f per 1,000 requests; %.0f%% of %d transactions rolled back, SQLSTATE 40P01): concurrent transactions lock rows in conflicting orders, and the lock waits until the deadlock timeout are the database time. Take row locks in one consistent order, keep transactions short, and retry the victim.", pgdl+0, ((has(reqtotal) && reqtotal+0>0) ? (pgdl+0)*1000/(reqtotal+0) : 0), (((pgrb+0)+(pgcm+0))>0 ? (pgrb+0)*100/((pgrb+0)+(pgcm+0)) : 0), (pgrb+0)+(pgcm+0));
       else if (cand[bi]=="db-lock-contention") reason=sprintf("%d of %d active database sessions wait on a row lock%s%s: requests serialize on the locked rows%s.", pglock+0, pgact+0, (has(pgblocked) ? sprintf(" (%d blocked by another session)", pgblocked+0) : ""), holder, (dbp_sat ? sprintf(", and the connections held while waiting saturate the pool (%.0f requests waiting), so a larger pool only adds waiters", dbpending+0) : ""));
       else if (cand[bi]=="db-pool-saturated") {
         tmotxt = ((has(dbtmo) && dbtmo+0>0) ? sprintf("; %d connection acquisition timeout(s) in the window", dbtmo+0) : "");
         if (pool_agrees) reason=sprintf("%.0f request(s) peak waiting for a pooled DB connection (used %.0f/%.0f)%s.", dbpending+0, dbused+0, dbmax+0, tmotxt);
         # All connections created before the window, none re-created in it,
         # and fewer in use plus idle than the pool holds: the rest were taken
         # and never returned (S09). Normal churn re-creates connections.
         else if (has(dbmade) && has(dbmax) && dbmax+0>0 && dbmade+0>=dbmax+0 && has(dbmadewin) && dbmadewin+0==0 && (dbused+0)+(has(dbidle)?dbidle+0:0) < dbmax+0) reason=sprintf("%.0f request(s) peak waiting for a pooled DB connection: all %.0f connections were created before the window, none since, and at most %.0f in use and %.0f idle, so the others are held outside the pool (taken and not returned)%s.", dbpending+0, dbmax+0, (has(dbused)?dbused+0:0), (has(dbidle)?dbidle+0:0), tmotxt);
         else reason=sprintf("%.0f request(s) peak waiting for a pooled DB connection (pool max %.0f)%s.", dbpending+0, (has(dbmax)?dbmax+0:0), tmotxt);
       }
       else if (cand[bi]=="upstream-pool-saturated") reason=sprintf("a typical request waits ~%.0f ms for an upstream HTTP connection to %s (%.0f in flight against %.0f open connection(s)).", (upwait+0)*1000, (uppool==""?"the dependency":uppool), (has(upactive)?upactive+0:0), (has(upconns)?upconns+0:0));
       # The share is a MEAN cost over the MEDIAN latency; a skewed distribution
       # (S27: ~1 s deadlock aborts and ~5 s timeouts) pushes it past 100%, which
       # cannot be read as "part of a typical request".
       else if (cand[bi]=="dependency-bound-db" && db_share > 1) reason=sprintf("mean database time per request (%.1f ms) exceeds the median request latency (%.1f ms): the latency distribution is skewed and requests are dominated by DB execution time (pool not saturated -- not pool waiting).", effdb+0, p50+0);
       else if (cand[bi]=="dependency-bound-db") reason=sprintf("~%.0f%% of a typical request is spent in the database (pool not saturated -- it is DB execution time, not pool waiting).", db_share*100);
       else if (cand[bi]=="dependency-bound-" span_kind) reason=sprintf("%s: requests wait on the dependency, not on their own resources.", span_cover());
       else if (cand[bi]=="wait-bound" && app_wait) reason=sprintf("~%.0f%% of a typical request (p50 %.0f ms) is spent waiting, not computing: %.2f ms of CPU per request and no captured resource saturated. The wait is the application pool \"%s\"%s: %d waits in the window averaged %.0f ms (%.0f%% of the median), with up to %d lease(s) held.", wait_share*100, p50+0, effcpu+0, ENVIRON["BN_APP_POOL"], (apsize!="" ? sprintf(" (configured size %s)", apsize) : ""), apwaits+0, apwait+0, (apwait+0)*100/(p50+0), apactive+0);
       else if (cand[bi]=="wait-bound") reason=sprintf("~%.0f%% of a typical request (p50 %.0f ms) is spent waiting, not computing: %.2f ms of CPU per request and no captured resource saturated. The wait is outside the measured pools -- an async lock or semaphore, a delay, or an external call; a dump (dumpasync) shows what the waiting requests await.", wait_share*100, p50+0, effcpu+0);
       else reason="";
       if (concurrent) reason=sprintf("Concurrent bottlenecks (%s). Primary -> ", primlist) reason;
       # Surface EVERY saturated resource (from the booleans) whenever >=2 are saturated --
       # including a secondary saturation next to a single primary, and the thread pool.
       if (nsatres>=2) reason=reason sprintf(" [%d resources saturated: %s]", nsatres, satreslist);
     }

     # ----- emit JSON -----
     gsub(/\\/,"\\\\",reason); gsub(/"/,"\\\"",reason);
     printf "{";
     printf "\"kind\":\"bottleneck\",\"runId\":\"%s\",\"scenarioId\":\"%s\",\"captureStatus\":\"%s\",", runid, scen, status;
     printf "\"verdict\":\"%s\",\"confidence\":\"%s\",\"concurrent\":%s,\"contributors\":[%s],\"saturatedResources\":[%s],\"reason\":\"%s\",", verdict, conf, (concurrent?"true":"false"), contribjson, satresjson, reason;
     printf "\"resources\":{";
     printf "\"cpu\":{\"coresBusyPeak\":%s,\"cpuCount\":%s,\"utilizationPct\":%s,\"msPerRequest\":%s,\"latencySharePct\":%s,\"saturated\":%s},", jnum(cpubusy), jnum(cpucount), jpct(cpu_util), jnum(effcpu), jpct(cpu_share), (cpu_sat?"true":"false");
     printf "\"threadPool\":{\"queuePeak\":%s,\"queueAvg\":%s,\"threadCountPeak\":%s,\"queueWaitSeconds\":%s,\"blockedThreads\":%s,\"saturated\":%s},", jnum(tpqpeak), jnum(tpqavg), jnum(threadpeak), (tpq_wait>=0?sprintf("%.6f",tpq_wait):"null"), (tp_blocked?"true":"false"), ((tpq_sat||tp_blocked)?"true":"false");
     printf "\"upstreamPool\":{\"meanWaitSeconds\":%s,\"activeRequestsPeak\":%s,\"openConnectionsPeak\":%s,\"pool\":%s,\"latencySharePct\":%s,\"saturated\":%s},", jnum(upwait), jnum(upactive), jnum(upconns), (uppool==""?"null":"\"" uppool "\""), jpct(up_share), (up_sat?"true":"false");
     printf "\"retention\":{\"heapGrowthPct\":%s,\"source\":\"%s\",\"flagged\":%s},", (has(retaingrowth)?sprintf("%.1f",(retaingrowth+0)*100):"null"), (has(retaingrowth)?"analysis/runtime/diff-gcdump-before-after.txt":"not-captured"), (retain_sat?"true":"false");
     printf "\"gc\":{\"pauseFractionPeak\":%s,\"pauseMsPerRequest\":%s,\"allocBytesPerRequest\":%s,\"allocRatePeak\":%s,\"latencySharePct\":%s,\"saturated\":%s},", jnum(gcpause), jnum(effgc), jnum(effalloc), jnum(allocrate), jpct(gc_share), (gc_sat?"true":"false");
     printf "\"locks\":{\"contentionsPerSecPeak\":%s,\"contentionsPerRequest\":%s,\"saturated\":%s},", jnum(lockrate), (lock_per_req>=0?sprintf("%.3f",lock_per_req):"null"), (lock_sat?"true":"false");
     printf "\"dbPool\":{\"pendingPeak\":%s,\"usedPeak\":%s,\"connectionsPeak\":%s,\"max\":%s,\"utilizationPct\":%s,\"acquisitionTimeouts\":%s,\"connectionsCreated\":%s,\"executingPeak\":%s,\"saturated\":%s},", jnum(dbpending), jnum(dbused), jnum(dbtotal), jnum(dbmax), jpct(dbpool_util), jnum(dbtmo), jnum(dbmade), jnum(dbexec), (dbp_sat?"true":"false");
     printf "\"dbServer\":{\"deadlocks\":%s,\"rollbacks\":%s,\"commits\":%s,\"maxConnections\":%s,\"backendsMidload\":%s,\"activeMidload\":%s,\"idleInTransactionMidload\":%s,\"lockWaitersMidload\":%s,\"blockedMidload\":%s,\"rowLockContention\":%s,\"deadlocked\":%s,\"execMsPerRequest\":%s,\"serverShareOfDbTimePct\":%s,\"mostCalledPerRequest\":%s,\"planRowsRead\":%s,\"planRowsReturned\":%s},", jnum(pgdl), jnum(pgrb), jnum(pgcm), jnum(pgmax), jnum(pgback), jnum(pgact), jnum(pgidletx), jnum(pglock), jnum(pgblocked), (rowlock?"true":"false"), (dl_sat?"true":"false"), (srv_ms_req>=0?sprintf("%.4f",srv_ms_req):"null"), jpct(srv_share), ((has(stmtmost) && has(reqtotal) && reqtotal+0>0)?sprintf("%.2f",(stmtmost+0)/(reqtotal+0)):"null"), jnum(planscanned), jnum(planreturned);
     printf "\"cache\":{\"hits\":%s,\"misses\":%s,\"hitRatioPct\":%s,\"expiredKeys\":%s,\"evictedKeys\":%s,\"keys\":%s,\"expiringKeys\":%s,\"connectionsAccepted\":%s,\"connectedClientsMidload\":%s},", jnum(chits), jnum(cmiss), (cache_ops>0 ? sprintf("%.1f", (chits+0)*100/cache_ops) : "null"), jnum(cexpired), jnum(cevict), jnum(ckeys), jnum(cexp), jnum(cconns), jnum(cclients);
     printf "\"dependency\":{\"system\":%s,\"serverTimeSharePct\":%s,\"msPerRequest\":%s,\"callsPerRequest\":%s,\"callsBasis\":%s,\"nestedServerRequestsPerRequest\":%s,\"dominant\":%s},", (depsys=="" ? "null" : "\"" depsys "\""), jpct(depsys=="" ? -1 : dshare), (dep_ms_req>=0 ? sprintf("%.3f", dep_ms_req) : "null"), (span_per_req>=0 ? sprintf("%.2f", span_per_req) : "null"), (span_per_req<0 ? "null" : (entry ? "\"entry-requests\"" : "\"server-spans\"")), (nested_per_req>=0 ? sprintf("%.2f", nested_per_req) : "null"), (span_dom?"true":"false");
     printf "\"broker\":{\"connectionsOpened\":%s,\"channelsOpened\":%s},", jnum(rbconns), jnum(rbchan);
     printf "\"appPool\":{\"pool\":%s,\"configuredSize\":%s,\"meanWaitMs\":%s,\"waits\":%s,\"activeLeasesPeak\":%s,\"holdsWait\":%s},", (ENVIRON["BN_APP_POOL"]=="" ? "null" : "\"" ENVIRON["BN_APP_POOL"] "\""), (apsize ~ /^[0-9]+$/ ? apsize : "null"), jnum(apwait), jnum(apwaits), jnum(apactive), (app_wait?"true":"false");
     printf "\"exceptions\":{\"ratePeak\":%s,\"rateMean\":%s,\"perRequest\":%s},", jnum(excpeak), jnum(excmean), (exc_per_req>=0 ? sprintf("%.3f", exc_per_req) : "null");
     printf "\"wait\":{\"latencySharePct\":%s,\"bound\":%s},", jpct(wait_share), (verdict=="wait-bound"?"true":"false");
     printf "\"dependencyDb\":{\"msPerRequest\":%s,\"latencySharePct\":%s,\"dominant\":%s},", jnum(effdb), jpct(db_share), (dep_dom?"true":"false");
     printf "\"responses\":{\"total\":%s,\"clientErrors\":%s,\"shed\":%s,\"serverErrors\":%s,\"clientErrorSharePct\":%s,\"shedSharePct\":%s},", jnum(sttotal), jnum(stclient), jnum(stshed), jnum(stserver), jpct(client_share), jpct(shed_share);
     printf "\"generatorPorts\":{\"timeWaitPeak\":%s,\"ephemeralRange\":%s,\"utilizationPct\":%s,\"exhausted\":%s},", jnum(gentw), jnum(genrange), jpct(gen_ratio), (gen_sat?"true":"false");
     printf "\"otherLatencySharePct\":%s", jpct(other_share);
     printf "},";
     printf "\"workload\":{\"rps\":%s,\"p50Ms\":%s,\"p99Ms\":%s,\"errorRate\":%s,\"droppedIterations\":%s},", jnum(rps), jnum(p50), jnum(p99), jnum(errate), (has(dropped)?sprintf("%d",dropped+0):"null");
     printf "\"notes\":[";
     for(i=1;i<=nn;i++){ gsub(/\\/,"\\\\",notes[i]); gsub(/"/,"\\\"",notes[i]); printf "%s\"%s\"", (i>1?",":""), notes[i] }
     printf "]}\n";
   }')"

[[ -n "${json}" ]] || { echo "bottleneck: computation produced no output." >&2; exit 3; }
printf '%s\n' "${json}" > "${out}"

# Human summary.
read -r verdict conf reason < <(jqd -r '[.verdict,.confidence,.reason]|@tsv' < "${out}" 2>/dev/null || echo "? ? ?")
echo "Bottleneck for ${scenario} (run ${run_id})"
echo "  verdict:    ${verdict}  (confidence: ${conf})"
echo "  reason:     ${reason}"
jqd -r '.resources | "  cpu util:   \(.cpu.utilizationPct // "n/a")%  (aggregate CPU cost / median latency: \(.cpu.latencySharePct // "n/a")%)\n  tp queue:   peak \(.threadPool.queuePeak // "n/a")\n  gc pause:   peak \(.gc.pauseFractionPeak // "n/a")  (\(.gc.latencySharePct // "n/a")% of a request)\n  locks:      \(.locks.contentionsPerRequest // "n/a") / request\n  db pool:    pending peak \(.dbPool.pendingPeak // "n/a"), used \(.dbPool.usedPeak // "n/a")/\(.dbPool.max // "n/a")\n  db time:    \(.dependencyDb.latencySharePct // "n/a")% of a request"' \
  < "${out}" 2>/dev/null || true
jqd -r '.notes[]? | "  note: " + .' < "${out}" 2>/dev/null || true
echo "  wrote ${out}"
