#!/usr/bin/env python3
"""Generate the Grafana dashboard suite for every performance lab.

Why a generator: the two labs (scenariolab, ecommerce) must stay in lock-step --
same panels, same scoping model, same UX -- differing only in the app-metric
prefix, the service_name regex, and which dependencies exist. Hand-maintaining
nine near-identical dashboard JSON files would drift. This emits them from one
source of truth, keyed off the SAME descriptor values the rest of the harness
reads from labs/<lab>/lab.config.sh (PERFLAB_APP_METRIC_PREFIX,
PERFLAB_SERVICE_NAME_REGEX, PERFLAB_DEPENDENCIES).

Output: labs/<lab>/infra/grafana/dashboards/*.json  (provisioned as a folder).

Run: python3 harness/adapters/observability/grafana/generate-dashboards.py
It writes into both labs and is idempotent. Re-run after editing panels here;
never hand-edit the emitted JSON (it will be overwritten).

Scoping model (kept identical across labs):
  $service   service_name (multi, All)      -- primary selector, always present
  $instance  service_instance_id (multi)    -- narrows runtime/GC to one process
  $scenario  scenario_id (from app counter) -- narrows app-metric panels
  $run       perf_run_id  (from app counter)-- narrows to one measurement run
HTTP-server + runtime + client-pool metrics are per service_instance_id (they
carry no scenario label), so they filter by $service/$instance. The app's own
counters carry scenario_id/perf_run_id, so those panels also honor $scenario/$run.
"""

import json
import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))

# --- Datasource handles provisioned by grafana/otel-lgtm ---
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
TEMPO = {"type": "tempo", "uid": "tempo"}

# ---------------------------------------------------------------------------
# Lab descriptors -- mirror labs/<lab>/lab.config.sh. Onboard a new lab's
# dashboards by adding an entry here (config-only, matching the harness ethos).
# ---------------------------------------------------------------------------
LABS = {
    "scenariolab": {
        "human": "Scenario Lab",
        "app": "perflab",                 # PERFLAB_APP_METRIC_PREFIX (default)
        "service_regex": "perflab-.*",    # PERFLAB_SERVICE_NAME_REGEX
        "uid": "perflab",
        "worker": True,
        "deps": ["postgres", "redis", "rabbitmq"],
        "kind": "scenariolab",
    },
    "ecommerce": {
        "human": "eCommerce Lab",
        "app": "ecommerce",
        "service_regex": "ecommerce-.*",
        "uid": "ecommerce",
        "worker": False,
        "deps": ["postgres"],
        "kind": "ecommerce",
    },
}

# Scope fragments reused everywhere.
SVC = 'service_name=~"$service"'
INST = 'service_instance_id=~"$instance"'
SVC_INST = f'{SVC},{INST}'
# App-metric panels also honour scenario/run (those labels exist on app counters).
APP_SCOPE = f'{SVC},scenario_id=~"$scenario",perf_run_id=~"$run"'
RI = "$__rate_interval"


# ---------------------------------------------------------------------------
# Low-level panel builders
# ---------------------------------------------------------------------------
def target(expr, legend=None, ref="A", datasource=PROM, exemplar=False, instant=False):
    t = {"datasource": datasource, "expr": expr, "refId": ref}
    if legend is not None:
        t["legendFormat"] = legend
    if exemplar:
        t["exemplar"] = True
    if instant:
        t["instant"] = True
    return t


def _base(pid, title, gp, ptype, datasource=PROM, desc=None):
    p = {
        "id": pid,
        "title": title,
        "type": ptype,
        "datasource": datasource,
        "gridPos": gp,
    }
    if desc:
        p["description"] = desc
    return p


def seq_refids(targets):
    """Give every target in a panel a UNIQUE refId (A, B, C, ...). Grafana keys
    query result frames by refId and collapses duplicates, so two targets sharing
    refId "A" silently drop a series (or the whole panel to No-data). Every
    multi-query panel must therefore hand out distinct refIds."""
    for i, t in enumerate(targets):
        t["refId"] = chr(ord("A") + i)
    return targets


def timeseries(pid, title, gp, targets, unit="short", desc=None, minv=None,
               stacking=False, fill=8, thresholds=None, decimals=None, legend_table=False,
               series_units=None):
    p = _base(pid, title, gp, "timeseries", desc=desc)
    custom = {
        "drawStyle": "line",
        "lineInterpolation": "smooth",
        "fillOpacity": fill,
        "showPoints": "never",
        "lineWidth": 2,
        "spanNulls": True,
    }
    if stacking:
        custom["stacking"] = {"mode": "normal", "group": "A"}
    defaults = {"unit": unit, "custom": custom}
    if minv is not None:
        defaults["min"] = minv
    if decimals is not None:
        defaults["decimals"] = decimals
    if thresholds:
        defaults["thresholds"] = {"mode": "absolute", "steps": thresholds}
        custom["thresholdsStyle"] = {"mode": "dashed"}
    # Per-series unit + axis overrides: when a panel legitimately carries series of
    # different units (e.g. bytes alongside a ratio), each odd series gets its own
    # unit and a right-hand axis so neither is rendered on a meaningless scale.
    overrides = []
    for su in (series_units or []):
        props = [{"id": "unit", "value": su["unit"]}]
        if su.get("axis") == "right":
            props.append({"id": "custom.axisPlacement", "value": "right"})
        if su.get("label"):
            props.append({"id": "custom.axisLabel", "value": su["label"]})
        overrides.append({"matcher": {"id": "byFrameRefID", "options": su["ref"]}, "properties": props})
    p["fieldConfig"] = {"defaults": defaults, "overrides": overrides}
    opts = {"tooltip": {"mode": "multi", "sort": "desc"},
            "legend": {"displayMode": "table" if legend_table else "list",
                       "placement": "bottom",
                       "calcs": ["lastNotNull", "max"] if legend_table else []}}
    p["options"] = opts
    p["targets"] = seq_refids(targets)
    return p


