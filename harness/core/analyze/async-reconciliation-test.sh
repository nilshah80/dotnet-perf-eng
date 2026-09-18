#!/usr/bin/env bash
# Acceptance case 16: accepted work is reconciled against completed work.
#
# An async endpoint returns 202 as soon as it has enqueued, so the client counts
# a success for work that may never happen. A run can look perfect at the load
# generator while the broker holds an undrained backlog or a dead-letter queue
# full of rejects -- neither of which any HTTP metric can show.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "async-reconciliation-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"
command -v docker >/dev/null || fail "docker is required for the jq shim"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/async-recon-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT HUP INT TERM
mkdir -p "${test_root}/bin"
cat > "${test_root}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "run" ]] || exit 0
shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in --rm|--interactive|-i|-t|--tty) shift ;; *) break ;; esac
done
shift
exec $(command -v jq) "\$@"
EOF
chmod +x "${test_root}/bin/docker"

build() { # build <name> <queues-json> [preload-json]
  local dir="${test_root}/$1"
  mkdir -p "${dir}/dependencies"
  # 5000 requests of which 0 failed, so accepted == 5000 successful.
  printf '{"observations":[{"name":"http.requests.total","value":5000},{"name":"http.responses.non_2xx_3xx","value":0},{"name":"http.transport_errors","value":0}]}\n' > "${dir}/facts.json"
  printf '%s\n' "$2" > "${dir}/dependencies/rabbitmq-queues.json"
  # A zeroed baseline by default: the counters then describe this run alone.
  printf '%s\n' "${3:-[{\"name\":\"perf.orders.created\",\"message_stats\":{\"publish\":0,\"ack\":0,\"redeliver\":0}}]}" \
    > "${dir}/dependencies/rabbitmq-queues-preload.json"
  printf '%s' "${dir}"
}
reconcile() {
  PATH="${test_root}/bin:${PATH}" PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh" \
    bash "${repo}/harness/core/analyze/async-reconciliation.sh" "$1" > "$1/out.txt" 2>&1 || true
  printf '%s' "$1/analysis/async-reconciliation.json"
}

# A run where every published message was acknowledged balances.
drained='[{"name":"perf.orders.created","messages":0,"messages_ready":0,"messages_unacknowledged":0,"message_stats":{"publish":5000,"ack":5000,"redeliver":0}},{"name":"perf.orders.dead","messages":0,"messages_ready":0}]'
report="$(reconcile "$(build drained "${drained}")")"
jq -e '.balanced == true and .published == 5000 and .acknowledged == 5000 and .unaccounted == 0
       and (.findings | length) == 0' "${report}" >/dev/null \
  || fail "a fully reconciled broker was reported as unbalanced: $(jq -c '{balanced,published,acknowledged,findings}' "${report}")"

# --- a completed count is REQUIRED, not inferred from an empty queue --------
# An empty queue is equally consistent with work that was never enqueued, so a
# broker with no counters must refuse to judge rather than report success.
empty='[{"name":"perf.orders.created","messages":0,"messages_ready":0,"messages_unacknowledged":0},{"name":"perf.orders.dead","messages":0}]'
report="$(reconcile "$(build empty "${empty}")")"
jq -e '.captureState == "not-captured" and .balanced == null' "${report}" >/dev/null \
  || fail "an empty queue with no broker counters was judged as balanced: $(jq -c '{captureState,balanced}' "${report}")"

# --- an undrained backlog is accepted work that never happened ---------------
backlog='[{"name":"perf.orders.created","messages":1200,"messages_ready":1200,"messages_unacknowledged":0,"message_stats":{"publish":5000,"ack":3800,"redeliver":0}},{"name":"perf.orders.dead","messages":0,"messages_ready":0}]'
report="$(reconcile "$(build backlog "${backlog}")")"
jq -e '.balanced == false and .stillQueued == 1200 and .acknowledged == 3800 and .unaccounted == 0
       and (.findings | join(" ") | test("never processed"))' "${report}" >/dev/null \
  || fail "1200 queued messages were not reconciled: $(jq -c '{balanced,stillQueued,acknowledged,unaccounted}' "${report}")"

