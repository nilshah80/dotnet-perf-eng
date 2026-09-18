#!/usr/bin/env bash
# Lifecycle integration tests for run-scenario.sh.
#
# Two properties that only an end-to-end drive can establish, because both are
# about what the orchestrator DOES NOT do:
#
#   Acceptance case 17 -- an existing local process is measured without being
#   deployed, reset or terminated. A preflight unit test cannot prove this: it
#   checks the guard in isolation, while the property is that run-scenario.sh
#   never reaches `compose up` or a dependency reset at all.
#
#   C-6 interruption recovery -- the dataset-preparation marker must survive
#   everything between the reset and the measurement. It used to be cleared
#   right after the resets, so a run interrupted during partition preparation
#   or warm-up left no trace and the next run measured a half-prepared dataset.
#
# The harness tree is COPIED and only its adapters are stubbed, so the code
# under test is the shipping run-scenario.sh rather than a reimplementation.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/run-scenario-lifecycle-test.XXXXXX")"
trap '[[ "${PERFLAB_TEST_KEEP:-0}" == "1" ]] && echo "fixture kept at ${test_root}" >&2 || rm -rf "${test_root}"' EXIT HUP INT TERM
fail() { echo "run-scenario-lifecycle-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

# The descriptor resolves catalogs and compose files relative to the repo root,
# which is derived from the harness location -- so the labs travel with it.
cp -R "${repo}/harness" "${test_root}/harness"
cp -R "${repo}/labs" "${test_root}/labs"
mkdir -p "${test_root}/bin" "${test_root}/artifacts"
calls="${test_root}/calls.log"
: > "${calls}"

# --- stub adapters: record what was invoked, do nothing else ----------------
cat > "${test_root}/harness/adapters/loadgen/k6/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'loadgen:%s\n' "${2:-unknown}" >> "${PERFLAB_TEST_CALLS}"
mkdir -p "$1/benchmark"
printf '{"observations":[{"name":"http.requests_per_second","value":100,"unit":"rps"}]}\n' > "$1/benchmark/observations.json"
printf '{}\n' > "$1/benchmark/k6-summary.json"
# Simulate a crash DURING warm-up: the dataset is prepared but the run never
# reaches measurement, which is exactly the window the marker must cover.
if [[ "${2:-}" == "warmup" && "${PERFLAB_TEST_SLOW_WARMUP:-0}" == "1" ]]; then
  sleep 30
fi
if [[ "${2:-}" == "warmup" && "${PERFLAB_TEST_FAIL_WARMUP:-0}" == "1" ]]; then
  echo "simulated warm-up interruption" >&2
  exit 1
fi
EOF
chmod +x "${test_root}/harness/adapters/loadgen/k6/run.sh"

# The managed-reference helper talks to a live API. Stubbed so the fixture can
# reach the cancellation path; the ordering it exercises is the real one.
cat > "${test_root}/harness/core/datafault/managed-reference.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'partition:%s\n' "${3:-create}" >> "${PERFLAB_TEST_CALLS}"
EOF
chmod +x "${test_root}/harness/core/datafault/managed-reference.sh"

for dep in postgres redis rabbitmq; do
  for hook in reset reset-stats snapshot fingerprint; do
    script="${test_root}/harness/adapters/dependency/${dep}/${hook}.sh"
    [[ -d "$(dirname "${script}")" ]] || continue
    if [[ "${hook}" == "fingerprint" ]]; then
      # Describe state that VARIES with the seed scale, as a real dependency
      # does: a fingerprint that ignores the data would hash the same for every
      # dataset and prove nothing.
      cat > "${script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'dependency:${dep}:fingerprint\n' >> "\${PERFLAB_TEST_CALLS}"
case "\${SEED_SCALE:-default}" in
  large) printf 'orders:100000\nusers:5000\n' ;;
  smoke) printf 'orders:100\nusers:10\n' ;;
  *)     printf 'orders:1000\nusers:100\n' ;;