def stat(pid, title, gp, expr, unit="short", thresholds=None, desc=None,
         decimals=None, color_mode="value", graph=True, reducer="lastNotNull"):
    p = _base(pid, title, gp, "stat", desc=desc)
    steps = thresholds or [{"color": "text", "value": None}]
    defaults = {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps},
                "color": {"mode": "thresholds"}}
    if decimals is not None:
        defaults["decimals"] = decimals
    p["fieldConfig"] = {"defaults": defaults, "overrides": []}
    p["options"] = {
        "colorMode": color_mode,
        "graphMode": "area" if graph else "none",
        "justifyMode": "auto",
        "textMode": "auto",
        "reduceOptions": {"calcs": [reducer], "fields": "", "values": False},
    }
    p["targets"] = [target(expr)]
    return p


def heatmap(pid, title, gp, expr, unit="s", desc=None):
    p = _base(pid, title, gp, "heatmap", desc=desc)
    p["targets"] = [dict(target(expr, ref="A"), **{"format": "heatmap"})]
    p["options"] = {
        "calculate": False,
        "cellGap": 1,
        "color": {"scheme": "Spectral", "mode": "scheme", "steps": 64, "reverse": True},
        "yAxis": {"unit": unit},
        "tooltip": {"show": True, "yHistogram": True},
        "legend": {"show": True},
    }
    p["fieldConfig"] = {"defaults": {"custom": {"hideFrom": {"tooltip": False, "viz": False, "legend": False}}}, "overrides": []}
    return p


def table(pid, title, gp, targets, desc=None, overrides=None, join_field=None, sort_by=None):
    p = _base(pid, title, gp, "table", desc=desc)
    for t in targets:
        t["format"] = "table"
        t["instant"] = True
    p["targets"] = targets  # named unique refIds are set by the caller (referenced in overrides)
    p["options"] = {"showHeader": True, "footer": {"show": False},
                    "sortBy": sort_by or [{"displayName": "Value", "desc": True}]}
    p["fieldConfig"] = {"defaults": {"custom": {"align": "auto", "filterable": True}},
                        "overrides": overrides or []}
    # Each instant query returns its own frame (join_field + Value #<refId>). Without
    # a join, the table shows only ONE frame's columns; joinByField merges every
    # frame into a single row per key so all metric columns appear side by side.
    tr = []
    if join_field:
        tr.append({"id": "joinByField", "options": {"byField": join_field, "mode": "outer"}})
    tr.append({"id": "organize", "options": {"excludeByName": {"Time": True, "job": True, "instance": True}}})
    p["transformations"] = tr
    return p


def logs(pid, title, gp, expr, desc=None):
    p = _base(pid, title, gp, "logs", datasource=LOKI, desc=desc)
    p["targets"] = [{"datasource": LOKI, "expr": expr, "queryType": "range", "refId": "A"}]
    p["options"] = {"dedupStrategy": "none", "enableLogDetails": True, "showTime": True,
                    "sortOrder": "Descending", "wrapLogMessage": True, "showLabels": False,
                    "showCommonLabels": False}
    return p


def traces(pid, title, gp, query, desc=None):
    p = _base(pid, title, gp, "table", datasource=TEMPO, desc=desc)
    p["targets"] = [{"datasource": TEMPO, "queryType": "traceql", "query": query,
                     "limit": 20, "tableType": "traces", "refId": "A"}]
    p["fieldConfig"] = {"defaults": {}, "overrides": []}
    p["options"] = {"showHeader": True}
    return p


