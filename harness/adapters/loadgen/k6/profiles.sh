#!/usr/bin/env bash
# k6 load-profile translator. Sourced by the k6 adapter's run.sh for the MEASURE
# phase when PERFLAB_PROFILE != steady. Emits a k6 config file (JSON options)
# whose "scenarios.measure" is the executor for the chosen profile; run.sh passes
# it via `k6 run --config <file>` (k6 honors a config-file scenario without any
# change to the workload script, which keeps providing only default()).
#
# All shapes derive from the scenario's own connections (C) and duration (D), so
# a profile is a run-time choice layered on any scenario -- no scenarios.tsv
# change. Tuning knobs (optional env): PERFLAB_MAX_VUS, PERFLAB_SPIKE_VUS,
# PERFLAB_TARGET_RPS, PERFLAB_START_RPS, PERFLAB_SOAK_DURATION_SECONDS.
#
# Closed model (VU-shaped): ramp, stress, spike, soak.
# Open model (arrival-rate, coordinated-omission-safe latency): capacity, arrival.

# k6_write_profile_config <profile> <connections> <duration-seconds> <out-file>
k6_write_profile_config() {
  local profile="$1" c="$2" d="$3" out="$4"
  local max_vus="${PERFLAB_MAX_VUS:-$(( c * 4 ))}"
  local spike_vus="${PERFLAB_SPIKE_VUS:-$(( c * 4 ))}"
  local target_rps="${PERFLAB_TARGET_RPS:-$(( c * 10 ))}"
  local start_rps="${PERFLAB_START_RPS:-1}"
  local soak_d="${PERFLAB_SOAK_DURATION_SECONDS:-$(( d > 600 ? d : 600 ))}"
  # Interpolation points (clamped to >=1 so tiny C/D still produce valid stages).
  local half=$(( d / 2 > 0 ? d / 2 : 1 ))
  local q=$(( d / 4 > 0 ? d / 4 : 1 ))
  local c1=$(( c / 4 > 0 ? c / 4 : 1 ))
  local c2=$(( c / 2 > 0 ? c / 2 : 1 ))
  local c3=$(( c * 3 / 4 > 0 ? c * 3 / 4 : 1 ))
  local sc
  case "${profile}" in
    ramp)     # closed model: step the VUs up to C to find where latency degrades
      sc="{\"executor\":\"ramping-vus\",\"startVUs\":0,\"gracefulRampDown\":\"0s\",\"stages\":[{\"duration\":\"${q}s\",\"target\":${c1}},{\"duration\":\"${q}s\",\"target\":${c2}},{\"duration\":\"${q}s\",\"target\":${c3}},{\"duration\":\"${q}s\",\"target\":${c}}]}" ;;
    stress)   # push past C toward MAX_VUS to find the breaking point / saturation
      sc="{\"executor\":\"ramping-vus\",\"startVUs\":0,\"gracefulRampDown\":\"0s\",\"stages\":[{\"duration\":\"${half}s\",\"target\":${c}},{\"duration\":\"${half}s\",\"target\":${max_vus}}]}" ;;
    spike)    # baseline C, sudden surge to SPIKE_VUS, then recover to C
      sc="{\"executor\":\"ramping-vus\",\"startVUs\":0,\"gracefulRampDown\":\"0s\",\"stages\":[{\"duration\":\"5s\",\"target\":${c}},{\"duration\":\"${q}s\",\"target\":${c}},{\"duration\":\"5s\",\"target\":${spike_vus}},{\"duration\":\"${q}s\",\"target\":${spike_vus}},{\"duration\":\"5s\",\"target\":${c}},{\"duration\":\"${q}s\",\"target\":${c}}]}" ;;
    soak)     # sustained constant load for a long window (leaks, GC/socket drift)
      sc="{\"executor\":\"constant-vus\",\"vus\":${c},\"duration\":\"${soak_d}s\"}" ;;
    capacity) # open model: ramp arrival rate to TARGET_RPS to find the knee
      sc="{\"executor\":\"ramping-arrival-rate\",\"startRate\":${start_rps},\"timeUnit\":\"1s\",\"preAllocatedVUs\":${c},\"maxVUs\":${max_vus},\"stages\":[{\"duration\":\"${d}s\",\"target\":${target_rps}}]}" ;;
    arrival)  # open model: hold a fixed TARGET_RPS (latency at a set throughput)
      sc="{\"executor\":\"constant-arrival-rate\",\"rate\":${target_rps},\"timeUnit\":\"1s\",\"duration\":\"${d}s\",\"preAllocatedVUs\":${c},\"maxVUs\":${max_vus}}" ;;
    *)
      echo "k6_write_profile_config: unknown profile '${profile}'" >&2
      return 1 ;;
  esac
  printf '{"scenarios":{"measure":%s},"summaryTrendStats":["avg","min","med","max","p(50)","p(90)","p(99)"],"discardResponseBodies":true}\n' \
    "${sc}" > "${out}"
}
