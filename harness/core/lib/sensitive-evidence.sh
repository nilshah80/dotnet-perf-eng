#!/usr/bin/env bash
# Sensitive evidence retention.
#
# A process dump is a copy of process memory: connection strings, bearer tokens
# and request payloads come with it. An evidence package is what gets shared, so
# a dump never stays in one (acceptance case 26: no credential value in
# artifacts). retain_sensitive_file moves the file to the artifacts root's
# sensitive/ store -- still inside the tree the diagnostics container mounts at
# /artifacts, so dotnet-dump can analyse it -- readable by the owner only, and
# leaves a pointer at the original path with the hash, size, classification and
# retention deadline. This is the native form of PerfLab's retained,
# non-exportable dump artifact.
#
# Sourced by the .NET capture and normalization adapters and capture-runtime.sh.
# Reads artifacts_root and json_escape from common.sh.

sensitive_sha256() { # <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sensitive_utc_after_days() { # <days> -> ISO-8601 UTC timestamp
  local at=$(( $(date +%s) + $1 * 86400 ))
  date -u -d "@${at}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "${at}" +%Y-%m-%dT%H:%M:%SZ
}

retain_sensitive_file() { # <file-inside-artifacts-root> [classification]
  local file="$1" classification="${2:-process-memory}" root rel target days sha bytes
  [[ -f "${file}" ]] || return 0
  root="${artifacts_root:-}"
  if [[ -z "${root}" || "${file}" != "${root}/"* ]]; then
    rm -f "${file}"
    echo "Refusing to keep ${file##*/} outside the artifacts root's sensitive store; it was deleted." >&2
    return 1
  fi
  rel="${file#"${root}/"}"
  [[ "${rel}" != sensitive/* ]] || return 0
  days="${PERFLAB_SENSITIVE_RETENTION_DAYS:-7}"
  case "${days}" in ''|*[!0-9]*) rm -f "${file}"; echo "PERFLAB_SENSITIVE_RETENTION_DAYS must be an integer; ${file##*/} was deleted." >&2; return 1 ;; esac
  target="${root}/sensitive/${rel}"
  ( umask 077; mkdir -p "${root}/sensitive" "$(dirname "${target}")" )
  chmod 700 "${root}/sensitive" 2>/dev/null || true
  mv -f "${file}" "${target}"
  chmod 600 "${target}" 2>/dev/null || true
  sha="$(sensitive_sha256 "${target}")"
  bytes="$(wc -c < "${target}" | tr -d ' ')"
  printf '{"version":"perflab-sensitive-retention-v1","classification":"%s","exportable":false,"retainedPath":"%s","sha256":"%s","bytes":%s,"retainedAt":"%s","retainUntil":"%s","reason":"%s"}\n' \
    "$(json_escape "${classification}")" "$(json_escape "sensitive/${rel}")" "${sha}" "${bytes}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sensitive_utc_after_days "${days}")" \
    "a process dump holds process memory, including connection strings and tokens; it is kept outside the evidence package" \
    > "${file}.retained.json"
}
