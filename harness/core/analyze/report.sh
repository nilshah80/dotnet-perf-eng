#!/usr/bin/env bash
# Human-readable run report.
#
# The evidence package is written for machines: facts.json is an index, and the
# analysis files each answer one question. An engineer opening a package cold
# has to know which of ~90 files to read first. This renders the verdict, the
# capture states, and the pointers into one page -- so the FIRST thing a reader
# sees is what was measured, what the evidence can and cannot support, and where
# to look next.
#
# It renders only what the package already contains. It computes no new
# verdicts, and a missing input becomes a visible gap rather than a blank: a
# report that quietly omits an absent signal would recreate the exact failure
# (absence reading as health) the capture states exist to prevent.
#
#   report.sh <run-dir>   ->   <run-dir>/analysis/report.html
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

run_arg="${1:?report.sh <run-dir>}"
facts="${run_arg}/facts.json"
[[ -f "${facts}" ]] || { echo "No facts.json in ${run_arg}" >&2; exit 1; }
out="${run_arg}/analysis/report.html"
mkdir -p "${run_arg}/analysis"

j() { jqd -r "$1" < "$2" 2>/dev/null || printf '%s' "${3:-—}"; }
esc() { printf '%s' "${1//&/&amp;}" | sed 's/</\&lt;/g; s/>/\&gt;/g'; }

scenario="$(j '.scenarioId // "—"' "${facts}")"
run_id="$(j '.runId // "—"' "${facts}")"
status="$(j '.status // "unknown"' "${facts}")"
generator="$(j '.loadGenerator // "—"' "${facts}")"

bn="${run_arg}/analysis/bottleneck.json"
verdict="—"; confidence="—"; reason=""
if [[ -s "${bn}" ]]; then
  verdict="$(j '.verdict // "—"' "${bn}")"
  confidence="$(j '.confidence // "—"' "${bn}")"
  reason="$(j '.reason // ""' "${bn}")"
fi

