#!/usr/bin/env bash
# Reconcile accepted work against completed work for broker-backed scenarios.
#
# Acceptance case 16. An async endpoint returns 202 as soon as it has enqueued,
# so HTTP metrics report success for work that was never done. A run can look
# perfect at the client while the broker holds a backlog it never drained or a
# dead-letter queue full of rejects -- the load generator cannot see either.
#
# The reconciliation balances one equation from the broker's own counters:
#
#   published = acknowledged + still-queued + in-flight + dead-lettered
#
# Anything left over is work the broker accepted and cannot account for. Each
# term comes from evidence rather than inference:
#   published     message_stats.publish   -- what the API actually enqueued
#   acknowledged  message_stats.ack       -- what a consumer finished
#   still-queued  messages_ready          -- accepted, never started
#   in-flight     messages_unacknowledged -- started, never confirmed
#   dead-lettered dead-letter queue depth -- rejected or corrupt
#   duplicate     message_stats.redeliver -- delivered more than once
#
# An earlier version counted HTTP requests as "accepted" and inferred success
# from an empty queue. That is not a reconciliation: it produced no completed
# count at all, and an empty queue is equally consistent with work that was
# never enqueued.
#
#   async-reconciliation.sh <run-dir>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"

run_arg="${1:?async-reconciliation.sh <run-dir>}"
[[ -d "${run_arg}" ]] || { echo "async-reconciliation: '${run_arg}' is not a run directory." >&2; exit 2; }
queues="${run_arg}/dependencies/rabbitmq-queues.json"
facts="${run_arg}/facts.json"
mkdir -p "${run_arg}/analysis"
out="${run_arg}/analysis/async-reconciliation.json"

if [[ ! -s "${queues}" ]]; then
  printf '{"kind":"async-reconciliation","captureState":"not-applicable","reason":"no broker evidence in this package; the scenario is not broker-backed","balanced":null}\n' > "${out}"
  echo "wrote ${out} (not broker-backed)"
  exit 0
fi

# Dead-letter naming is a convention, not a protocol: match the queues this lab
# declares rather than guessing, and say so when nothing matches.
dead_pattern="${PERFLAB_ASYNC_DEAD_QUEUE_PATTERN:-dead|dlq|error}"
work_pattern="${PERFLAB_ASYNC_WORK_QUEUE_PATTERN:-created|orders|work}"

