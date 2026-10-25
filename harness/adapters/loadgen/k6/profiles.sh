#!/usr/bin/env bash
# Script-native profile compiler for the project-owned k6 workload.

k6_positive_step() {
  local total="$1" divisor="$2" value
  value=$((total / divisor))
  (( value < 1 )) && value=1
  printf '%s' "${value}"
}

k6_profile_effective_duration() {
  local profile="$1" _connections="$2" duration="$3" q half soak
  q="$(k6_positive_step "${duration}" 4)"
  half="$(k6_positive_step "${duration}" 2)"
  case "${profile}" in
    smoke) printf '12' ;;
    load) printf '%s' "$((duration + 2 * $(k6_positive_step "${duration}" 10)))" ;;
    steady|closed) printf '%s' "${duration}" ;;
    ramp|breakpoint) printf '%s' "$((4 * q))" ;;
    stress|capacity|knee) printf '%s' "$((2 * half))" ;;
    spike) printf '%s' "$((15 + 3 * q))" ;;
    open|arrival) printf '%s' "${duration}" ;;
    soak)
      soak="${PERFLAB_SOAK_DURATION_SECONDS:-600}"
      [[ "${soak}" =~ ^[1-9][0-9]*$ ]] || {
        echo "PERFLAB_SOAK_DURATION_SECONDS must be a positive integer." >&2
        return 1
      }
      printf '%s' "${soak}"
      ;;
    *) echo "unknown profile '${profile}'" >&2; return 1 ;;
  esac
}

k6_browser_options() {
  if [[ "${PERF_PROTOCOL:-}" == "browser-synthetic" ]]; then
    printf '%s' ',"options":{"browser":{"type":"chromium"}}'
  fi
}

