#!/usr/bin/env bash
# Build the native JMeter adapter image. Host Java/Go are not required; Docker
# performs the compile and JMeter install. Prints the local image digest.
set -euo pipefail
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
image_name="${DOTNET_PERF_ENG_JMETER_IMAGE_NAME:-dotnet-perf-eng-load-jmeter:local}"
platform="${DOTNET_PERF_ENG_JMETER_PLATFORM:-}"

# An optional vendored tarball is copied when present. The Dockerfile downloads
# Apache JMeter 5.6.3 itself when the file is absent.
if [[ -f "${here}/apache-jmeter.tgz" ]]; then
  cp "${here}/apache-jmeter.tgz" "${here}/vendor/apache-jmeter.tgz"
  echo "using vendored ${here}/apache-jmeter.tgz" >&2
fi

build_args=()
if [[ -n "${platform}" ]]; then
  build_args+=(--platform "${platform}")
fi
docker build "${build_args[@]}" -t "${image_name}" "${here}"
digest="$(docker image inspect --format '{{.Id}}' "${image_name}")"
printf '%s\n' "${digest}"
printf 'PERFLAB_JMETER_IMAGE=%s\n' "${digest}" >&2