esac
EOF
    else
      cat > "${script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'dependency:${dep}:${hook}\n' >> "\${PERFLAB_TEST_CALLS}"
EOF
    fi
    chmod +x "${script}"
  done
done

# docker/compose: record every lifecycle verb instead of running it.
cat > "${test_root}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "compose" ]]; then
  shift
  verb=""
  for arg in "\$@"; do
    case "\${arg}" in up|down|stop|start|restart|rm|ps|exec|run) verb="\${arg}"; break ;; esac
  done
  printf 'compose:%s\n' "\${verb:-other}" >> "\${PERFLAB_TEST_CALLS}"
  [[ "\${verb}" == "ps" ]] && printf '[]\n'
  exit 0
fi
# jqd() runs jq in a container; run the local binary instead.
if [[ "\${1:-}" == "run" ]]; then
  shift
  while [[ \$# -gt 0 ]]; do
    case "\$1" in --rm|--interactive|-i|-t|--tty) shift ;; *) break ;; esac
  done
  shift
  exec $(command -v jq) "\$@"
fi
exit 0
EOF
chmod +x "${test_root}/bin/docker"

# curl: the target is always reachable; every backend query returns empty.
cat > "${test_root}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "${url}" in
  *health*|*ready*) printf 'OK' ;;
  *) printf '{"status":"success","data":{"result":[]}}' ;;
esac
EOF
chmod +x "${test_root}/bin/curl"
cat > "${test_root}/bin/k6" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${test_root}/bin/k6"

# Derive the lab from the real descriptor so the fixture tracks it, redirecting
# only the artifacts root.
lab_config="${test_root}/lab.config.sh"
cp "${test_root}/labs/scenariolab/lab.config.sh" "${lab_config}"
printf '\nPERFLAB_ARTIFACTS_ROOT="%s"\n' "${test_root}/artifacts" >> "${lab_config}"

# calls_contain <pattern> -- read the ledger safely. A missing ledger is a test
# defect, and must not be reported as the product failing to do something.
calls_contain() {
  [[ -f "${calls}" ]] || fail "the call ledger is missing; the test cannot observe what the harness did"
  grep -q "$1" "${calls}"
}

run_scenario() { # run_scenario <name> [env assignments...]
  local name="$1"; shift
  : > "${calls}"
  set +e
  env "$@" \
    PATH="${test_root}/bin:${PATH}" \
    PERFLAB_CONFIG="${lab_config}" \
    PERFLAB_TEST_CALLS="${calls}" \
    PERFLAB_ARTIFACTS_ROOT="${test_root}/artifacts" \
    PERFLAB_WARMUP_SECONDS=0 \
    bash "${test_root}/harness/core/run/run-scenario.sh" S01 1 > "${test_root}/${name}.out" 2>&1
  local rc=$?
  set -e
  return "${rc}"
}

# --- acceptance case 17 ------------------------------------------------------
# An existing local process is measured without deployment or termination.
run_scenario case17 PERFLAB_TARGET_KIND=existing-process || true

calls_contain 'compose:up' \
  && fail "attach-only target was deployed: run-scenario.sh called compose up"
calls_contain 'compose:(down|stop|rm|restart)' \
  && fail "attach-only target was stopped or removed"
calls_contain 'dependency:.*:reset$' \
  && fail "attach-only target had its dependency state reset"
grep -q 'Attaching to an existing existing-process' "${test_root}/case17.out" \
  || fail "run-scenario.sh did not take the attach-only path: $(head -5 "${test_root}/case17.out")"
# It must still MEASURE -- an attach-only run that does nothing proves nothing.
calls_contain 'loadgen:measure' \
  || fail "attach-only target was never measured; the path refuses instead of attaching"