# --- dead-lettered work is corrupt/rejected, invisible to HTTP ---------------
dead='[{"name":"perf.orders.created","messages":0,"messages_ready":0,"messages_unacknowledged":0,"message_stats":{"publish":5000,"ack":4963,"redeliver":0}},{"name":"perf.orders.dead","messages":37,"messages_ready":37}]'
report="$(reconcile "$(build dead "${dead}")")"
jq -e '.balanced == false and .deadLettered == 37 and .unaccounted == 0
       and (.findings | join(" ") | test("dead-lettered"))' "${report}" >/dev/null \
  || fail "37 dead-lettered messages were not reconciled"

# --- unacknowledged work was delivered and never confirmed -------------------
unacked='[{"name":"perf.orders.created","messages":9,"messages_ready":0,"messages_unacknowledged":9,"message_stats":{"publish":5000,"ack":4991,"redeliver":0}},{"name":"perf.orders.dead","messages":0}]'
report="$(reconcile "$(build unacked "${unacked}")")"
jq -e '.balanced == false and .inFlight == 9 and (.findings | join(" ") | test("never confirmed"))' "${report}" >/dev/null \
  || fail "9 unacknowledged messages were not reported"

# --- duplicates ARE measured: redelivery means a handler ran twice -----------
duplicated='[{"name":"perf.orders.created","messages":0,"messages_ready":0,"messages_unacknowledged":0,"message_stats":{"publish":5000,"ack":5000,"redeliver":84}},{"name":"perf.orders.dead","messages":0}]'
report="$(reconcile "$(build duplicated "${duplicated}")")"
jq -e '.duplicate.captureState == "captured" and .duplicate.redeliveries == 84
       and .balanced == false and (.findings | join(" ") | test("more than once"))' "${report}" >/dev/null \
  || fail "84 redeliveries were not reported as duplicate work: $(jq -c .duplicate "${report}")"

# --- published work that cannot be placed is the core of the reconciliation --
lost='[{"name":"perf.orders.created","messages":0,"messages_ready":0,"messages_unacknowledged":0,"message_stats":{"publish":5000,"ack":4000,"redeliver":0}},{"name":"perf.orders.dead","messages":0}]'
report="$(reconcile "$(build lost "${lost}")")"
jq -e '.balanced == false and .unaccounted == 1000 and (.findings | join(" ") | test("unaccounted for"))' "${report}" >/dev/null \
  || fail "1000 published-but-unplaced messages were not detected: $(jq -c '{unaccounted,findings}' "${report}")"

# --- HTTP successes that never reached the broker ---------------------------
# 5000 HTTP requests succeeded but only 4000 were published: a thousand callers
# were told their work was accepted when it was never enqueued.
never='[{"name":"perf.orders.created","messages":0,"messages_ready":0,"messages_unacknowledged":0,"message_stats":{"publish":4000,"ack":4000,"redeliver":0}},{"name":"perf.orders.dead","messages":0}]'
report="$(reconcile "$(build never "${never}")")"
jq -e '.balanced == false and (.findings | join(" ") | test("never enqueued"))' "${report}" >/dev/null \
  || fail "HTTP successes with no corresponding publish were not detected: $(jq -c .findings "${report}")"

# --- a non-broker scenario is not-applicable, not balanced -------------------
plain="${test_root}/plain"
mkdir -p "${plain}"
printf '{"observations":[]}\n' > "${plain}/facts.json"
report="$(reconcile "${plain}")"
jq -e '.captureState == "not-applicable" and .balanced == null' "${report}" >/dev/null \
  || fail "a scenario with no broker was reported as balanced; absence was read as health"

# --- broker evidence with no matching work queue cannot reconcile ------------
unmatched='[{"name":"some.other.queue","messages":5,"messages_ready":5}]'
report="$(reconcile "$(build unmatched "${unmatched}")")"
jq -e '.captureState == "missing" and .balanced == null' "${report}" >/dev/null \
  || fail "a broker whose queues do not match the work pattern was judged rather than reported as unjudgeable"

