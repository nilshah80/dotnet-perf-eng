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
#   _LOCK_SAT (1.0 contentions/req), _DEP_SHARE (0.50).
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
dbpool_worst() { # -> "usedPeak\tmaxCfg\tpendingPeak" of the most-saturated pool
  local f="${mdir}/database_pool_metrics.json"; [[ -s "${f}" ]] || return 0
  jqd -r '
    [ .data.result[]?
      | { pool: (.metric.db_client_connection_pool_name // "default"),
          nm:   (.metric.__name__ // ""),
          st:   (.metric.db_client_connection_state // ""),
          peak: ([ (.values // (if .value then [.value] else [] end))[] | .[1]|tonumber ] | if length==0 then 0 else max end) } ]
    | group_by(.pool)
    | map({ used: ([ .[] | select(.nm=="db_client_connection_count" and .st=="used") | .peak ] | max // 0),
            maxc: ([ .[] | select(.nm=="db_client_connection_max") | .peak ] | max // 0),
            pend: ([ .[] | select(.nm | test("pending_requests")) | .peak ] | max // 0) })
    | map(. + {util: (if .maxc>0 then .used/.maxc else 0 end)})
    # pending dominates the ranking; utilisation breaks ties.
    | (sort_by([.pend, .util]) | last) // {used:0,maxc:0,pend:0}
    | "\(.used)\t\(.maxc)\t\(.pend)"' < "${f}" 2>/dev/null | head -1
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
  jqd -r '
    [ .data.result[]?
      | { pool: (.metric.server_address // .metric.http_client_connection_pool_name // "default"),
          nm:   (.metric.__name__ // ""),
          st:   (.metric.http_connection_state // ""),
          peak: ([ (.values // (if .value then [.value] else [] end))[] | .[1]|tonumber ] | if length==0 then 0 else max end) } ]
    | group_by(.pool)
    | map({ pool: .[0].pool,
            qsum: ([ .[] | select(.nm=="http_client_request_time_in_queue_seconds_sum") | .peak ] | add // 0),
            qcnt: ([ .[] | select(.nm=="http_client_request_time_in_queue_seconds_count") | .peak ] | add // 0),
            act:  ([ .[] | select(.nm=="http_client_active_requests") | .peak ] | max // 0),
            conn: ([ .[] | select(.nm=="http_client_open_connections") | .peak ] | add // 0) })
    | map(. + {wait: (if .qcnt>0 then .qsum/.qcnt else 0 end)})
    | (sort_by(.wait) | last) // {wait:0,act:0,conn:0,pool:"none"}
    | "\(.wait)\t\(.act)\t\(.conn)\t\(.pool)"' < "${f}" 2>/dev/null | head -1
}

cpu_busy_peak="$(mstat_sum process_cpu max)"
cpu_count="$(mstat cpu_count last)"; [[ -z "${cpu_count}" ]] && cpu_count="$(mstat cpu_count max)"
tpq_peak="$(mstat thread_pool_queue max)"; tpq_avg="$(mstat thread_pool_queue avg)"
thread_peak="$(mstat thread_count max)"
gc_pause_peak="$(mstat gc_pause max)"
alloc_rate_peak="$(mstat gc_allocation_rate max)"
lock_rate_peak="$(mstat lock_contention max)"
db_used_peak=""; db_max=""; db_pending_peak=""
# `read` returns non-zero at EOF, so an absent or empty database_pool_metrics.json
# (no database in this lab, or a failed Prometheus query) would abort the whole
# classifier under `set -e` -- exit 1, no message, no verdict at all. A signal
# that was not captured must degrade that ONE dimension to "not captured", not
# destroy the diagnosis of every other resource.
if read_fields 3 < <(dbpool_worst | tr '\t' '\n'); then
  db_used_peak="${TSV_FIELDS[0]}"; db_max="${TSV_FIELDS[1]}"; db_pending_peak="${TSV_FIELDS[2]}"
fi
up_wait=""; up_active=""; up_conns=""; up_pool=""
if read_fields 4 < <(upstream_worst | tr '\t' '\n'); then
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

# --- decision + JSON (awk; -1 == not captured) ------------------------------
d() { [[ -n "$1" ]] && printf '%s' "$1" || printf -- '-1'; }
json="$(awk \
  -v scen="${scenario}" -v runid="${run_id}" -v status="${status}" \
  -v rps="$(d "${rps}")" -v p50="$(d "${p50}")" -v p99="$(d "${p99}")" \
  -v errate="$(d "${errate}")" -v dropped="$(d "${dropped}")" \
  -v effcpu="$(d "${eff_cpu}")" -v effgc="$(d "${eff_gc}")" -v effdb="$(d "${eff_db}")" -v effalloc="$(d "${eff_alloc}")" \
  -v cpubusy="$(d "${cpu_busy_peak}")" -v cpucount="$(d "${cpu_count}")" \
  -v tpqpeak="$(d "${tpq_peak}")" -v tpqavg="$(d "${tpq_avg}")" -v threadpeak="$(d "${thread_peak}")" \
  -v gcpause="$(d "${gc_pause_peak}")" -v allocrate="$(d "${alloc_rate_peak}")" -v lockrate="$(d "${lock_rate_peak}")" \
  -v dbpending="$(d "${db_pending_peak}")" -v dbused="$(d "${db_used_peak}")" -v dbmax="$(d "${db_max}")" \
  -v upwait="$(d "${up_wait}")" -v upactive="$(d "${up_active}")" -v upconns="$(d "${up_conns}")" -v uppool="${up_pool:-}" \
  -v UP_WAIT_SAT="${PERFLAB_USE_UPSTREAM_WAIT_SAT:-0.05}" \
  -v CPU_SAT="${PERFLAB_USE_CPU_SAT:-0.85}" -v TPQ_SAT="${PERFLAB_USE_TPQ_SAT:-2}" \
  -v TPQ_WAIT_SAT="${PERFLAB_USE_TPQ_WAIT_SAT:-0.05}" -v RETAIN_SAT="${PERFLAB_USE_RETAIN_SAT:-0.25}" \
  -v retaingrowth="$(d "${retain_growth}")" \
  -v GC_SAT="${PERFLAB_USE_GC_SAT:-0.10}" -v LOCK_SAT="${PERFLAB_USE_LOCK_SAT:-1.0}" -v DEP_SHARE="${PERFLAB_USE_DEP_SHARE:-0.50}" \
  'function has(x){ return (x+0) >= 0 && x != "" }
   function share(ms){ return (has(ms) && has(p50) && p50+0>0) ? (ms+0)/(p50+0) : -1 }
   function jnum(x){ return (has(x) ? sprintf("%.4f", x+0) : "null") }
   function jpct(x){ return (x>=0 ? sprintf("%.1f", x*100) : "null") }
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
     tpq_sat  = (has(tpqpeak) && tpqpeak+0>=TPQ_SAT && (tpq_wait<0 || tpq_wait>=TPQ_WAIT_SAT));
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

     # ----- rank candidates. Saturation signals outweigh mere utilisation/shares;
     # among shares, the largest slice of the request wins. Score in [0,~2]. -----
     n=0;
     if (dbp_sat){ cand[++n]="db-pool-saturated"; sc[n]=1.5 + (has(dbpending)?dbpending+0:0)/100 }
     # A thread-pool queue is only its OWN bottleneck (sync-over-async / blocking
     # starvation, threads parked not busy) when CPU is NOT saturated. When CPU is also
     # saturated the queue is a SYMPTOM of CPU starvation, so cpu-bound must win -- do not
     # add a competing threadpool-starved candidate whose queue score would overpower it.
     # A thread-pool queue behind a saturated upstream pool is a SYMPTOM: the
     # threads are waiting on connection acquisition, not starved by blocking
     # work of their own. Scored above threadpool-starved so the measured wait
     # wins over the queue that the wait produced.
     if (up_sat){ cand[++n]="upstream-pool-saturated"; sc[n]=1.45 + (upwait+0) }
     if (tpq_sat && !cpu_sat){ cand[++n]="threadpool-starved"; sc[n]=1.3 + (tpqpeak+0)/100 }
     if (lock_sat){ cand[++n]="lock-bound"; sc[n]=1.2 + lock_per_req/10 }
     if (cpu_sat){ cand[++n]="cpu-bound"; sc[n]=1.0 + cpu_util }
     if (gc_sat){ cand[++n]="gc-bound"; sc[n]=1.0 + (gcpause+0) }
     # dependency-bound-db means the request time is DB EXECUTION, not pool WAITING -- its
     # reason explicitly assumes the pool is NOT saturated. So it is mutually exclusive with
     # db-pool-saturated: only a candidate when the pool is not saturated.
     if (dep_dom && !dbp_sat){ cand[++n]="dependency-bound-db"; sc[n]=0.5 + db_share }
     # utilisation-only fallbacks (no hard saturation, but a resource clearly dominates)
     if (n==0 && cpu_share>=0.5){ cand[++n]="cpu-bound"; sc[n]=0.4+cpu_share }
     if (n==0 && gc_share>=0.3){ cand[++n]="gc-bound"; sc[n]=0.4+gc_share }
     if (n==0 && cpu_util>=0.6){ cand[++n]="cpu-bound"; sc[n]=0.3+cpu_util }

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
     if (tpq_sat){ nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"threadPool\""; satreslist=satreslist (nsatres>1?", ":"") "threadPool" }
     if (gc_sat) { nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"gc\"";         satreslist=satreslist (nsatres>1?", ":"") "gc" }
     if (lock_sat){ nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"locks\"";     satreslist=satreslist (nsatres>1?", ":"") "locks" }
     if (dbp_sat){ nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"dbPool\"";     satreslist=satreslist (nsatres>1?", ":"") "dbPool" }
     if (up_sat) { nsatres++; satresjson=satresjson (nsatres>1?",":"") "\"upstreamPool\""; satreslist=satreslist (nsatres>1?", ":"") "upstreamPool" }

     # any resource signal captured at all?
     any = (cpu_util>=0) || has(tpqpeak) || has(gcpause) || (lock_per_req>=0) || has(dbpending) || (db_share>=0) || has(upwait);
     if (!any) verdict="insufficient-data";

     # ----- confidence -----
     if (verdict=="insufficient-data") conf="low";
     else if (dbp_sat || tpq_sat || up_sat || (cpu_util>=0.9) || (gc_sat && gcpause+0>=0.2) || lock_sat) conf="high";
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

     # ----- notes -----
     nn=0;
     if (has(errate) && errate+0>0.01) notes[++nn]=sprintf("error_rate=%.3f -- the system is failing requests; the bottleneck reasoning is about an OVERLOADED system (see the gate).", errate+0);
     if (has(dropped) && dropped+0>0) notes[++nn]=sprintf("%d dropped iteration(s) -- offered load exceeded served throughput; capacity is already past the knee.", dropped+0);
     if (tpq_sat && cpu_sat) notes[++nn]="thread-pool queue AND CPU are both saturated -- the queue is most likely CPU starvation, not sync-over-async blocking.";
     # Only when nothing else explains the queue. A saturated upstream pool
     # already accounts for parked threads, and emitting both notes tells the
     # reader to look for blocking calls AND for the pool limit that is the real
     # cause -- two contradictory instructions from one report.
     if (tpq_sat && !cpu_sat && !up_sat) notes[++nn]="thread-pool queue is high while CPU is NOT saturated -- classic sync-over-async / blocking-call starvation (threads parked, not busy).";
     if (verdict=="dependency-bound-db" && dbp_sat) notes[++nn]="most request time is DB AND the pool is saturated -- the DB dependency is the bottleneck via pool exhaustion.";
     if (verdict=="no-clear-bottleneck" && any) notes[++nn]="no resource crossed a saturation gate -- the system has headroom at this load (push RPS with a capacity profile to find the knee).";
     # Retention is reported, never ranked: a leak is a stability defect, not a
     # latency bottleneck, so it must not win the verdict -- but "nothing
     # saturated" must not be the last word when the heap grew by orders of
     # magnitude. Sourced from the in-process before/after gcdump diff.
     if (up_sat) notes[++nn]=sprintf("~%.0f ms of a typical request is spent waiting for an upstream HTTP connection (%.0f in flight, %.0f open) -- the connection pool is the constraint, not the code behind it. Raise MaxConnectionsPerServer / SocketsHttpHandler limits, or reduce concurrency.", (upwait+0)*1000, (has(upactive)?upactive+0:0), (has(upconns)?upconns+0:0));
     if (up_sat && tpq_sat) notes[++nn]="the thread-pool queue is behind a saturated upstream connection pool -- it is a symptom of connection waiting, not independent starvation.";
     if (retain_sat) notes[++nn]=sprintf("managed heap grew %.1f%% between the in-process before/after GC dumps -- RETENTION, not a latency bottleneck; read analysis/runtime/diff-gcdump-before-after.txt for the growing types.", (retaingrowth+0)*100);
     if (tpq_sat==0 && has(tpqpeak) && tpqpeak+0>=TPQ_SAT && tpq_wait>=0) notes[++nn]=sprintf("thread-pool queue peaked at %d but drains in ~%.1f ms at %.0f rps -- transient depth, not starvation.", tpqpeak+0, tpq_wait*1000, rps+0);
     if (nsatres>=2) notes[++nn]=sprintf("%d resources saturated at once (%s); primary bottleneck(s): %s. Address them together, not just the top-scored one; see resources.* for each.", nsatres, satreslist, primlist);

     # ----- reason line: describe the PRIMARY (top) resource; a composite verdict lists
     # the concurrent ones as a prefix so nothing is hidden. -----
     if (verdict=="insufficient-data") reason="no runtime resource signals were captured (black-box run, or metrics missing) -- cannot classify.";
     else if (bi==0) reason="no resource crossed a saturation threshold at this load.";
     else {
       if (cand[bi]=="cpu-bound") reason=sprintf("CPU utilisation peaked at %.0f%% of %s core(s); ~%.0f%% of a typical request is on-CPU.", (cpu_util>=0?cpu_util*100:0), (has(cpucount)?sprintf("%d",cpucount+0):"?"), (cpu_share>=0?cpu_share*100:0));
       else if (cand[bi]=="threadpool-starved") reason=sprintf("thread-pool queue peaked at %.0f work items waiting for a worker thread.", tpqpeak+0);
       else if (cand[bi]=="lock-bound") reason=sprintf("~%.1f Monitor lock contention(s) per request (%.0f/s peak).", lock_per_req, (has(lockrate)?lockrate+0:0));
       else if (cand[bi]=="gc-bound") reason=sprintf("the GC paused ~%.0f%% of wall-clock (peak); ~%.0f%% of a request is GC pause.", (gcpause+0)*100, (gc_share>=0?gc_share*100:0));
       else if (cand[bi]=="db-pool-saturated") reason=sprintf("%.0f request(s) peak waiting for a pooled DB connection (used %.0f/%.0f).", dbpending+0, (has(dbused)?dbused+0:0), (has(dbmax)?dbmax+0:0));
       else if (cand[bi]=="upstream-pool-saturated") reason=sprintf("a typical request waits ~%.0f ms for an upstream HTTP connection to %s (%.0f in flight against %.0f open connection(s)).", (upwait+0)*1000, (uppool==""?"the dependency":uppool), (has(upactive)?upactive+0:0), (has(upconns)?upconns+0:0));
       else if (cand[bi]=="dependency-bound-db") reason=sprintf("~%.0f%% of a typical request is spent in the database (pool not saturated -- it is DB execution time, not pool waiting).", db_share*100);
       else reason="";
       if (concurrent) reason=sprintf("Concurrent bottlenecks (%s). Primary -> ", primlist) reason;
       # Surface EVERY saturated resource (from the booleans) whenever >=2 are saturated --
       # including a secondary saturation next to a single primary, and the thread pool.
       if (nsatres>=2) reason=reason sprintf(" [%d resources saturated: %s]", nsatres, satreslist);
     }

     # ----- emit JSON -----
     printf "{";
     printf "\"kind\":\"bottleneck\",\"runId\":\"%s\",\"scenarioId\":\"%s\",\"captureStatus\":\"%s\",", runid, scen, status;
     printf "\"verdict\":\"%s\",\"confidence\":\"%s\",\"concurrent\":%s,\"contributors\":[%s],\"saturatedResources\":[%s],\"reason\":\"%s\",", verdict, conf, (concurrent?"true":"false"), contribjson, satresjson, reason;
     printf "\"resources\":{";
     printf "\"cpu\":{\"coresBusyPeak\":%s,\"cpuCount\":%s,\"utilizationPct\":%s,\"msPerRequest\":%s,\"latencySharePct\":%s,\"saturated\":%s},", jnum(cpubusy), (has(cpucount)?sprintf("%d",cpucount+0):"null"), jpct(cpu_util), jnum(effcpu), jpct(cpu_share), (cpu_sat?"true":"false");
     printf "\"threadPool\":{\"queuePeak\":%s,\"queueAvg\":%s,\"threadCountPeak\":%s,\"queueWaitSeconds\":%s,\"saturated\":%s},", jnum(tpqpeak), jnum(tpqavg), jnum(threadpeak), (tpq_wait>=0?sprintf("%.6f",tpq_wait):"null"), (tpq_sat?"true":"false");
     printf "\"upstreamPool\":{\"meanWaitSeconds\":%s,\"activeRequestsPeak\":%s,\"openConnectionsPeak\":%s,\"pool\":%s,\"latencySharePct\":%s,\"saturated\":%s},", jnum(upwait), jnum(upactive), jnum(upconns), (uppool==""?"null":"\"" uppool "\""), jpct(up_share), (up_sat?"true":"false");
     printf "\"retention\":{\"heapGrowthPct\":%s,\"source\":\"%s\",\"flagged\":%s},", (has(retaingrowth)?sprintf("%.1f",(retaingrowth+0)*100):"null"), (has(retaingrowth)?"analysis/runtime/diff-gcdump-before-after.txt":"not-captured"), (retain_sat?"true":"false");
     printf "\"gc\":{\"pauseFractionPeak\":%s,\"pauseMsPerRequest\":%s,\"allocBytesPerRequest\":%s,\"allocRatePeak\":%s,\"latencySharePct\":%s,\"saturated\":%s},", jnum(gcpause), jnum(effgc), jnum(effalloc), jnum(allocrate), jpct(gc_share), (gc_sat?"true":"false");
     printf "\"locks\":{\"contentionsPerSecPeak\":%s,\"contentionsPerRequest\":%s,\"saturated\":%s},", jnum(lockrate), (lock_per_req>=0?sprintf("%.3f",lock_per_req):"null"), (lock_sat?"true":"false");
     printf "\"dbPool\":{\"pendingPeak\":%s,\"usedPeak\":%s,\"max\":%s,\"utilizationPct\":%s,\"saturated\":%s},", jnum(dbpending), jnum(dbused), jnum(dbmax), jpct(dbpool_util), (dbp_sat?"true":"false");
     printf "\"dependencyDb\":{\"msPerRequest\":%s,\"latencySharePct\":%s,\"dominant\":%s},", jnum(effdb), jpct(db_share), (dep_dom?"true":"false");
     printf "\"otherLatencySharePct\":%s", jpct(other_share);
     printf "},";
     printf "\"workload\":{\"rps\":%s,\"p50Ms\":%s,\"p99Ms\":%s,\"errorRate\":%s,\"droppedIterations\":%s},", jnum(rps), jnum(p50), jnum(p99), jnum(errate), (has(dropped)?sprintf("%d",dropped+0):"null");
     printf "\"notes\":[";
     for(i=1;i<=nn;i++){ gsub(/"/,"\\\"",notes[i]); printf "%s\"%s\"", (i>1?",":""), notes[i] }
     printf "]}\n";
   }')"

[[ -n "${json}" ]] || { echo "bottleneck: computation produced no output." >&2; exit 3; }
printf '%s\n' "${json}" > "${out}"

# Human summary.
read -r verdict conf reason < <(jqd -r '[.verdict,.confidence,.reason]|@tsv' < "${out}" 2>/dev/null || echo "? ? ?")
echo "Bottleneck for ${scenario} (run ${run_id})"
echo "  verdict:    ${verdict}  (confidence: ${conf})"
echo "  reason:     ${reason}"
jqd -r '.resources | "  cpu util:   \(.cpu.utilizationPct // "n/a")%  (\(.cpu.latencySharePct // "n/a")% of a request on-CPU)\n  tp queue:   peak \(.threadPool.queuePeak // "n/a")\n  gc pause:   peak \(.gc.pauseFractionPeak // "n/a")  (\(.gc.latencySharePct // "n/a")% of a request)\n  locks:      \(.locks.contentionsPerRequest // "n/a") / request\n  db pool:    pending peak \(.dbPool.pendingPeak // "n/a"), used \(.dbPool.usedPeak // "n/a")/\(.dbPool.max // "n/a")\n  db time:    \(.dependencyDb.latencySharePct // "n/a")% of a request"' \
  < "${out}" 2>/dev/null || true
jqd -r '.notes[]? | "  note: " + .' < "${out}" 2>/dev/null || true
echo "  wrote ${out}"
