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

cpu_busy_peak="$(mstat_sum process_cpu max)"
cpu_count="$(mstat cpu_count last)"; [[ -z "${cpu_count}" ]] && cpu_count="$(mstat cpu_count max)"
tpq_peak="$(mstat thread_pool_queue max)"; tpq_avg="$(mstat thread_pool_queue avg)"
thread_peak="$(mstat thread_count max)"
gc_pause_peak="$(mstat gc_pause max)"
alloc_rate_peak="$(mstat gc_allocation_rate max)"
lock_rate_peak="$(mstat lock_contention max)"
db_used_peak=""; db_max=""; db_pending_peak=""
IFS=$'\t' read -r db_used_peak db_max db_pending_peak < <(dbpool_worst)

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
  -v CPU_SAT="${PERFLAB_USE_CPU_SAT:-0.85}" -v TPQ_SAT="${PERFLAB_USE_TPQ_SAT:-2}" \
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
     tpq_sat  = (has(tpqpeak) && tpqpeak+0>=TPQ_SAT);
     gc_sat   = (has(gcpause) && gcpause+0>=GC_SAT);
     lock_sat = (lock_per_req>=0 && lock_per_req>=LOCK_SAT);
     dbp_sat  = (has(dbpending) && dbpending+0>0);
     dep_dom  = (db_share>=0 && db_share>=DEP_SHARE);

     # ----- rank candidates. Saturation signals outweigh mere utilisation/shares;
     # among shares, the largest slice of the request wins. Score in [0,~2]. -----
     n=0;
     if (dbp_sat){ cand[++n]="db-pool-saturated"; sc[n]=1.5 + (has(dbpending)?dbpending+0:0)/100 }
     # A thread-pool queue is only its OWN bottleneck (sync-over-async / blocking
     # starvation, threads parked not busy) when CPU is NOT saturated. When CPU is also
     # saturated the queue is a SYMPTOM of CPU starvation, so cpu-bound must win -- do not
     # add a competing threadpool-starved candidate whose queue score would overpower it.
     if (tpq_sat && !cpu_sat){ cand[++n]="threadpool-starved"; sc[n]=1.3 + (tpqpeak+0)/100 }
     if (lock_sat){ cand[++n]="lock-bound"; sc[n]=1.2 + lock_per_req/10 }
     if (cpu_sat){ cand[++n]="cpu-bound"; sc[n]=1.0 + cpu_util }
     if (gc_sat){ cand[++n]="gc-bound"; sc[n]=1.0 + (gcpause+0) }
     if (dep_dom){ cand[++n]="dependency-bound-db"; sc[n]=0.5 + db_share }
     # utilisation-only fallbacks (no hard saturation, but a resource clearly dominates)
     if (n==0 && cpu_share>=0.5){ cand[++n]="cpu-bound"; sc[n]=0.4+cpu_share }
     if (n==0 && gc_share>=0.3){ cand[++n]="gc-bound"; sc[n]=0.4+gc_share }
     if (n==0 && cpu_util>=0.6){ cand[++n]="cpu-bound"; sc[n]=0.3+cpu_util }

     verdict="no-clear-bottleneck"; conf="low"; best=-1; bi=0;
     for(i=1;i<=n;i++){ if(sc[i]>best){best=sc[i]; bi=i} }
     if (bi>0) verdict=cand[bi];

     # any resource signal captured at all?
     any = (cpu_util>=0) || has(tpqpeak) || has(gcpause) || (lock_per_req>=0) || has(dbpending) || (db_share>=0);
     if (!any) verdict="insufficient-data";

     # ----- confidence -----
     if (verdict=="insufficient-data") conf="low";
     else if (dbp_sat || tpq_sat || (cpu_util>=0.9) || (gc_sat && gcpause+0>=0.2) || lock_sat) conf="high";
     else if (bi>0 && sc[bi]>=1.0) conf="high";
     else if (bi>0) conf="medium";
     else conf="low";
     if (status!="captured") conf="low";  # partial evidence never rates high

     # ----- notes -----
     nn=0;
     if (has(errate) && errate+0>0.01) notes[++nn]=sprintf("error_rate=%.3f -- the system is failing requests; the bottleneck reasoning is about an OVERLOADED system (see the gate).", errate+0);
     if (has(dropped) && dropped+0>0) notes[++nn]=sprintf("%d dropped iteration(s) -- offered load exceeded served throughput; capacity is already past the knee.", dropped+0);
     if (tpq_sat && cpu_sat) notes[++nn]="thread-pool queue AND CPU are both saturated -- the queue is most likely CPU starvation, not sync-over-async blocking.";
     if (tpq_sat && !cpu_sat) notes[++nn]="thread-pool queue is high while CPU is NOT saturated -- classic sync-over-async / blocking-call starvation (threads parked, not busy).";
     if (verdict=="dependency-bound-db" && dbp_sat) notes[++nn]="most request time is DB AND the pool is saturated -- the DB dependency is the bottleneck via pool exhaustion.";
     if (verdict=="no-clear-bottleneck" && any) notes[++nn]="no resource crossed a saturation gate -- the system has headroom at this load (push RPS with a capacity profile to find the knee).";

     # ----- reason line -----
     if (verdict=="cpu-bound") reason=sprintf("CPU utilisation peaked at %.0f%% of %s core(s); ~%.0f%% of a typical request is on-CPU.", (cpu_util>=0?cpu_util*100:0), (has(cpucount)?sprintf("%d",cpucount+0):"?"), (cpu_share>=0?cpu_share*100:0));
     else if (verdict=="threadpool-starved") reason=sprintf("thread-pool queue peaked at %.0f work items waiting for a worker thread.", tpqpeak+0);
     else if (verdict=="lock-bound") reason=sprintf("~%.1f Monitor lock contention(s) per request (%.0f/s peak).", lock_per_req, (has(lockrate)?lockrate+0:0));
     else if (verdict=="gc-bound") reason=sprintf("the GC paused ~%.0f%% of wall-clock (peak); ~%.0f%% of a request is GC pause.", (gcpause+0)*100, (gc_share>=0?gc_share*100:0));
     else if (verdict=="db-pool-saturated") reason=sprintf("%.0f request(s) peak waiting for a pooled DB connection (used %.0f/%.0f).", dbpending+0, (has(dbused)?dbused+0:0), (has(dbmax)?dbmax+0:0));
     else if (verdict=="dependency-bound-db") reason=sprintf("~%.0f%% of a typical request is spent in the database (pool not saturated -- it is DB execution time, not pool waiting).", db_share*100);
     else if (verdict=="insufficient-data") reason="no runtime resource signals were captured (black-box run, or metrics missing) -- cannot classify.";
     else reason="no resource crossed a saturation threshold at this load.";

     # ----- emit JSON -----
     printf "{";
     printf "\"kind\":\"bottleneck\",\"runId\":\"%s\",\"scenarioId\":\"%s\",\"captureStatus\":\"%s\",", runid, scen, status;
     printf "\"verdict\":\"%s\",\"confidence\":\"%s\",\"reason\":\"%s\",", verdict, conf, reason;
     printf "\"resources\":{";
     printf "\"cpu\":{\"coresBusyPeak\":%s,\"cpuCount\":%s,\"utilizationPct\":%s,\"msPerRequest\":%s,\"latencySharePct\":%s,\"saturated\":%s},", jnum(cpubusy), (has(cpucount)?sprintf("%d",cpucount+0):"null"), jpct(cpu_util), jnum(effcpu), jpct(cpu_share), (cpu_sat?"true":"false");
     printf "\"threadPool\":{\"queuePeak\":%s,\"queueAvg\":%s,\"threadCountPeak\":%s,\"saturated\":%s},", jnum(tpqpeak), jnum(tpqavg), jnum(threadpeak), (tpq_sat?"true":"false");
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
