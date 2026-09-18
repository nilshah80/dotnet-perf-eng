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
if [[ -s "${preload}" ]]; then
  read_fields 3 < <(
    jqd -r --arg work "${work_pattern}" --arg dead "${dead_pattern}" '
      [.[]? | select((.name // "") | test($dead) | not) | select((.name // "") | test($work))] as $w |
      [ ([$w[].message_stats.publish // 0] | add // 0),
        ([$w[].message_stats.ack // 0] | add // 0),
        ([$w[].message_stats.redeliver // 0] | add // 0) ] | .[] | tostring' < "${preload}" 2>/dev/null) \
    && { baseline_published="${TSV_FIELDS[0]}"; baseline_acked="${TSV_FIELDS[1]}"; baseline_redelivered="${TSV_FIELDS[2]}"; }
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
# Successful requests only. http.requests.total counts failures too, and a
# request that returned 500 was never accepted -- comparing it against publishes
# would invent a gap the system does not have.
accepted="$(jqd -r '
  ((.observations[]? | select(.name=="http.requests.total") | .value) // 0) as $total |
  ((.observations[]? | select(.name=="http.responses.non_2xx_3xx") | .value) // 0) as $status |
  ((.observations[]? | select(.name=="http.transport_errors") | .value) // 0) as $transport |
  ($total - $status - $transport) | if . < 0 then 0 else . end' < "${facts}" 2>/dev/null | head -1 || true)"

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
unaccounted="$(awk -v p="${published:-0}" -v a="${acknowledged:-0}" -v r="${backlog:-0}" \
  -v u="${unacked:-0}" -v d="${dead:-0}" 'BEGIN { printf "%d", p - (a + r + u + d) }')"

[[ "${backlog:-0}" -gt 0 ]] && add "${backlog} message(s) still queued at the end of the run: accepted by the API, never processed, and counted as success by the client"
[[ "${unacked:-0}" -gt 0 ]] && add "${unacked} message(s) unacknowledged: delivered to a consumer that never confirmed them"
[[ "${dead:-0}" -gt 0 ]] && add "${dead} message(s) dead-lettered: rejected or corrupt work the HTTP result cannot show"
[[ "${redelivered:-0}" -gt 0 ]] && add "${redelivered} redelivery(ies): the broker delivered work more than once. That is a delivery ATTEMPT, not proof a handler completed twice -- but a non-idempotent handler has been given the chance to."
if [[ "${unaccounted}" -gt 0 ]]; then
  add "${unaccounted} published message(s) are unaccounted for: not acknowledged, not queued, not in flight, not dead-lettered"
elif [[ "${unaccounted}" -lt 0 ]]; then
  add "the broker acknowledged more messages than it recorded publishing (${unaccounted} difference); the counters span more than this run window"
fi

# The HTTP count is reported beside the broker count, never in place of it: a
# gap between them is itself a finding -- requests that returned 202 without
# reaching the broker at all.
if [[ -n "${accepted:-}" && "${accepted}" != "null" ]]; then
  http_gap="$(awk -v h="${accepted}" -v p="${published:-0}" 'BEGIN { printf "%d", h - p }')"
  [[ "${http_gap}" -gt 0 ]] && add "${http_gap} request(s) succeeded over HTTP without a corresponding publish; they were accepted and never enqueued"
fi

printf '{"kind":"async-reconciliation","captureState":"captured","balanced":%s,"published":%s,"acknowledged":%s,"stillQueued":%s,"inFlight":%s,"deadLettered":%s,"duplicate":{"captureState":"captured","redeliveries":%s,"meaning":"redelivery attempts, not confirmed duplicate completions"},"unaccounted":%s,"httpSuccessful":%s,"scope":"%s","workQueues":%s,"deadLetterQueues":%s,"findings":[%s]}\n' \
  "${balanced}" "${published:-0}" "${acknowledged:-0}" "${backlog:-0}" "${unacked:-0}" "${dead:-0}" \
  "${redelivered:-0}" "${unaccounted}" "${accepted:-null}" "${scope_state}" \
  "${work_seen:-0}" "${dead_seen:-0}" "${findings}" > "${out}"

if [[ "${balanced}" == "false" ]]; then
  echo "async-reconciliation: accepted work did not fully complete." >&2
  jqd -r '.findings[]' < "${out}" 2>/dev/null | sed 's/^/  - /' >&2 || true
fi
echo "wrote ${out}"