# Cumulative counters, scoped to this run. RabbitMQ's message_stats are for the
# broker's lifetime and purging a queue does not reset them, so the raw values
# include every earlier run -- a later run balances using somebody else's work.
# The reset baseline is subtracted; without it, the reconciliation says so
# rather than reporting a number it cannot scope.
preload="$(dirname "${queues}")/rabbitmq-queues-preload.json"
baseline_published=0; baseline_acked=0; baseline_redelivered=0; scope_state="run-scoped"
# Depths at the baseline too: the counters are subtracted, so the depths must be
# as well, or messages queued or dead-lettered during warm-up are charged to the
# measured run (S17 starts its window with a full queue and a populated DLQ).
baseline_ready=0; baseline_unacked=0; baseline_dead=0
if [[ -s "${preload}" ]]; then
  read_fields 6 < <(
    jqd -r --arg work "${work_pattern}" --arg dead "${dead_pattern}" '
      [.[]? | select((.name // "") | test($dead) | not) | select((.name // "") | test($work))] as $w |
      [.[]? | select((.name // "") | test($dead))] as $d |
      [ ([$w[].message_stats.publish // 0] | add // 0),
        ([$w[].message_stats.ack // 0] | add // 0),
        ([$w[].message_stats.redeliver // 0] | add // 0),
        ([$w[].messages_ready // 0] | add // 0),
        ([$w[].messages_unacknowledged // 0] | add // 0),
        ([$d[].messages // 0] | add // 0) ] | .[] | tostring' < "${preload}" 2>/dev/null) \
    && { baseline_published="${TSV_FIELDS[0]}"; baseline_acked="${TSV_FIELDS[1]}"; baseline_redelivered="${TSV_FIELDS[2]}"
         baseline_ready="${TSV_FIELDS[3]}"; baseline_unacked="${TSV_FIELDS[4]}"; baseline_dead="${TSV_FIELDS[5]}"; }
else
  scope_state="unscoped"
fi

read_fields 8 < <(
  jqd -r --arg dead "${dead_pattern}" --arg work "${work_pattern}" '
    [.[]? | select((.name // "") | test($dead) | not) | select((.name // "") | test($work))] as $w |
    [.[]? | select((.name // "") | test($dead))] as $d |
    [ ([$w[].message_stats.publish // 0] | add // 0),
      ([$w[].message_stats.ack // 0] | add // 0),
      ([$w[].message_stats.redeliver // 0] | add // 0),
      ([$w[].messages_ready // 0] | add // 0),
      ([$w[].messages_unacknowledged // 0] | add // 0),
      ([$d[].messages // 0] | add // 0),
      ($w | length), ($d | length) ] | .[] | tostring' < "${queues}" 2>/dev/null) || {
  printf '{"kind":"async-reconciliation","captureState":"missing","reason":"broker queue evidence could not be parsed","balanced":null}\n' > "${out}"
  echo "async-reconciliation: broker evidence unreadable." >&2
  exit 0
}
published=$(( TSV_FIELDS[0] - baseline_published ))
acknowledged=$(( TSV_FIELDS[1] - baseline_acked ))
redelivered=$(( TSV_FIELDS[2] - baseline_redelivered ))
(( published < 0 )) && published=0
(( acknowledged < 0 )) && acknowledged=0
(( redelivered < 0 )) && redelivered=0
backlog="${TSV_FIELDS[3]}"; unacked="${TSV_FIELDS[4]}"; dead="${TSV_FIELDS[5]}"
work_seen="${TSV_FIELDS[6]}"; dead_seen="${TSV_FIELDS[7]}"
# The balance uses the change in each depth across the run; the end depths are
# still reported, because they are the state the next operator inherits.
ready_delta=$(( backlog - baseline_ready ))
unacked_delta=$(( unacked - baseline_unacked ))
dead_delta=$(( dead - baseline_dead ))
# Management counters are emitted every collect_statistics_interval (5 s by
# default), so a snapshot can trail the traffic by up to one interval. A
# difference within that much of the run's publish rate is sampling lag, not loss.
stats_lag=0
if [[ -s "${run_arg}/manifest.json" ]]; then
  window="$(jqd -r '((.measurementEndedEpoch // 0) - (.measurementStartedEpoch // 0))' < "${run_arg}/manifest.json" 2>/dev/null | head -1 || true)"
  [[ "${window:-0}" =~ ^[0-9]+$ && "${window}" -gt 0 ]] && stats_lag=$(( (published * 5 + window - 1) / window ))
fi
# Successful requests only. http.requests.total counts failures too, and a
# request that returned 500 was never accepted -- comparing it against publishes
# would invent a gap the system does not have.
accepted="$(jqd -r '
  ((.observations[]? | select(.name=="http.requests.total") | .value) // 0) as $total |
  ((.observations[]? | select(.name=="http.responses.non_2xx_3xx") | .value) // 0) as $status |
  ((.observations[]? | select(.name=="http.transport_errors") | .value) // 0) as $transport |
  ($total - $status - $transport) | if . < 0 then 0 else . end' < "${facts}" 2>/dev/null | head -1 || true)"
# Only a single-request workload publishes once per success. A weighted mix
# counts every member, so ScenarioLab's mixed-runtime (10% POST /api/orders)
# reported 176,207 reads as requests "accepted and never enqueued".
http_comparison="compared"
workload_method="$(jqd -r '.workload.method // empty' < "${run_arg}/manifest.json" 2>/dev/null | head -1 || true)"
case "${workload_method}" in
  ""|GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) ;;
  *) http_comparison="not-applicable: ${workload_method} workload; its HTTP successes include operations that do not publish" ;;
esac

findings=""
balanced=true
add() { findings="${findings}${findings:+,}$(printf '"%s"' "$(json_escape "$1")")"; balanced=false; }

if [[ "${work_seen:-0}" == "0" ]]; then
  printf '{"kind":"async-reconciliation","captureState":"missing","reason":"broker evidence exists but no queue matched the work-queue pattern; the reconciliation cannot be performed","balanced":null}\n' > "${out}"
  echo "async-reconciliation: no work queue matched; cannot reconcile." >&2
  exit 0
fi

findings=""
balanced=true
add() { findings="${findings}${findings:+,}$(printf '"%s"' "$(json_escape "$1")")"; balanced=false; }

# A broker restart inside the window starts message_stats from zero, so the
# post-warm-up baseline no longer applies and "published" would count only the
# traffic since the restart -- inventing a gap of accepted-but-never-enqueued
# work. Evidence of a restart: this run's own stop/kill fault on the broker, or
# a node whose uptime is shorter than the time since the baseline was taken.
restart_reason=""
fault_proof="${run_arg}/benchmark/fault-proof.json"
if [[ -s "${fault_proof}" ]]; then
  restart_reason="$(jqd -r --arg svc "${rabbit_service:-rabbitmq}" '
    select(.service == $svc and .applied == true and (.action == "stop" or .action == "kill")) |
    "the \(.action) fault in this run restarted \(.service) at \(.appliedAt)"' < "${fault_proof}" 2>/dev/null | head -1 || true)"
fi
nodes_before="$(dirname "${queues}")/rabbitmq-nodes-preload.json"
nodes_after="$(dirname "${queues}")/rabbitmq-nodes.json"
if [[ -z "${restart_reason}" && -s "${nodes_before}" && -s "${nodes_after}" ]]; then
  restart_reason="$(cat "${nodes_before}" "${nodes_after}" | jqd -rs '
    (.[1].capturedAtEpoch - .[0].capturedAtEpoch) as $elapsed | .[0].nodes as $before |
    [ .[1].nodes[] as $n | select(any($before[]; .name == $n.name)) |
      select((($n.uptime // 0) / 1000) < ($elapsed - 5)) | $n.name ] |
    if length > 0 then "broker node \(join(", ")) has less uptime than the \($elapsed)s since the baseline, so it restarted" else empty end' 2>/dev/null | head -1 || true)"
fi
if [[ -n "${restart_reason}" ]]; then
  # Current depths stay true after a restart: a dead-letter queue still holding
  # messages is loss the client never saw. Only the cumulative balance is void.
  [[ "${backlog:-0}" -gt 0 ]] && add "${backlog} message(s) still queued at the end of the run"
  [[ "${unacked:-0}" -gt 0 ]] && add "${unacked} message(s) unacknowledged at the end of the run"
  [[ "${dead:-0}" -gt 0 ]] && add "${dead} message(s) in the dead-letter queue at the end of the run: accepted work the HTTP result cannot show"
  printf '{"kind":"async-reconciliation","captureState":"not-captured","reason":"%s; message_stats restarted from zero, so publish/ack cannot be scoped to this run and no balance is computed","balanced":null,"stillQueued":%s,"inFlight":%s,"deadLettered":%s,"httpSuccessful":%s,"scope":"broker-restarted","workQueues":%s,"deadLetterQueues":%s,"findings":[%s]}\n' \
    "$(json_escape "${restart_reason}")" "${backlog:-0}" "${unacked:-0}" "${dead:-0}" "${accepted:-null}" \
    "${work_seen:-0}" "${dead_seen:-0}" "${findings}" > "${out}"
  echo "async-reconciliation: ${restart_reason}; balance not computed." >&2
  echo "wrote ${out}"
  exit 0
fi

# The broker only reports message_stats once it has seen traffic. Without them
# there is no completed count, and saying "balanced" would be a claim about a
# measurement nobody took.
accounting_state="captured"
if [[ "${published:-0}" == "0" && "${acknowledged:-0}" == "0" && "${backlog:-0}" == "0" && "${unacked:-0}" == "0" ]]; then
  accounting_state="not-captured"
  printf '{"kind":"async-reconciliation","captureState":"%s","reason":"the broker reported no publish/ack counters for the work queue; accepted-versus-completed cannot be reconciled from this package","balanced":null,"workQueues":%s}\n' \
    "${accounting_state}" "${work_seen}" > "${out}"
  echo "async-reconciliation: no broker counters; cannot reconcile." >&2
  exit 0
fi

# The balance itself. Anything published and not accounted for is work the
# broker took and cannot place.
unaccounted="$(awk -v p="${published:-0}" -v a="${acknowledged:-0}" -v r="${ready_delta:-0}" \
  -v u="${unacked_delta:-0}" -v d="${dead_delta:-0}" 'BEGIN { printf "%d", p - (a + r + u + d) }')"

inherited() { if [[ "$1" -gt 0 ]]; then printf ' (%s already there when the measured window began)' "$1"; fi; }
[[ "${backlog:-0}" -gt 0 ]] && add "${backlog} message(s) still queued at the end of the run: accepted by the API, never processed, and counted as success by the client$(inherited "${baseline_ready}")"
[[ "${unacked:-0}" -gt 0 ]] && add "${unacked} message(s) unacknowledged: delivered to a consumer that never confirmed them$(inherited "${baseline_unacked}")"
if [[ "${dead:-0}" -gt 0 && "${baseline_dead}" -gt 0 ]]; then
  add "${dead_delta} message(s) dead-lettered during the run (${dead} in the dead-letter queue, ${baseline_dead} of them from before the measured window): rejected or corrupt work the HTTP result cannot show"
elif [[ "${dead:-0}" -gt 0 ]]; then
  add "${dead} message(s) dead-lettered: rejected or corrupt work the HTTP result cannot show"
fi
[[ "${redelivered:-0}" -gt 0 ]] && add "${redelivered} redelivery(ies): the broker delivered work more than once. That is a delivery ATTEMPT, not proof a handler completed twice -- but a non-idempotent handler has been given the chance to."
if [[ "${unaccounted}" -gt "${stats_lag}" ]]; then
  add "${unaccounted} published message(s) are unaccounted for: not acknowledged, not queued, not in flight, not dead-lettered"
elif [[ "${unaccounted}" -lt $(( -stats_lag )) ]]; then
  add "the broker acknowledged more messages than it recorded publishing (${unaccounted} difference); the counters span more than this run window"
fi

# The HTTP count is reported beside the broker count, never in place of it: a
# gap between them is itself a finding -- requests that returned 202 without
# reaching the broker at all.
if [[ "${http_comparison}" == "compared" && -n "${accepted:-}" && "${accepted}" != "null" ]]; then
  http_gap="$(awk -v h="${accepted}" -v p="${published:-0}" 'BEGIN { printf "%d", h - p }')"
  [[ "${http_gap}" -gt "${stats_lag}" ]] && add "${http_gap} request(s) succeeded over HTTP without a corresponding publish; they were accepted and never enqueued"
fi

printf '{"kind":"async-reconciliation","captureState":"captured","balanced":%s,"published":%s,"acknowledged":%s,"stillQueued":%s,"inFlight":%s,"deadLettered":%s,"deadLetteredDuringRun":%s,"baseline":{"stillQueued":%s,"inFlight":%s,"deadLettered":%s},"statsLagTolerance":%s,"duplicate":{"captureState":"captured","redeliveries":%s,"meaning":"redelivery attempts, not confirmed duplicate completions"},"unaccounted":%s,"httpSuccessful":%s,"httpComparison":"%s","scope":"%s","workQueues":%s,"deadLetterQueues":%s,"findings":[%s]}\n' \
  "${balanced}" "${published:-0}" "${acknowledged:-0}" "${backlog:-0}" "${unacked:-0}" "${dead:-0}" "${dead_delta:-0}" \
  "${baseline_ready}" "${baseline_unacked}" "${baseline_dead}" "${stats_lag}" \
  "${redelivered:-0}" "${unaccounted}" "${accepted:-null}" "$(json_escape "${http_comparison}")" "${scope_state}" \
  "${work_seen:-0}" "${dead_seen:-0}" "${findings}" > "${out}"

if [[ "${balanced}" == "false" ]]; then
  echo "async-reconciliation: accepted work did not fully complete." >&2
  jqd -r '.findings[]' < "${out}" 2>/dev/null | sed 's/^/  - /' >&2 || true
fi
echo "wrote ${out}"