def row(pid, title, y, collapsed=False):
    return {"id": pid, "title": title, "type": "row", "collapsed": collapsed,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


# ---------------------------------------------------------------------------
# Layout helper -- flow (panel, w, h) tuples left-to-right, wrapping at 24 cols.
# Rows (h==1,w==24) force a new line. Returns the assembled panel list.
# ---------------------------------------------------------------------------
class Grid:
    def __init__(self):
        self.panels = []
        self.x = 0
        self.y = 0
        self.rowh = 0
        self._id = 100

    def nid(self):
        self._id += 1
        return self._id

    def newline(self):
        if self.x != 0:
            self.y += self.rowh
            self.x = 0
            self.rowh = 0

    def add_row(self, title):
        self.newline()
        self.panels.append(row(self.nid(), title, self.y))
        self.y += 1

    def place(self, panel, w, h):
        if self.x + w > 24:
            self.newline()
        panel["gridPos"] = {"h": h, "w": w, "x": self.x, "y": self.y}
        if "id" not in panel or panel["id"] is None:
            panel["id"] = self.nid()
        self.panels.append(panel)
        self.x += w
        self.rowh = max(self.rowh, h)
        return panel


# ---------------------------------------------------------------------------
# Template variables + dashboard envelope
# ---------------------------------------------------------------------------
def templating(app, service_regex):
    def q(name, label, expr, regex=None, allv=True, default_all=True):
        v = {
            "name": name, "label": label, "type": "query", "datasource": PROM,
            "definition": expr, "query": {"query": expr, "refId": f"var-{name}"},
            # refresh=1 ("on dashboard load"), NOT 2 ("on time-range change"): with a
            # relative window + 5s auto-refresh, refresh=2 re-queries the variables on
            # every tick, which blanks every dependent panel during re-resolution
            # (constant flicker). Panels still refresh their own data every 5s; only the
            # variable value lists are frozen at load (reload to pick up a brand-new run).
            "refresh": 1, "includeAll": allv, "multi": True, "sort": 1,
        }
        if regex:
            v["regex"] = regex
        if allv and default_all:
            v["current"] = {"text": ["All"], "value": ["$__all"]}
        return v

    # Source each variable from a metric EVERY relevant series carries, not from
    # the scenario-execution counter -- that counter is only emitted by a subset of
    # scenarios (catalog/cache/runtime) and never by the worker, so sourcing from it
    # left Instance/Scenario/Run empty for orders/pool/deadlock scenarios and blanked
    # every variable-filtered panel. Instead:
    #   instance  <- dotnet_process_memory_working_set_bytes (every .NET process emits it: api AND worker, all scenarios)
    #   scenario/run <- any app metric carrying the label ({__name__=~"<app>_.*"}), so all scenarios contribute
    return {"list": [
        q("service", "Service", "label_values(service_name)", regex=f"/{service_regex}/"),
        q("instance", "Instance",
          'label_values(dotnet_process_memory_working_set_bytes{service_name=~"$service"}, service_instance_id)'),
        q("scenario", "Scenario", f'label_values({{__name__=~"{app}_.*",scenario_id!=""}}, scenario_id)'),
        q("run", "Run", f'label_values({{__name__=~"{app}_.*",perf_run_id!=""}}, perf_run_id)'),
    ]}


def dashboard(uid, title, panels, tv, tags):
    return {
        "annotations": {"list": [{
            "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
            "enable": True, "hide": True, "type": "dashboard",
            "name": "Annotations & Alerts", "iconColor": "rgba(0, 211, 255, 1)"}]},
        "editable": True,
        "fiscalYearStartMonth": 0,
        "graphTooltip": 1,
        "links": [{"title": "Lab dashboards", "type": "dashboards", "tags": tags,
                   "asDropdown": True, "includeVars": True, "keepTime": True,
                   "targetBlank": False, "icon": "external link"}],
        "liveNow": False,
        "panels": panels,
        "refresh": "5s",
        "schemaVersion": 41,
        "tags": tags,
        "templating": tv,
        "time": {"from": "now-15m", "to": "now"},
        "timezone": "browser",
        "title": title,
        "uid": uid,
        # No hardcoded "version": Grafana's file provisioner keeps the dashboard with
        # the HIGHEST version, so a constant version made every regeneration a no-op on
        # an already-provisioned instance (file v1 <= stored v2 -> skipped, dashboards
        # stayed stale until a manual reload). Omitting it lets Grafana version by
        # checksum, so a regenerated file reloads within the provider's poll interval.
    }


# ---------------------------------------------------------------------------
# Shared PromQL fragments
# ---------------------------------------------------------------------------
def rate_sum(metric, scope, by=None, extra="", iv=RI):
    grp = f" by ({by})" if by else ""
    return f'sum{grp}(rate({metric}{{{scope}{extra}}}[{iv}]))'


def quantile(q, metric_bucket, scope, by=None, extra="", iv=RI):
    grp = f"le,{by}" if by else "le"
    return f'histogram_quantile({q}, sum by ({grp})(rate({metric_bucket}{{{scope}{extra}}}[{iv}])))'


# ===========================================================================
# Dashboard 00 -- Overview: golden signals & SLOs (home)
# ===========================================================================
def build_overview(s):
    app, g = s["app"], Grid()
    reqcount = "http_server_request_duration_seconds_count"
    reqbucket = "http_server_request_duration_seconds_bucket"
    # non-health server scope (exclude readiness/liveness noise)
    ns = f'{SVC_INST},http_route!~"/health.*|"'

    g.add_row("Service level indicators (server-side, live)")
    g.place(stat(None, "Throughput", {}, rate_sum(reqcount, ns),
                 unit="reqps", decimals=1, color_mode="value",
                 thresholds=[{"color": "text", "value": None}],
                 desc="Requests/s completed by the server (health probes excluded)."), 4, 4)
    g.place(stat(None, "Error rate", {},
                 f'({rate_sum(reqcount, ns, extra=",http_response_status_code=~\"5..\"")} or vector(0)) '
                 f'/ clamp_min({rate_sum(reqcount, ns)}, 1)',
                 unit="percentunit", decimals=2, color_mode="background",
                 thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 0.01}, {"color": "red", "value": 0.05}],
                 desc="Share of 5xx responses. Green <1%, red >=5%."), 4, 4)
    g.place(stat(None, "p95 latency", {}, quantile("0.95", reqbucket, ns),
                 unit="s", decimals=3, color_mode="value",
                 thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 0.25}, {"color": "red", "value": 1}]), 4, 4)
    g.place(stat(None, "p99 latency", {}, quantile("0.99", reqbucket, ns),
                 unit="s", decimals=3, color_mode="value",
                 thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 0.5}, {"color": "red", "value": 2}]), 4, 4)
    g.place(stat(None, "In-flight", {}, f'sum(http_server_active_requests{{{SVC_INST}}})',
                 unit="short", desc="Concurrent requests currently executing on the server."), 4, 4)
    g.place(stat(None, "CPU (cores)", {}, rate_sum("dotnet_process_cpu_time_seconds_total", SVC_INST),
                 unit="short", decimals=2, color_mode="value",
                 thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 0.8}, {"color": "red", "value": 1}],
                 desc="CPU seconds/s = cores consumed. api is limited to 1.0 core."), 4, 4)

    g.add_row("Golden signals over time")
    g.place(timeseries(None, "Throughput by route", {},
                       [target(rate_sum(reqcount, ns, by="http_route"), "{{http_route}}")],
                       unit="reqps", minv=0, legend_table=True), 12, 8)
    g.place(timeseries(None, "Latency percentiles (server)", {},
                       [target(quantile("0.50", reqbucket, ns), "p50", "A", exemplar=True),
                        target(quantile("0.90", reqbucket, ns), "p90", "B"),
                        target(quantile("0.95", reqbucket, ns), "p95", "C", exemplar=True),
                        target(quantile("0.99", reqbucket, ns), "p99", "D", exemplar=True)],
                       unit="s", minv=0), 12, 8)

    g.place(timeseries(None, "Responses by status class", {},
                       [target(rate_sum(reqcount, ns, by="http_response_status_code"), "{{http_response_status_code}}")],
                       unit="reqps", minv=0, stacking=True, fill=25, legend_table=True,
                       desc="Stacked response rate by HTTP status code."), 8, 8)
    g.place(timeseries(None, "Error rate % (5xx)", {},
                       [target(f'({rate_sum(reqcount, ns, extra=",http_response_status_code=~\"5..\"")} or vector(0)) '
                               f'/ clamp_min({rate_sum(reqcount, ns)}, 1)', "5xx error rate")],
                       unit="percentunit", minv=0,
                       thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 0.05}]), 8, 8)
    g.place(heatmap(None, "Latency distribution (heatmap)", {},
                    f'sum by (le)(rate({reqbucket}{{{ns}}}[{RI}]))', unit="s",
                    desc="Server request-duration histogram over time; spots multi-modal tails."), 8, 8)

    # Client-side (k6 remote-write) SLO row. The `run` label on k6 series equals
    # PERF_RUN_ID, which is the same value as the app's perf_run_id -> $run filters
    # both sources coherently. Populated only when PERFLAB_K6_PROM_RW is enabled
    # (default on when Prometheus is reachable; see harness/adapters/loadgen/k6/run.sh).
    g.add_row("Client-observed SLOs (k6 remote-write — the true stakeholder view)")
    k6r = 'run=~"$run"'
    g.place(timeseries(None, "Client throughput (k6)", {},
                       [target(f'sum(rate(k6_http_reqs_total{{{k6r}}}[{RI}]))', "requests/s")],
                       unit="reqps", minv=0,
                       desc="Throughput as measured BY THE LOAD GENERATOR (includes client-side queueing). "
                            "Compare with server throughput above -- a gap means requests are queued before the server sees them."), 8, 8)
    g.place(timeseries(None, "Client latency p95 / p99 (k6)", {},
                       [target(f'max(k6_http_req_duration_p95{{{k6r}}})', "p95"),
                        target(f'max(k6_http_req_duration_p99{{{k6r}}})', "p99")],
                       unit="s", minv=0,
                       desc="End-to-end latency incl. network + connection wait. k6 remote-write stores trend "
                            "durations in SECONDS (Grafana auto-scales to ms). Divergence above server p95 exposes client/queueing overhead."), 8, 8)
    g.place(timeseries(None, "Client error rate (k6)", {},
                       [target(f'max(k6_http_req_failed_rate{{{k6r}}})', "failed fraction")],
                       unit="percentunit", minv=0,
                       thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 0.05}],
                       desc="k6 http_req_failed fraction (HTTP >=400 or a transport error)."), 8, 8)

    g.add_row("Correlated logs")
    g.place(logs(None, "Application errors & warnings", {},
                 '{service_name=~"$service"} |~ "(?i)(error|warn|fail|exception)"',
                 desc="Loki-backed. Click a line for trace correlation (trace_id → Tempo)."), 24, 9)

    tv = templating(app, s["service_regex"])
    return f"00-overview.json", dashboard(f'{s["uid"]}-overview',
                                          f'{s["human"]} · Overview & SLOs', g.panels, tv,
                                          ["perflab", s["uid"], "overview"])


