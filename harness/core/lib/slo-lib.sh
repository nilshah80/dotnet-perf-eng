#!/usr/bin/env bash
# Shared SLO reader. Sourced by analyze/gate.sh and analyze/find-knee.sh.
#
# slo_effective <slos.tsv> <scenario-id>
#   Emits the effective SLOs for a scenario as TAB-separated "metric op threshold"
#   lines: a scenario's own row overrides the "default" row for that metric, and
#   every default metric the scenario does not override is inherited. Comment (#)
#   and short lines are skipped; a trailing CR (Windows checkouts) is stripped.
slo_effective() {
  local file="$1" scenario="$2"
  [[ -s "${file}" ]] || return 0
  awk -F'\t' -v scen="${scenario}" '
    /^[[:space:]]*#/ { next }
    NF < 4 { next }
    { gsub(/\r$/, "", $4); m = $2
      if ($1 == "default")   { dop[m] = $3; dthr[m] = $4 }
      else if ($1 == scen)   { oop[m] = $3; othr[m] = $4 }
    }
    END {
      for (m in oop) print m "\t" oop[m] "\t" othr[m]
      for (m in dop) if (!(m in oop)) print m "\t" dop[m] "\t" dthr[m]
    }
  ' "${file}"
}