cs="${run_arg}/telemetry/capture-status.json"
sig_rows=""
if [[ -s "${cs}" ]]; then
  while IFS=$'\t' read -r name state detail; do
    [[ -z "${name}" ]] && continue
    cls="ok"; case "${state}" in empty|missing|failed) cls="bad" ;; partial|delayed|truncated) cls="warn" ;; not-applicable) cls="na" ;; esac
    sig_rows+="<tr><td>$(esc "${name}")</td><td class=\"${cls}\">$(esc "${state}")</td><td>$(esc "${detail}")</td></tr>"
  done < <(jqd -r '.signals | to_entries[] | [.key, (.value.captureState // "—"),
      ((.value.returned // .value.files // .value.records // "") | tostring)] | @tsv' < "${cs}" 2>/dev/null || true)
fi

cap="${run_arg}/runtime/capture.json"
diag_rows=""; lim_items=""
if [[ -s "${cap}" ]]; then
  req="$(j '.requestedDiagnostic // "—"' "${cap}")"; eff="$(j '.effectiveDiagnostic // "—"' "${cap}")"
  cnt="$(j '.counters.captureState // "—"' "${cap}")"
  fb="$(j '.fallbackReason // ""' "${cap}")"
  diag_rows+="<tr><td>diagnostic</td><td class=\"$( [[ "${req}" == "${eff}" ]] && echo ok || echo warn )\">$(esc "${req}") &rarr; $(esc "${eff}")</td><td>$(esc "${fb}")</td></tr>"
  diag_rows+="<tr><td>runtime counters</td><td class=\"$( [[ "${cnt}" == captured ]] && echo ok || echo warn )\">$(esc "${cnt}")</td><td>dotnet-monitor /livemetrics</td></tr>"
  while IFS= read -r lim; do [[ -n "${lim}" ]] && lim_items+="<li>$(esc "${lim}")</li>"; done \
    < <(jqd -r '.limitations[]?' < "${cap}" 2>/dev/null || true)
fi

obs_rows=""
while IFS=$'\t' read -r n v u src; do
  [[ -z "${n}" ]] && continue
  obs_rows+="<tr><td>$(esc "${n}")</td><td class=\"num\">$(esc "${v}")</td><td>$(esc "${u}")</td><td class=\"path\">$(esc "${src}")</td></tr>"
done < <(jqd -r '.observations[]? | [.name, (.value|tostring), (.unit // ""), (.source // "")] | @tsv' < "${facts}" 2>/dev/null || true)

retain=""
rd="${run_arg}/analysis/runtime/diff-gcdump-before-after.txt"
[[ -s "${rd}" ]] && retain="$(grep -m1 'total delta:' "${rd}" 2>/dev/null || true)"

status_cls="ok"; [[ "${status}" != "captured" ]] && status_cls="warn"

cat > "${out}" <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${scenario} — run report</title><style>
:root{--bg:#fff;--fg:#1a1a1a;--mut:#666;--line:#e3e3e3;--ok:#0a7c3f;--warn:#9a6700;--bad:#b42318;--na:#888;--card:#fafafa}
@media(prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#111;--fg:#eee;--mut:#9a9a9a;--line:#2c2c2c;--ok:#3fb950;--warn:#d29922;--bad:#f85149;--na:#777;--card:#1a1a1a}}
:root[data-theme=dark]{--bg:#111;--fg:#eee;--mut:#9a9a9a;--line:#2c2c2c;--ok:#3fb950;--warn:#d29922;--bad:#f85149;--na:#777;--card:#1a1a1a}
*{box-sizing:border-box}body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);
font:15px/1.55 ui-sans-serif,-apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:960px;margin:0 auto}h1{font-size:1.5rem;margin:0 0 2px}h2{font-size:1rem;margin:28px 0 8px;
text-transform:uppercase;letter-spacing:.06em;color:var(--mut)}
.sub{color:var(--mut);margin:0 0 20px;font-size:.9rem}
.verdict{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--fg);
border-radius:6px;padding:14px 16px;margin-bottom:8px}
.verdict .v{font-size:1.15rem;font-weight:600}
table{width:100%;border-collapse:collapse;margin:6px 0 4px;font-size:.88rem}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--mut);font-weight:600;font-size:.78rem;text-transform:uppercase;letter-spacing:.04em}
td.num{text-align:right;font-variant-numeric:tabular-nums}
td.path,.path{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.8rem;color:var(--mut);word-break:break-all}
.ok{color:var(--ok);font-weight:600}.warn{color:var(--warn);font-weight:600}
.bad{color:var(--bad);font-weight:600}.na{color:var(--na)}
ul{margin:6px 0;padding-left:20px;color:var(--mut);font-size:.85rem}
.note{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:10px 14px;
font-size:.85rem;color:var(--mut)}
@media(max-width:640px){body{padding:16px}table{font-size:.82rem}}
</style></head><body><main>
<h1>${scenario} &mdash; $(esc "${verdict}")</h1>
<p class="sub">run <span class="path">$(esc "${run_id}")</span> &middot; generator ${generator}
&middot; package <span class="${status_cls}">$(esc "${status}")</span></p>

<div class="verdict"><div class="v">$(esc "${verdict}") <span class="${confidence}">[$(esc "${confidence}")]</span></div>
<div>$(esc "${reason}")</div></div>
$( [[ -n "${retain}" ]] && printf '<div class="note"><strong>Retention:</strong> %s &mdash; see <span class="path">analysis/runtime/diff-gcdump-before-after.txt</span> for the growing types.</div>' "$(esc "${retain#\# }")" )

<h2>Evidence completeness</h2>
<table><thead><tr><th>Signal</th><th>State</th><th>Detail</th></tr></thead>
<tbody>${sig_rows:-<tr><td colspan=3 class=na>no capture-status.json in this package</td></tr>}</tbody></table>

<h2>Runtime diagnostics</h2>
<table><thead><tr><th>Item</th><th>State</th><th>Detail</th></tr></thead>
<tbody>${diag_rows:-<tr><td colspan=3 class=na>no runtime capture in this package</td></tr>}</tbody></table>
$( [[ -n "${lim_items}" ]] && printf '<p class="sub" style="margin:10px 0 2px">What this capture cannot show:</p><ul>%s</ul>' "${lim_items}" )

<h2>Measured observations</h2>
<table><thead><tr><th>Metric</th><th>Value</th><th>Unit</th><th>Source</th></tr></thead>
<tbody>${obs_rows:-<tr><td colspan=4 class=na>no observations recorded</td></tr>}</tbody></table>

<p class="sub" style="margin-top:24px">Rendered from this package only. Every value above cites the raw
artifact it came from; nothing here is recomputed.</p>
</main></body></html>
HTML

echo "Report: ${out}"