pkg="$(ls -dt "${test_root}"/artifacts/runs/*/ 2>/dev/null | head -1)"
[[ -n "${pkg}" ]] || fail "attach-only run produced no evidence package"
jq -e '.owned == false and (.reason | test("attach-only"))' "${pkg}/data/dataset.json" >/dev/null \
  || fail "attach-only dataset state does not record that the data is not ours: $(cat "${pkg}/data/dataset.json" 2>/dev/null)"

# --- acceptance case 18 ------------------------------------------------------
# An existing REMOTE environment is measured without lifecycle mutation. Same
# property as case 17 and a different code path, so it needs its own assertion:
# remote is the mode most likely to be pointed at something that matters.
run_scenario case18 PERFLAB_TARGET=remote PERFLAB_BASE_URL=http://127.0.0.1:9 PERFLAB_READY_URL=http://127.0.0.1:9/health || true
grep -qE 'compose:(up|down|stop|rm|restart)' "${calls}" \
  && fail "a remote target had its lifecycle mutated"
calls_contain 'dependency:.*:reset$' \
  && fail "a remote target had its dependency state reset"
grep -q 'no lifecycle/reset' "${test_root}/case18.out" \
  || fail "run-scenario.sh did not take the remote path: $(head -5 "${test_root}/case18.out")"

# --- C-6 interruption recovery ----------------------------------------------
marker="${test_root}/artifacts/.dataset-preparation"

# A run interrupted during WARM-UP has prepared the dataset but never measured.
# The marker has to outlive that, or the next run trusts a half-prepared state.
rm -f "${marker}"
run_scenario interrupted PERFLAB_TEST_FAIL_WARMUP=1 && fail "the simulated warm-up interruption did not fail the run"
[[ -f "${marker}" ]] \
  || fail "the dataset-preparation marker was cleared before warm-up finished, so the interruption left no trace"

# The next run must SEE that marker and say so.
run_scenario recovered || true
grep -q 'did not finish preparing the dataset' "${test_root}/recovered.out" \
  || fail "the following run did not notice the interrupted preparation"
pkg="$(ls -dt "${test_root}"/artifacts/runs/*/ 2>/dev/null | head -1)"
jq -e '.interruptionRecovered == true' "${pkg}/data/dataset.json" >/dev/null \
  || fail "recovery was not recorded in dataset.json: $(cat "${pkg}/data/dataset.json" 2>/dev/null)"

# And a clean run must clear it, or every later run would claim a recovery.
[[ ! -f "${marker}" ]] \
  || fail "a completed run left the marker behind; the next run would report a false interruption"
run_scenario clean || true
pkg="$(ls -dt "${test_root}"/artifacts/runs/*/ 2>/dev/null | head -1)"
jq -e '.interruptionRecovered == false' "${pkg}/data/dataset.json" >/dev/null \
  || fail "a run with no prior interruption reported one"

# --- acceptance case 3 -------------------------------------------------------
# A stateful journey mutates reference data, so it runs only after ownership,
# an explicit acknowledgement, a write budget and reset readiness all pass.
# Each gate is checked separately: a single "it refused" assertion would pass
# even if only one gate were doing the work, and the others were decorative.
run_scenario case3_noack PERF_REQUIRES_MANAGED_PARTITION=1 && fail "a managed-reference journey ran with no write acknowledgement"
grep -q 'PERF_WRITE_ACK=managed-reference' "${test_root}/case3_noack.out" \
  || fail "the refusal does not name the acknowledgement required: $(tail -3 "${test_root}/case3_noack.out")"

run_scenario case3_nobudget PERF_REQUIRES_MANAGED_PARTITION=1 PERF_WRITE_ACK=managed-reference \
  && fail "a managed-reference journey ran with no write budget"
grep -q 'PERF_WRITE_BUDGET' "${test_root}/case3_nobudget.out" \
  || fail "the refusal does not require a write budget"