k6_write_profile_config() {
  local profile="$1" connections="$2" duration="$3" out="$4" name="${5:-measure}"
  local q half tenth max_vus spike_vus target_rps start_rps soak browser
  q="$(k6_positive_step "${duration}" 4)"
  half="$(k6_positive_step "${duration}" 2)"
  tenth="$(k6_positive_step "${duration}" 10)"
  max_vus="${PERFLAB_MAX_VUS:-$((connections * 4))}"
  spike_vus="${PERFLAB_SPIKE_VUS:-$((connections * 4))}"
  target_rps="${PERFLAB_TARGET_RPS:-$((connections * 10))}"
  start_rps="${PERFLAB_START_RPS:-1}"
  soak="${PERFLAB_SOAK_DURATION_SECONDS:-600}"
  browser="$(k6_browser_options)"
  for value in "${connections}" "${duration}" "${max_vus}" "${spike_vus}" \
    "${target_rps}" "${start_rps}" "${soak}"; do
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || {
      echo "profile values must be positive integers; received '${value}'." >&2
      return 1
    }
  done

  local scenario
  case "${profile}" in
    smoke)
      scenario="{\"executor\":\"ramping-vus\",\"startVUs\":0,\"gracefulRampDown\":\"0s\",\"stages\":[{\"duration\":\"2s\",\"target\":1},{\"duration\":\"10s\",\"target\":1}]${browser}}"
      ;;
    load)
      scenario="{\"executor\":\"ramping-vus\",\"startVUs\":0,\"gracefulRampDown\":\"0s\",\"stages\":[{\"duration\":\"${tenth}s\",\"target\":${connections}},{\"duration\":\"${tenth}s\",\"target\":${connections}},{\"duration\":\"${duration}s\",\"target\":${connections}}]${browser}}"
      ;;
    ramp)
      scenario="{\"executor\":\"ramping-vus\",\"startVUs\":0,\"gracefulRampDown\":\"0s\",\"stages\":[{\"duration\":\"${q}s\",\"target\":$((connections / 4 > 0 ? connections / 4 : 1))},{\"duration\":\"${q}s\",\"target\":$((connections / 2 > 0 ? connections / 2 : 1))},{\"duration\":\"${q}s\",\"target\":$((connections * 3 / 4 > 0 ? connections * 3 / 4 : 1))},{\"duration\":\"${q}s\",\"target\":${connections}}]${browser}}"
      ;;
    stress)
      scenario="{\"executor\":\"ramping-vus\",\"startVUs\":0,\"gracefulRampDown\":\"0s\",\"stages\":[{\"duration\":\"${half}s\",\"target\":${connections}},{\"duration\":\"${half}s\",\"target\":${max_vus}}]${browser}}"
      ;;
    breakpoint)
      scenario="{\"executor\":\"ramping-vus\",\"startVUs\":0,\"gracefulRampDown\":\"0s\",\"stages\":[{\"duration\":\"${q}s\",\"target\":$((connections / 2 > 0 ? connections / 2 : 1))},{\"duration\":\"${q}s\",\"target\":${connections}},{\"duration\":\"${q}s\",\"target\":${max_vus}},{\"duration\":\"${q}s\",\"target\":$(((connections + max_vus) / 2))}]${browser}}"
      ;;
    spike)
      scenario="{\"executor\":\"ramping-vus\",\"startVUs\":0,\"gracefulRampDown\":\"0s\",\"stages\":[{\"duration\":\"5s\",\"target\":${connections}},{\"duration\":\"${q}s\",\"target\":${connections}},{\"duration\":\"5s\",\"target\":${spike_vus}},{\"duration\":\"${q}s\",\"target\":${spike_vus}},{\"duration\":\"5s\",\"target\":${connections}},{\"duration\":\"${q}s\",\"target\":${connections}}]${browser}}"
      ;;
    open|arrival)
      scenario="{\"executor\":\"constant-arrival-rate\",\"rate\":${target_rps},\"timeUnit\":\"1s\",\"duration\":\"${duration}s\",\"preAllocatedVUs\":${connections},\"maxVUs\":${max_vus}${browser}}"
      ;;
    capacity|knee)
      scenario="{\"executor\":\"ramping-arrival-rate\",\"startRate\":${start_rps},\"timeUnit\":\"1s\",\"preAllocatedVUs\":${connections},\"maxVUs\":${max_vus},\"stages\":[{\"duration\":\"${half}s\",\"target\":$((target_rps / 2 > 0 ? target_rps / 2 : 1))},{\"duration\":\"${half}s\",\"target\":${target_rps}}]${browser}}"
      ;;
    closed)
      scenario="{\"executor\":\"constant-vus\",\"vus\":${connections},\"duration\":\"${duration}s\"${browser}}"
      ;;
    soak)
      scenario="{\"executor\":\"constant-vus\",\"vus\":${connections},\"duration\":\"${soak}s\"${browser}}"
      ;;
    steady)
      scenario="{\"executor\":\"constant-vus\",\"vus\":${connections},\"duration\":\"${duration}s\"${browser}}"
      ;;
    *) echo "unknown profile '${profile}'" >&2; return 1 ;;
  esac

  printf '%s\n' "{\"scenarios\":{\"${name}\":${scenario}},\"summaryTrendStats\":[\"avg\",\"min\",\"med\",\"max\",\"p(50)\",\"p(90)\",\"p(95)\",\"p(99)\"],\"discardResponseBodies\":true}" \
    | jqd '.' > "${out}"
}

# Warm-up drives the measured workload's own shape at its initial steady level,
# only shorter: a fixed 16 unthrottled VUs was far hotter than a 10 req/s arrival
# run, and against a connection-per-iteration workload it churned thousands of
# connections a second and exhausted the generator's ephemeral ports before the
# measurement began.
k6_write_warmup_config() {
  local profile="$1" connections="$2" seconds="$3" out="$4" rate
  case "${profile}" in
    open|arrival) k6_write_profile_config open "${connections}" "${seconds}" "${out}" warmup ;;
    capacity|knee)
      rate="${PERFLAB_TARGET_RPS:-$((connections * 10))}"
      rate=$((rate / 2 > 0 ? rate / 2 : 1))
      PERFLAB_TARGET_RPS="${rate}" k6_write_profile_config open "${connections}" "${seconds}" "${out}" warmup
      ;;
    smoke) k6_write_profile_config closed 1 "${seconds}" "${out}" warmup ;;
    *) k6_write_profile_config closed "${connections}" "${seconds}" "${out}" warmup ;;
  esac
}