# ===========================================================================
# Dashboard 10 -- .NET runtime: GC / threads / exceptions
# ===========================================================================
def build_runtime(s):
    app, g = s["app"], Grid()

    g.add_row("Memory")
    g.place(timeseries(None, "Working set vs managed heap vs committed", {},
                       [target(f'dotnet_process_memory_working_set_bytes{{{SVC_INST}}}', "working set {{service_name}}"),
                        target(f'sum by (service_name)(dotnet_gc_last_collection_heap_size_bytes{{{SVC_INST}}})', "managed heap {{service_name}}"),
                        target(f'sum by (service_name)(dotnet_gc_last_collection_memory_committed_size_bytes{{{SVC_INST}}})', "GC committed {{service_name}}")],
                       unit="bytes", minv=0,
                       desc="api mem_limit is 768 MiB; GCHeapHardLimitPercent caps managed heap. Watch working set vs limit."), 12, 8)
    g.place(timeseries(None, "Managed heap by generation", {},
                       [target(f'sum by (gc_heap_generation)(dotnet_gc_last_collection_heap_size_bytes{{{SVC_INST}}})', "{{gc_heap_generation}}")],
                       unit="bytes", minv=0, stacking=True, fill=25, legend_table=True,
                       desc="gen0/gen1/gen2/loh/poh. Rising gen2/loh = long-lived or large-object pressure."), 12, 8)

    g.add_row("Garbage collector")
    g.place(timeseries(None, "Allocation rate", {},
                       [target(rate_sum("dotnet_gc_heap_allocated_bytes_total", SVC_INST, by="service_name"), "{{service_name}}")],
                       unit="Bps", minv=0,
                       desc="Bytes allocated/s -- the primary driver of GC frequency and CPU in most .NET hotspots."), 8, 8)
    g.place(timeseries(None, "% time paused in GC", {},
                       [target(rate_sum("dotnet_gc_pause_time_seconds_total", SVC_INST, by="service_name"), "{{service_name}}")],
                       unit="percentunit", minv=0,
                       thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 0.05}, {"color": "red", "value": 0.2}],
                       desc="GC pause-seconds per second. >5% steals latency; >20% is a GC-bound workload."), 8, 8)
    g.place(timeseries(None, "GC collections/s by generation", {},
                       [target(rate_sum("dotnet_gc_collections_total", SVC_INST, by="gc_heap_generation"), "gen {{gc_heap_generation}}")],
                       unit="ops", minv=0, legend_table=True,
                       desc="Gen2 collections are the expensive ones; a rising gen2 rate is the classic churn signal."), 8, 8)

    g.add_row("Threads & scheduling")
    g.place(timeseries(None, "Thread pool: threads vs queue", {},
                       [target(f'dotnet_thread_pool_thread_count_total{{{SVC_INST}}}', "threads {{service_name}}"),
                        target(f'dotnet_thread_pool_queue_length_total{{{SVC_INST}}}', "queue {{service_name}}")],
                       unit="short", minv=0,
                       desc="A persistently non-zero queue = thread-pool starvation (blocking on the pool)."), 8, 8)
    g.place(timeseries(None, "Thread pool: completed work items/s", {},
                       [target(rate_sum("dotnet_thread_pool_work_item_count_total", SVC_INST, by="service_name"), "{{service_name}}")],
                       unit="ops", minv=0,
                       desc="Requires dotnet_thread_pool_work_item_count_total (runtime instrumentation)."), 8, 8)
    g.place(timeseries(None, "Lock contention/s", {},
                       [target(rate_sum("dotnet_monitor_lock_contentions_total", SVC_INST, by="service_name"), "{{service_name}}")],
                       unit="ops", minv=0,
                       desc="Monitor contention events/s. Spikes point at a hot lock serializing requests."), 8, 8)

    g.add_row("CPU & exceptions")
    g.place(timeseries(None, "CPU by mode (cores)", {},
                       [target(f'sum by (cpu_mode)(rate(dotnet_process_cpu_time_seconds_total{{{SVC_INST}}}[{RI}]))', "{{cpu_mode}}")],
                       unit="short", minv=0, stacking=True, fill=25,
                       desc="user vs system cores. High system time hints at syscalls / GC / context switching."), 8, 8)
    g.place(timeseries(None, "Exceptions thrown/s", {},
                       [target(rate_sum("dotnet_exceptions_total", SVC_INST, by="error_type"), "{{error_type}}")],
                       unit="ops", minv=0, legend_table=True,
                       desc="Throw rate by type. Exceptions on the hot path are a common hidden cost."), 8, 8)
    g.place(timeseries(None, "JIT & assemblies", {},
                       [target(f'dotnet_jit_compiled_methods_total{{{SVC_INST}}}', "compiled methods {{service_name}}"),
                        target(f'dotnet_assembly_count{{{SVC_INST}}}', "assemblies {{service_name}}")],
                       unit="short", minv=0,
                       desc="Flat after warm-up; late growth = runtime codegen / dynamic loading."), 8, 8)

    # Per-request efficiency: resource use normalised by throughput. Mirrors the
    # efficiency.* facts capture-evidence.sh writes, so the boards and facts.json
    # agree. Catches the regression absolute latency hides: same p95, more work.
    g.add_row("Efficiency (per request)")
    reqrate = f'sum(rate(http_server_request_duration_seconds_count{{{SVC_INST},http_route!~"/health.*|"}}[{RI}]))'
    # Guard against divide-by-~0 at idle: `... / reqrate and (reqrate > 0.5)` yields
    # a value only when the request rate is meaningful, otherwise the series is
    # hidden. (clamp_min(reqrate,1e-9) instead produced billions/trillions at idle.)
    def per_req(numer):
        return f'{numer} / {reqrate} and ({reqrate} > 0.5)'
    g.place(timeseries(None, "CPU-ms per request", {},
                       [target(per_req(f'1000 * sum(rate(dotnet_process_cpu_time_seconds_total{{{SVC_INST}}}[{RI}]))'), "cpu ms/req")],
                       unit="ms", minv=0,
                       desc="CPU-milliseconds spent per served request -- rises when a change does more work per request even if latency holds. Hidden when idle."), 8, 8)
    g.place(timeseries(None, "Allocated bytes per request", {},
                       [target(per_req(f'sum(rate(dotnet_gc_heap_allocated_bytes_total{{{SVC_INST}}}[{RI}]))'), "bytes/req")],
                       unit="bytes", minv=0,
                       desc="Managed bytes allocated per request -- the driver of GC frequency, and a classic hidden regression. Hidden when idle."), 8, 8)
    g.place(timeseries(None, "GC-pause + dependency ms per request", {},
                       [target(per_req(f'1000 * sum(rate(dotnet_gc_pause_time_seconds_total{{{SVC_INST}}}[{RI}]))'), "gc pause ms/req"),
                        target(per_req(f'1000 * sum(rate(db_client_operation_duration_seconds_sum{{{SVC_INST}}}[{RI}]))'), "db ms/req")],
                       unit="ms", minv=0,
                       desc="Per-request GC-pause time and DB dependency time -- where the per-request cost actually goes. Hidden when idle."), 8, 8)

    tv = templating(app, s["service_regex"])
    return "10-runtime.json", dashboard(f'{s["uid"]}-runtime',
                                        f'{s["human"]} · .NET Runtime & GC', g.panels, tv,
                                        ["perflab", s["uid"], "runtime"])