# A budget must be a positive number. "unlimited" spelled as 0 or as a word is
# not a budget, and accepting it would make the gate ceremonial.
for bad in 0 -5 lots ""; do
  run_scenario "case3_badbudget" PERF_REQUIRES_MANAGED_PARTITION=1 \
    PERF_WRITE_ACK=managed-reference PERF_WRITE_BUDGET="${bad}" \
    && fail "a managed-reference journey accepted write budget '${bad}'"
done

# And ownership still governs: an attach-only target must not run a mutating
# journey at all, whatever acknowledgements the operator supplies.
run_scenario case3_unowned PERFLAB_TARGET_KIND=existing-process \
  PERF_REQUIRES_MANAGED_PARTITION=1 PERF_WRITE_ACK=managed-reference PERF_WRITE_BUDGET=100 || true
calls_contain 'dependency:.*:reset$' \
  && fail "a mutating journey reset dependency state on a target this run does not own"

# A correctly acknowledged and budgeted journey must then RUN, and prepare and
# clean up its partition. Testing only the refusals would pass an implementation
# that refused everything.
run_scenario case3_ok PERF_REQUIRES_MANAGED_PARTITION=1 \
  PERF_WRITE_ACK=managed-reference PERF_WRITE_BUDGET=100 || true
calls_contain 'partition:create' \
  || fail "an acknowledged, budgeted journey never prepared its managed-reference partition"
calls_contain 'loadgen:measure' \
  || fail "an acknowledged, budgeted journey never measured"
ok_pkg="$(ls -dt "${test_root}"/artifacts/runs/*/ | head -1)"
[[ -f "${ok_pkg}/cleanup-complete" ]] \
  || fail "a completed managed-reference journey did not restore its partition"

# --- acceptance case 14 ------------------------------------------------------
# The dataset a run measured is part of the measurement. Two runs over different
# data are not comparable, and without a recorded fingerprint that difference is
# invisible in the evidence.
run_scenario scale_small SEED_SCALE=smoke || true
small_pkg="$(ls -dt "${test_root}"/artifacts/runs/*/ | head -1)"
small_id="$(jq -r .datasetIdentity "${small_pkg}/data/dataset.json")"

run_scenario scale_large SEED_SCALE=large || true
large_pkg="$(ls -dt "${test_root}"/artifacts/runs/*/ | head -1)"
large_id="$(jq -r .datasetIdentity "${large_pkg}/data/dataset.json")"

[[ -n "${small_id}" && "${small_id}" != "null" ]] \
  || fail "no dataset identity was recorded for a data-scale run"
[[ "${small_id}" != "${large_id}" ]] \
  || fail "two different seed scales produced the same identity (${small_id}); a data-scale change would be invisible"

# The identity above is the DECLARED scale. It says what was asked for, and a
# reset that half-restored produces the same declaration as one that worked --
# so the dataset must also be fingerprinted by its CONTENT.
small_hash="$(jq -r '.contentFingerprint.sha256' "${small_pkg}/data/dataset.json")"
large_hash="$(jq -r '.contentFingerprint.sha256' "${large_pkg}/data/dataset.json")"
jq -e '.contentFingerprint.captureState == "captured"' "${small_pkg}/data/dataset.json" >/dev/null \
  || fail "no content fingerprint was taken; the dataset identity is only a declaration"
[[ "${small_hash}" =~ ^[0-9a-f]{64}$ ]] \
  || fail "the content fingerprint is not a digest: '${small_hash}'"
[[ "${small_hash}" != "${large_hash}" ]] \
  || fail "two different datasets hashed identically (${small_hash}); the fingerprint does not read the data"
calls_contain 'dependency:postgres:fingerprint' \
  || fail "the dataset was fingerprinted without asking any dependency for its state"

# The same scale must reproduce the same fingerprint, or the value is a nonce
# and every pair of runs looks incomparable.
run_scenario scale_small_again SEED_SCALE=smoke || true
again_pkg="$(ls -dt "${test_root}"/artifacts/runs/*/ | head -1)"
[[ "$(jq -r .datasetIdentity "${again_pkg}/data/dataset.json")" == "${small_id}" ]] \
  || fail "the same seed scale produced a different identity; the value is a nonce, not an identity"
