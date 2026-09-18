#!/usr/bin/env bash
# Phase-scoped environment envelope.
#
# A single mid-load `docker stats` sample cannot separate "the app slowed down"
# from "the host was already loaded before we started" or "a neighbour spiked
# after the window closed". Four boundary snapshots can: pre-run establishes the
# baseline, measurement-start and measurement-end bracket the measured window,
# and post-run shows what the run left behind. Each is a point sample, not a
# series -- it answers "what was the environment at this boundary", which is the
# question a mid-load sample silently conflates with "what was it throughout".
#
# Best-effort by contract: the environment is context for a verdict, never the
# verdict itself, so a docker or /proc hiccup must not fail a measured run. Each
# snapshot records its own captureState so a reader can tell an absent sample
# from a healthy-but-idle one.
#
#   capture-environment.sh <artifact-dir> <phase>
#     phase: pre-run | measurement-start | measurement-end | post-run
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

artifact_dir="${1:?capture-environment.sh <artifact-dir> <phase>}"
phase="${2:?phase required}"
case "${phase}" in
  pre-run|measurement-start|measurement-end|post-run) ;;
  *) echo "Unknown environment phase '${phase}'. Use pre-run, measurement-start, measurement-end, or post-run." >&2; exit 1 ;;
esac

out_dir="${artifact_dir}/environment/${phase}"
mkdir -p "${out_dir}"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

state="captured"; reason=""

# Per-container resource usage at this boundary. Without the container id list
# this would sample every container on the host, including ones this run does
# not own.
cids="$(compose ps -q 2>/dev/null | tr '\n' ' ' || true)"
if [[ -n "${cids// /}" ]]; then
  # shellcheck disable=SC2086
  MSYS_NO_PATHCONV=1 docker stats --no-stream --format '{{json .}}' ${cids} \
    > "${out_dir}/container-stats.ndjson" 2>/dev/null \
    || { state="partial"; reason="docker stats unavailable at this boundary"; }
else
  state="partial"; reason="no owned containers were running at this boundary"
fi

# Compose topology: which services existed, and in what state. A container that
# restarted between two boundaries is invisible in the stats alone.
compose ps --format json 2>/dev/null | jqd -s '.' > "${out_dir}/compose-ps.json" 2>/dev/null || true

# Host pressure. The app's own container metrics cannot show that the HOST was
# saturated by something outside the compose project.
{
  printf '{"capturedAt":"%s","phase":"%s"' "${captured_at}" "${phase}"
  # macOS prints "load averages: 3.56 2.69 2.74" (space separated); Linux prints
  # "load average: 0.15, 0.20, 0.18" (comma separated). Normalise commas to
  # spaces and split on whitespace -- stripping spaces instead would concatenate
  # the three figures into one unparseable token and emit invalid JSON.
  if load="$(uptime 2>/dev/null | sed -n 's/.*load averages*: *//p' | tr ',' ' ')"; then
    read -r l1 l5 l15 _rest <<< "${load}" || true
    if [[ "${l1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      printf ',"loadAverage":{"1m":%s,"5m":%s,"15m":%s}' \
        "${l1}" "$([[ "${l5:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "${l5}" || printf 'null')" \
        "$([[ "${l15:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "${l15}" || printf 'null')"
    fi
  fi
  printf ',"dockerContainersRunning":%s' "$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
  printf '}\n'
} > "${out_dir}/host.json" 2>/dev/null || true

printf '{"phase":"%s","capturedAt":"%s","captureState":"%s","reason":"%s","artifacts":["environment/%s/container-stats.ndjson","environment/%s/compose-ps.json","environment/%s/host.json"]}\n' \
  "$(json_escape "${phase}")" "$(json_escape "${captured_at}")" "${state}" "$(json_escape "${reason}")" \
  "${phase}" "${phase}" "${phase}" > "${out_dir}/environment.json"