# ===========================================================================
# Dashboard 20 -- HTTP & endpoints (RED per route)
# ===========================================================================
def build_http(s):
    app, g = s["app"], Grid()
    c = "http_server_request_duration_seconds_count"
    b = "http_server_request_duration_seconds_bucket"
    ns = f'{SVC_INST},http_route!~"/health.*|"'

    g.add_row("Per-route RED")
    g.place(timeseries(None, "Requests/s by route", {},
                       [target(rate_sum(c, ns, by="http_route"), "{{http_route}}")],
                       unit="reqps", minv=0, legend_table=True), 12, 8)
    g.place(timeseries(None, "p99 latency by route", {},
                       [target(quantile("0.99", b, ns, by="http_route"), "{{http_route}}")],
                       unit="s", minv=0, legend_table=True,
                       desc="Which endpoint owns the tail."), 12, 8)

    # Zero-filled per route (`4xx/5xx-rate or all-rate*0`) so a clean run shows a flat
    # 0 line per route instead of "No data" -- an error SLO reads 0 when healthy.
    errs = (f'{rate_sum(c, ns, by="http_route", extra=chr(44)+"http_response_status_code=~\"4..|5..\"")} '
            f'or ({rate_sum(c, ns, by="http_route")} * 0)')
    g.place(timeseries(None, "Errors/s by route (4xx+5xx)", {},
                       [target(errs, "{{http_route}}")],
                       unit="reqps", minv=0, legend_table=True,
                       desc="Zero-filled per route: a healthy run shows 0, not No-data."), 12, 8)
    g.place(timeseries(None, "5xx by exception type", {},
                       [target(rate_sum(c, ns, by="error_type", extra=',error_type!=""'), "{{error_type}}")],
                       unit="reqps", minv=0, legend_table=True,
                       desc="error_type is the CLR exception surfaced by ASP.NET Core instrumentation."), 12, 8)

    g.add_row("Concurrency & connections")
    g.place(timeseries(None, "In-flight requests", {},
                       [target(f'sum by (service_name)(http_server_active_requests{{{SVC_INST}}})', "{{service_name}}")],
                       unit="short", minv=0), 8, 8)
    g.place(timeseries(None, "Kestrel connections", {},
                       [target(f'sum by (service_name)(kestrel_active_connections{{{SVC_INST}}})', "active {{service_name}}"),
                        target(f'sum by (service_name)(kestrel_queued_connections{{{SVC_INST}}})', "queued {{service_name}}")],
                       unit="short", minv=0,
                       desc="Queued connections rising = accept-loop can't keep up."), 8, 8)
    g.place(timeseries(None, "Request method mix", {},
                       [target(rate_sum(c, ns, by="http_request_method"), "{{http_request_method}}")],
                       unit="reqps", minv=0, stacking=True, fill=25), 8, 8)

    g.add_row("Route breakdown (current window)")
    ov = [
        {"matcher": {"id": "byName", "options": "http_route"}, "properties": [{"id": "custom.width", "value": 260}]},
        {"matcher": {"id": "byName", "options": "Value #reqs"}, "properties": [{"id": "displayName", "value": "req/s"}, {"id": "unit", "value": "reqps"}, {"id": "decimals", "value": 2}]},
        {"matcher": {"id": "byName", "options": "Value #p95"}, "properties": [{"id": "displayName", "value": "p95"}, {"id": "unit", "value": "s"}, {"id": "decimals", "value": 3}]},
        {"matcher": {"id": "byName", "options": "Value #p99"}, "properties": [{"id": "displayName", "value": "p99"}, {"id": "unit", "value": "s"}, {"id": "decimals", "value": 3}]},
        {"matcher": {"id": "byName", "options": "Value #err"}, "properties": [{"id": "displayName", "value": "err/s"}, {"id": "unit", "value": "reqps"}, {"id": "decimals", "value": 3}]},
    ]
    # The table summarises the WHOLE dashboard window, so every rate/quantile is
    # computed over $__range (not $__rate_interval): an instant rate[$__rate_interval]
    # reads 0 req/s and NaN p95/p99 the moment traffic goes idle, even though the
    # window contains traffic. The error column is zero-filled per route
    # (`5xx-rate or all-rate*0`) so it shows 0 for routes with traffic but no 5xx,
    # instead of the whole err/s column vanishing when no 5xx series exists.
    err = (f'{rate_sum(c, ns, by="http_route", extra=chr(44)+"http_response_status_code=~\"5..\"", iv="$__range")} '
           f'or ({rate_sum(c, ns, by="http_route", iv="$__range")} * 0)')
    g.place(table(None, "Top routes by throughput / latency / errors (over window)", {},
                  [target(rate_sum(c, ns, by="http_route", iv="$__range"), ref="reqs"),
                   target(quantile("0.95", b, ns, by="http_route", iv="$__range"), ref="p95"),
                   target(quantile("0.99", b, ns, by="http_route", iv="$__range"), ref="p99"),
                   target(err, ref="err")],
                  overrides=ov, join_field="http_route",
                  sort_by=[{"displayName": "p99", "desc": True}],
                  desc="Averaged over the dashboard window ($__range), so idle-at-now doesn't blank it. "
                       "err/s zero-filled per route. Sortable/filterable; joined by route."), 24, 9)

    tv = templating(app, s["service_regex"])
    return "20-http.json", dashboard(f'{s["uid"]}-http',
                                     f'{s["human"]} · HTTP & Endpoints', g.panels, tv,
                                     ["perflab", s["uid"], "http"])