# --- the reconciliation is scoped to THIS run ------------------------------
# RabbitMQ message_stats are cumulative for the broker's lifetime and purging a
# queue does not reset them. Without a baseline, a later run balances using work
# from earlier ones and reports itself complete.
carried='[{"name":"perf.orders.created","messages":0,"messages_ready":0,"messages_unacknowledged":0,"message_stats":{"publish":9000,"ack":8000,"redeliver":0}},{"name":"perf.orders.dead","messages":0}]'
earlier='[{"name":"perf.orders.created","message_stats":{"publish":4000,"ack":4000,"redeliver":0}}]'
report="$(reconcile "$(build carried "${carried}" "${earlier}")")"
jq -e '.published == 5000 and .acknowledged == 4000 and .unaccounted == 1000' "${report}" >/dev/null \
  || fail "the baseline was not subtracted; earlier runs are being counted: $(jq -c '{published,acknowledged,unaccounted}' "${report}")"

# Without a baseline the analyzer must SAY it cannot scope the numbers rather
# than present cumulative counters as this run's.
unscoped_dir="$(build unscoped "${carried}")"
rm -f "${unscoped_dir}/dependencies/rabbitmq-queues-preload.json"
report="$(reconcile "${unscoped_dir}")"
jq -e '.scope == "unscoped"' "${report}" >/dev/null \
  || fail "a reconciliation with no baseline did not declare itself unscoped"

# --- accepted means SUCCESSFUL requests -------------------------------------
# http.requests.total counts failures too; a request that returned 500 was never
# accepted, and counting it would invent a gap the system does not have.
failing="$(build failing "${drained}")"
printf '{"observations":[{"name":"http.requests.total","value":5000},{"name":"http.responses.non_2xx_3xx","value":1000},{"name":"http.transport_errors","value":0}]}\n' \
  > "${failing}/facts.json"
report="$(reconcile "${failing}")"
jq -e '.httpSuccessful == 4000' "${report}" >/dev/null \
  || fail "failed HTTP requests were counted as accepted: httpSuccessful=$(jq -r .httpSuccessful "${report}")"
jq -e '(.findings | join(" ") | test("never enqueued")) | not' "${report}" >/dev/null \
  || fail "a gap was invented from requests that failed rather than being enqueued"

# --- redelivery is an ATTEMPT, not a confirmed duplicate completion ----------
jq -e '.duplicate.meaning | test("not confirmed duplicate completions")' \
  "$(reconcile "$(build dupmeaning "${duplicated}")")" >/dev/null \
  || fail "redeliveries are presented as confirmed duplicate completions, which the counter does not show"

# --- the baseline must be taken AFTER warm-up -------------------------------
# message_stats are cumulative for the broker's lifetime. Where the baseline is
# taken decides which traffic the reconciliation describes: taken before
# warm-up, it counts warm-up publishes as measured work while the HTTP side
# counts the measure phase alone, and the two halves of the balance describe
# different windows.
reset_script="${repo}/harness/adapters/dependency/rabbitmq/reset.sh"
stats_script="${repo}/harness/adapters/dependency/rabbitmq/reset-stats.sh"
[[ -x "${stats_script}" ]] \
  || fail "rabbitmq has no reset-stats hook, so the baseline cannot be taken after warm-up"
grep -q 'rabbitmq-queues-preload.json' "${stats_script}" \
  || fail "the post-warm-up hook does not baseline the queue counters"
grep -q 'rabbitmq-queues-preload.json' "${reset_script}" \
  && fail "the pre-warm-up reset still baselines the counters; warm-up traffic would count as measured work"

# And the harness must actually run reset-stats after warm-up, not before.
run_scenario_script="${repo}/harness/core/run/run-scenario.sh"
warmup_line="$(grep -n 'loadgen_warmup' "${run_scenario_script}" | head -1 | cut -d: -f1)"
stats_line="$(grep -n 'reset-stats.sh' "${run_scenario_script}" | head -1 | cut -d: -f1)"
[[ -n "${warmup_line}" && -n "${stats_line}" ]] \
  || fail "could not locate the warm-up and reset-stats steps in run-scenario.sh"
[[ "${stats_line}" -gt "${warmup_line}" ]] \
  || fail "reset-stats runs at line ${stats_line}, before warm-up at line ${warmup_line}"

echo "async reconciliation tests passed"
