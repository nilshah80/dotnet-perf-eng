#!/usr/bin/env bash
# Map a Docker TARGETARCH (or uname -m) value to the grafana/pyroscope-dotnet
# glibc tarball architecture. Host architecture is intentionally not consulted.
pyroscope_glibc_arch() {
  case "${1:-}" in
    amd64|x86_64) printf 'x86_64\n' ;;
    arm64|aarch64) printf 'aarch64\n' ;;
    *)
      echo "unsupported Docker TARGETARCH '${1:-}' (want amd64/x86_64 or arm64/aarch64)." >&2
      return 1
      ;;
  esac
}