# ===========================================================================
# Dashboard 30 -- Dependencies & connection pools (client + server)
# ===========================================================================
def build_dependencies(s):
    app, g = s["app"], Grid()

    # --- Client-side: Npgsql pool (both labs, from OTel db.client.* metrics) ---
    g.add_row("Database connection pool (client-side — Npgsql)")
    g.place(timeseries(None, "Pool connections: used vs idle vs max", {},
                       [target(f'sum by (db_client_connection_state)(db_client_connection_count{{{SVC_INST}}})', "{{db_client_connection_state}}"),
                        target(f'max(db_client_connection_max{{{SVC_INST}}})', "max")],
                       unit="short", minv=0,
                       desc="used approaching max with pending>0 = pool saturation (Maximum Pool Size=20)."), 8, 8)
    g.place(timeseries(None, "Pending connection requests", {},
                       [target(f'sum by (service_name)(db_client_connection_npgsql_pending_requests{{{SVC_INST}}}) or vector(0)', "pending")],
                       unit="short", minv=0,
                       thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                       desc="Requests waiting for a pooled connection (Npgsql omits the metric when the queue is empty, "
                            "so this is zero-filled). Any sustained >0 is the smoking gun for pool starvation."), 8, 8)
    g.place(timeseries(None, "Commands executing + connection create time p95", {},
                       [target(f'sum by (service_name)(db_client_operation_npgsql_executing{{{SVC_INST}}})', "executing {{service_name}}"),
                        target(quantile("0.95", "db_client_connection_npgsql_create_time_seconds_bucket", SVC_INST), "create p95")],
                       unit="short", minv=0,
                       series_units=[{"ref": "B", "unit": "s", "axis": "right", "label": "create p95"}],
                       desc="create p95 (right axis, seconds) spiking = pool churn (connections opened under load, not reused)."), 8, 8)

    # --- Client-side: HTTP client pool (both; primarily exercised by scenariolab S25/S26) ---
    g.add_row("Outbound HTTP client pool (System.Net.Http)")
    g.place(timeseries(None, "Open connections by state", {},
                       [target(f'sum by (http_connection_state)(http_client_open_connections{{{SVC_INST}}})', "{{http_connection_state}}")],
                       unit="short", minv=0,
                       desc="SocketsHttpHandler pool. idle vs active split; low ceiling + queueing = MaxConnectionsPerServer too small."), 8, 8)
    g.place(timeseries(None, "Time waiting for a connection (p95)", {},
                       [target(quantile("0.95", "http_client_request_time_in_queue_seconds_bucket", SVC_INST), "queue p95")],
                       unit="s", minv=0,
                       thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 0.05}, {"color": "red", "value": 0.25}],
                       desc="Time a request waited for a free pooled connection. Non-zero = outbound pool saturation."), 8, 8)
    g.place(timeseries(None, "Outbound request duration p95 + active", {},
                       [target(quantile("0.95", "http_client_request_duration_seconds_bucket", SVC_INST), "duration p95"),
                        target(f'sum by (service_name)(http_client_active_requests{{{SVC_INST}}})', "active")],
                       unit="s", minv=0,
                       series_units=[{"ref": "B", "unit": "short", "axis": "right", "label": "active requests"}]), 8, 8)

    # --- Server-side (live exporters via the collector overlay) ---
    if "postgres" in s["deps"]:
        g.add_row("PostgreSQL server (postgres_exporter — live when the observability profile is up)")
        pg = 'datname=~"perflab|ecommerce"'
        g.place(timeseries(None, "Backends (server connections)", {},
                           [target(f'sum(pg_stat_activity_count{{{pg}}}) or sum(pg_stat_database_numbackends{{{pg}}})', "backends"),
                            target('pg_settings_max_connections', "max_connections")],
                           unit="short", minv=0,
                           desc="Server-side connection count -- compare against the client pool above."), 8, 8)
        g.place(timeseries(None, "Transactions/s (commit vs rollback)", {},
                           [target(f'sum(rate(pg_stat_database_xact_commit_total{{{pg}}}[{RI}]))', "commit/s"),
                            target(f'sum(rate(pg_stat_database_xact_rollback_total{{{pg}}}[{RI}]))', "rollback/s")],
                           unit="ops", minv=0), 8, 8)
        g.place(timeseries(None, "Deadlocks/s + temp bytes/s", {},
                           [target(f'sum(rate(pg_stat_database_deadlocks_total{{{pg}}}[{RI}]))', "deadlocks/s"),
                            target(f'sum(rate(pg_stat_database_temp_bytes_total{{{pg}}}[{RI}]))', "temp Bps")],
                           unit="ops", minv=0,
                           series_units=[{"ref": "B", "unit": "Bps", "axis": "right", "label": "temp bytes/s"}],
                           desc="Deadlocks/s validates S27; temp bytes/s (right axis) = spill to disk (sorts/joins exceeding work_mem)."), 8, 8)
        g.place(timeseries(None, "Buffer cache hit ratio", {},
                           [target(f'sum(rate(pg_stat_database_blks_hit_total{{{pg}}}[{RI}])) / clamp_min(sum(rate(pg_stat_database_blks_hit_total{{{pg}}}[{RI}])) + sum(rate(pg_stat_database_blks_read_total{{{pg}}}[{RI}])), 1)', "hit ratio")],
                           unit="percentunit", minv=0,
                           desc="Fraction of block reads served from shared_buffers; sustained dips below ~0.99 mean disk reads."), 8, 8)

    if "redis" in s["deps"]:
        g.add_row("Redis server (redis_exporter — live when the observability profile is up)")
        g.place(timeseries(None, "Ops/s + connected clients", {},
                           [target(f'sum(rate(redis_commands_processed_total[{RI}]))', "commands/s"),
                            target('sum(redis_connected_clients)', "clients"),
                            target('sum(redis_blocked_clients)', "blocked clients")],
                           unit="short", minv=0), 8, 8)
        g.place(timeseries(None, "Keyspace hit ratio", {},
                           [target(f'sum(rate(redis_keyspace_hits_total[{RI}])) / clamp_min(sum(rate(redis_keyspace_hits_total[{RI}])) + sum(rate(redis_keyspace_misses_total[{RI}])), 1)', "hit ratio")],
                           unit="percentunit", minv=0,
                           desc="Server-side view; compare with the app's own perflab_cache_requests hit ratio on the Messaging board."), 8, 8)
        g.place(timeseries(None, "Memory used + evictions/s", {},
                           [target('sum(redis_memory_used_bytes)', "used bytes"),
                            target(f'sum(rate(redis_evicted_keys_total[{RI}]))', "evictions/s")],
                           series_units=[{"ref": "B", "unit": "ops", "axis": "right", "label": "evictions/s"}],
                           unit="bytes", minv=0,
                           desc="maxmemory=256mb, allkeys-lru: evictions/s>0 means the working set exceeds the cache."), 8, 8)

    if "rabbitmq" in s["deps"]:
        g.add_row("RabbitMQ broker (rabbitmq_prometheus — live when the observability profile is up)")
        g.place(timeseries(None, "Queue depth (ready vs unacked)", {},
                           [target('sum(rabbitmq_queue_messages_ready)', "ready"),
                            target('sum(rabbitmq_queue_messages_unacked)', "unacked")],
                           unit="short", minv=0,
                           desc="Ready backlog growing = consumers can't keep up (publish > consume)."), 8, 8)
        g.place(timeseries(None, "Publish vs deliver/s", {},
                           [target(f'sum(rate(rabbitmq_channel_messages_published_total[{RI}]))', "published/s"),
                            target(f'sum(rate(rabbitmq_channel_messages_delivered_total[{RI}]))', "delivered/s")],
                           unit="ops", minv=0), 8, 8)
        g.place(timeseries(None, "Consumers / connections / channels", {},
                           [target('sum(rabbitmq_queue_consumers)', "consumers"),
                            target('rabbitmq_connections', "connections"),
                            target('rabbitmq_channels', "channels")],
                           unit="short", minv=0), 8, 8)

    tv = templating(app, s["service_regex"])
    return "30-dependencies.json", dashboard(f'{s["uid"]}-dependencies',
                                             f'{s["human"]} · Dependencies & Pools', g.panels, tv,
                                             ["perflab", s["uid"], "dependencies"])


