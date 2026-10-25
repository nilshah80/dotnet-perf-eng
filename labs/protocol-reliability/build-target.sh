#!/usr/bin/env bash
# Builds the Protocol Reliability target for the live Gate B tests the way the
# lab image does -- the Dockerfile's Release publish stage, inside the .NET SDK
# image, where Grpc.Tools' protoc runs natively on any host -- and copies the
# published app into <out-dir>. Nothing is written to the source tree and no
# restore state is borrowed from it. Prints the path of the app's DLL.
set -euo pipefail
out="${1:?build-target.sh <out-dir>}"
root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
image="$(docker build -q --target build "${root}/source/dotnet/protocol-reliability")"
container="$(docker create "${image}")"
trap 'docker rm -f "${container}" >/dev/null 2>&1 || true; docker rmi "${image}" >/dev/null 2>&1 || true' EXIT
mkdir -p "${out}"
docker cp "${container}:/app/." "${out}/" >/dev/null
printf '%s/ProtocolReliability.Api.dll\n' "${out}"