[[ "$(jq -r '.contentFingerprint.sha256' "${again_pkg}/data/dataset.json")" == "${small_hash}" ]] \
  || fail "the same dataset hashed differently on a second run; the fingerprint is not stable"

# Every reset must have succeeded for the fingerprint to mean anything: a
# fingerprint recorded over state the run failed to clear describes data that
# was never prepared.
jq -e '.resetFailures == 0' "${small_pkg}/data/dataset.json" >/dev/null \
  || fail "a dataset fingerprint was recorded despite failed resets"

# --- acceptance case 25 ------------------------------------------------------
# Cancellation must preserve what was already captured and restore what the run
# mutated. A cancelled run that discards its evidence wastes the load it just
# generated; one that leaves its mutations behind poisons the next run.
cancel_dir="${test_root}/cancel"
: > "${calls}"
env PERFLAB_TEST_SLOW_WARMUP=1 \
  PATH="${test_root}/bin:${PATH}" \
  PERFLAB_CONFIG="${lab_config}" \
  PERFLAB_TEST_CALLS="${calls}" \
  PERFLAB_ARTIFACTS_ROOT="${test_root}/artifacts" \
  PERFLAB_WARMUP_SECONDS=0 \
  PERF_REQUIRES_MANAGED_PARTITION=1 PERF_WRITE_ACK=managed-reference PERF_WRITE_BUDGET=100 \
  bash "${test_root}/harness/core/run/run-scenario.sh" S01 1 > "${cancel_dir}.out" 2>&1 &
cancel_pid=$!
# Interrupt once the run is past preparation and into the load it would be
# cancelled during.
for _ in $(seq 1 60); do
  grep -q 'loadgen:warmup' "${calls}" 2>/dev/null && break
  sleep 0.5
done
kill -INT "${cancel_pid}" 2>/dev/null || true
wait "${cancel_pid}" 2>/dev/null || true
# An interrupted run does not stop instantly: its cleanup trap still runs. Give
# the child time to finish writing before any later case truncates the ledger,
# or the two interleave and the ledger describes neither run.
for _ in $(seq 1 50); do
  pgrep -P $$ -f run-scenario.sh >/dev/null 2>&1 || break
  sleep 0.1
done

cancelled_pkg="$(ls -dt "${test_root}"/artifacts/runs/*/ 2>/dev/null | head -1)"
[[ -n "${cancelled_pkg}" ]] \
  || fail "a cancelled run left no evidence package at all; the load it generated is unrecoverable"
[[ -s "${cancelled_pkg}/manifest.json" ]] \
  || fail "a cancelled run left no manifest, so the partial evidence cannot be identified"
# The mutation must actually be RESTORED. Accepting either outcome would pass a
# run that left its partition behind -- which is the failure the cleanup exists
# to prevent, not evidence that cleanup ran.
[[ -f "${cancelled_pkg}/cleanup-complete" ]] \
  || fail "a cancelled run did not restore the reference data it mutated: $(ls "${cancelled_pkg}" | tr '\n' ' ')"
[[ ! -f "${cancelled_pkg}/cleanup-incomplete" ]] \
  || fail "cleanup reported itself incomplete; the partition was left behind"
# And the cleanup must have actually invoked the restore, not just written a marker.
calls_contain 'partition:cleanup' \
  || fail "no cleanup call was made for the partition this run created"

# --- acceptance case 22 (end to end) ----------------------------------------
# API and worker are separate processes with separate runtimes. A campaign that
# captured both under one identity would attribute the worker's allocations to
# the API. Two campaigns are launched here and each must select its OWN process
# and replay its OWN load -- comparing assembly mappings proves neither.
cat > "${test_root}/harness/adapters/runtime/dotnet/capture.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
artifact_dir="${1:?}"; kind="${2:?}"; duration="${3:-30}"; target="${4:?}"
printf 'campaign:%s:%s\n' "${target}" "${kind}" >> "${PERFLAB_TEST_CALLS}"
mkdir -p "${artifact_dir}/runtime/${target}"
printf '{"target":"%s","requestedDiagnostic":"%s","status":"captured"}\n' "${target}" "${kind}" \
  > "${artifact_dir}/runtime/${target}/capture.json"