# ===========================================================================
# Dashboard 40 -- Messaging & worker (scenariolab only)
# ===========================================================================
def build_messaging(s):
    app, g = s["app"], Grid()
    a = APP_SCOPE

    g.add_row("Order pipeline (app instrumentation)")
    g.place(timeseries(None, "Publish / process / retry per second", {},
                       [target(rate_sum("perflab_orders_published_total", a), "published/s"),
                        target(rate_sum("perflab_orders_processed_total", a), "processed/s"),
                        target(rate_sum("perflab_orders_retried_total", a), "retried/s")],
                       unit="ops", minv=0,
                       desc="published>processed for a sustained period = the worker is falling behind (see broker queue depth)."), 12, 8)
    g.place(timeseries(None, "Order processing duration p95/p99", {},
                       [target(quantile("0.95", "perflab_order_processing_duration_milliseconds_bucket", a), "p95"),
                        target(quantile("0.99", "perflab_order_processing_duration_milliseconds_bucket", a), "p99")],
                       unit="ms", minv=0), 12, 8)

    g.place(stat(None, "Correctness failures (total in window)", {},
                 f'sum(increase(perflab_correctness_failures_total{{{a}}}[$__range])) or vector(0)',
                 unit="short", color_mode="background",
                 thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                 desc="Guards against 'fast but wrong'. Must stay 0 -- any value invalidates a throughput win."), 8, 6)
    g.place(timeseries(None, "Retries/s", {},
                       [target(rate_sum("perflab_orders_retried_total", a), "retried/s")],
                       unit="ops", minv=0), 8, 6)
    g.place(timeseries(None, "Cache hit ratio (app view)", {},
                       [target(f'{rate_sum("perflab_cache_requests_total", a, extra=",cache_result=\"hit\"")} '
                               f'/ clamp_min({rate_sum("perflab_cache_requests_total", a)}, 1)', "hit ratio")],
                       unit="percentunit", minv=0,
                       desc="From perflab_cache_requests{cache_result}. Compare with Redis server-side ratio on Dependencies."), 8, 6)

    g.add_row("Resource-pool lab (S21–S26 — by pool)")
    g.place(timeseries(None, "Pool wait duration p95 by pool", {},
                       [target(quantile("0.95", "perflab_pool_wait_duration_milliseconds_bucket", a, by="pool_name"), "{{pool_name}}")],
                       unit="ms", minv=0,
                       desc="Time blocked acquiring a lease. postgres / redis-multiplexer / http."), 8, 8)
    g.place(timeseries(None, "Active leases by pool", {},
                       [target(f'sum by (pool_name)(perflab_pool_active_leases{{{a}}})', "{{pool_name}}")],
                       unit="short", minv=0,
                       desc="Leases in flight; flat at the configured ceiling under contention."), 8, 8)
    g.place(timeseries(None, "Pool timeouts/s + resources created/s", {},
                       [target(rate_sum("perflab_pool_timeouts_total", a, by="pool_name"), "timeout {{pool_name}}"),
                        target(rate_sum("perflab_pool_resources_created_total", a, by="pool_name"), "created {{pool_name}}")],
                       unit="ops", minv=0,
                       desc="Timeouts>0 = under-sized pool; a high create rate = churn (not reusing resources)."), 8, 8)

    if s["worker"]:
        g.add_row("Worker process health (service_name=perflab-worker)")
        ws = 'service_name="perflab-worker"'
        g.place(timeseries(None, "Worker CPU (cores) & working set", {},
                           [target(f'sum(rate(dotnet_process_cpu_time_seconds_total{{{ws}}}[{RI}]))', "cpu cores"),
                            target(f'dotnet_process_memory_working_set_bytes{{{ws}}}', "working set")],
                           unit="short", minv=0,
                           series_units=[{"ref": "B", "unit": "bytes", "axis": "right", "label": "working set"}],
                           desc="Worker is cpus:0.75 / 512 MiB. CPU cores on the left axis, working-set bytes on the right."), 12, 8)
        g.place(timeseries(None, "Worker allocation rate & GC pause %", {},
                           [target(f'sum(rate(dotnet_gc_heap_allocated_bytes_total{{{ws}}}[{RI}]))', "alloc Bps"),
                            target(f'sum(rate(dotnet_gc_pause_time_seconds_total{{{ws}}}[{RI}]))', "gc pause %")],
                           unit="Bps", minv=0,
                           series_units=[{"ref": "B", "unit": "percentunit", "axis": "right", "label": "% time in GC"}]), 12, 8)

    tv = templating(app, s["service_regex"])
    return "40-messaging.json", dashboard(f'{s["uid"]}-messaging',
                                          f'{s["human"]} · Messaging & Worker', g.panels, tv,
                                          ["perflab", s["uid"], "messaging"])


# ---------------------------------------------------------------------------
def main():
    for lab, s in LABS.items():
        outdir = os.path.join(REPO_ROOT, "labs", lab, "infra", "grafana", "dashboards")
        os.makedirs(outdir, exist_ok=True)
        builders = [build_overview, build_runtime, build_http, build_dependencies]
        if s["kind"] == "scenariolab":
            builders.append(build_messaging)
        written = []
        for b in builders:
            fname, doc = b(s)
            path = os.path.join(outdir, fname)
            with open(path, "w", encoding="utf-8") as f:
                json.dump(doc, f, indent=2)
                f.write("\n")
            written.append(fname)
        print(f"[{lab}] wrote {len(written)} dashboards -> {outdir}")
        for w in written:
            print(f"    {w}")


if __name__ == "__main__":
    main()
