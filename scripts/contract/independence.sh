#!/usr/bin/env sh
# Fail closed on sibling-relative paths and peer-owned JMeter artifact guidance
# in shipped samples, code, scripts, and README. Dots in path needles are
# matched as literals (grep -F), not regex.
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
cd "$root"

img="perflab-load-"$(printf '%s' "jmeter")
pkg="package-plugin.sh"
hits="$(
  grep -R -n -F "$img" labs README.md harness source scripts 2>/dev/null || true
  grep -R -n -F "$pkg" labs README.md harness source scripts 2>/dev/null || true
  grep -R -n -F "../perflab" labs README.md harness source scripts 2>/dev/null || true
  grep -R -n -F "../../perflab" labs README.md harness source scripts 2>/dev/null || true
  grep -R -n -F "PoC/perflab" labs README.md harness source scripts 2>/dev/null || true
)"
hits="$(printf '%s\n' "$hits" | grep -v "docs/archive/" | grep -v "scripts/contract/" | grep -v '^$' || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  echo "independence scan failed: peer image, package helper, or sibling path in shipped files" >&2
  exit 1
fi

if [ -e .github/workflows/coordinate-performance-contract.yml ] || [ -d scripts/contract/coordinate-release ]; then
  echo "coordinator must not live in the native repository" >&2
  exit 1
fi

echo "independence scan passed"