# Each campaign replays its own load into its own directory.
mkdir -p "${artifact_dir}/runtime/campaign-load/${target}"
printf 'replay:%s\n' "${target}" >> "${PERFLAB_TEST_CALLS}"
EOF
chmod +x "${test_root}/harness/adapters/runtime/dotnet/capture.sh"

: > "${calls}"
for service in api worker; do
  case "${service}" in api) campaign_scenario=S01 ;; worker) campaign_scenario=S17 ;; esac
  campaign_pkg="${test_root}/campaign-${service}"
  mkdir -p "${campaign_pkg}"
  printf '{"scenarioId":"%s","runId":"run-%s","telemetryRunId":"run-%s","target":"local","workload":{"loadGenerator":"k6","baseUrl":"http://127.0.0.1:8080","readyUrl":"http://127.0.0.1:8080/health","method":"GET","path":"/x","body":"","connections":"8"},"compatibility":{"generator":"k6","generatorFingerprint":"k6 v0","workloadContentHash":"%s","configurationHash":"%s"}}\n' \
    "${campaign_scenario}" "${service}" "${service}" \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    "0000000000000000000000000000000000000000000000000000000000000000" > "${campaign_pkg}/manifest.json"
  printf '{"observations":[],"compatibility":{"generator":"k6","generatorFingerprint":"k6 v0","workloadContentHash":"0000000000000000000000000000000000000000000000000000000000000000","configurationHash":"0000000000000000000000000000000000000000000000000000000000000000"}}\n' \
    > "${campaign_pkg}/facts.json"
  env PATH="${test_root}/bin:${PATH}" \
    PERFLAB_CONFIG="${lab_config}" \
    PERFLAB_TEST_CALLS="${calls}" \
    PERFLAB_ARTIFACTS_ROOT="${test_root}/artifacts" \
    bash "${test_root}/harness/core/capture/capture-runtime.sh" "${campaign_pkg}" trace 1 \
    > "${campaign_pkg}.out" 2>&1 || true
done

calls_contain 'campaign:api:' \
  || fail "no runtime campaign was launched for the api: $(cat "${test_root}/campaign-api.out" | tail -3)"
calls_contain 'campaign:worker:' \
  || fail "no runtime campaign was launched for the worker: $(cat "${test_root}/campaign-worker.out" | tail -3)"
[[ -s "${test_root}/campaign-api/runtime/api/capture.json" ]] \
  || fail "the api campaign produced no evidence under its own target directory"
[[ -s "${test_root}/campaign-worker/runtime/worker/capture.json" ]] \
  || fail "the worker campaign produced no evidence under its own target directory"
# Neither campaign may write into the other's directory: that is what
# attributing one process's cost to another looks like on disk.
[[ ! -e "${test_root}/campaign-api/runtime/worker" ]] \
  || fail "the api campaign wrote into the worker's directory"
[[ ! -e "${test_root}/campaign-worker/runtime/api" ]] \
  || fail "the worker campaign wrote into the api's directory"
# And each replayed its own load rather than sharing one.
[[ "$(grep -c '^replay:api$' "${calls}")" == "1" ]] \
  || fail "the api load was replayed $(grep -c '^replay:api$' "${calls}") time(s), want exactly 1"
[[ "$(grep -c '^replay:worker$' "${calls}")" == "1" ]] \
  || fail "the worker load was replayed $(grep -c '^replay:worker$' "${calls}") time(s), want exactly 1"

echo "run-scenario lifecycle tests passed"
