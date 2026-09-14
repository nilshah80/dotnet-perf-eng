#!/usr/bin/env bash
# k6 load-profile translator. Sourced by the k6 adapter's run.sh for the MEASURE
# phase when PERFLAB_PROFILE != steady. Emits a k6 config file (JSON options)
# whose "scenarios.measure" is the executor for the chosen profile; run.sh passes
# it via `k6 run --config <file>` (k6 honors a config-file scenario without any
# change to the workload script, which keeps providing only default()).
#
# Shapes come from the canonical profile compiler (harness/core/profile), not from
# a second copy of stage math in this file.

k6_profile_cmd_dir() {
  if [[ -n "${harness_core_dir:-}" ]]; then
    printf '%s' "${harness_core_dir}/performance/cmd"
    return
  fi
  printf '%s' "${HARNESS_ROOT:?HARNESS_ROOT or harness_core_dir is required}/core/performance/cmd"
}

# k6_write_profile_config <profile> <connections> <duration-seconds> <out-file>
k6_write_profile_config() {
  local profile="$1" c="$2" d="$3" out="$4"
  go run "$(k6_profile_cmd_dir)" profile k6-config "${profile}" "${c}" "${d}" > "${out}"
}

# k6_profile_effective_duration <profile> <connections> <duration> -> the seconds
# the MEASURE phase actually runs, driven by the canonical compiler stages.
k6_profile_effective_duration() {
  local profile="$1" c="$2" d="$3"
  go run "$(k6_profile_cmd_dir)" profile duration "${profile}" "${c}" "${d}"
}
