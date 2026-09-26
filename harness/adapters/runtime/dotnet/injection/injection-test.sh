#!/usr/bin/env bash
# D-P1-3/D-P1-8: the deploy-time injection works on an application that knows
# nothing about it. A throwaway ASP.NET Core app is built here with no reference
# to the injection; only DOTNET_STARTUP_HOOKS and
# ASPNETCORE_HOSTINGSTARTUPASSEMBLIES bring it in. The app observes its own
# request span, request-duration metric and log scopes and prints them, so the
# test sees exactly what an OpenTelemetry exporter would receive:
#   - valid baggage: run and phase on the span, the phase on the metric, both
#     in the log scope, and an exact echo from the probe;
#   - hostile baggage: nothing stamped, so it can never become a label;
#   - no injection (both variables empty): the app runs untouched and the probe
#     is absent, which the harness reads as "not advertised".
# Span profiles need the native Pyroscope profiler and are proven in the lab.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "injection-test: $*" >&2; exit 1; }
if ! command -v dotnet >/dev/null 2>&1 || ! dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
  echo "injection-test: SKIPPED -- needs a .NET 10 SDK; the lab image build compiles the injection instead" >&2
  exit 0
fi
command -v curl >/dev/null || fail "curl is required"

work="$(mktemp -d "${TMPDIR:-/tmp}/injection-test.XXXXXX")"
app_pid=""
cleanup() { [[ -n "${app_pid}" ]] && kill "${app_pid}" 2>/dev/null; rm -rf "${work}"; }
trap cleanup EXIT HUP INT TERM

# Build a copy: an in-tree build leaves bin/ and obj/ in the harness, which the
# independence scan reads.
mkdir -p "${work}/src"
cp "${here}"/PerfLab.DotNet.Injection.csproj "${here}"/*.cs "${work}/src/"
dotnet publish "${work}/src/PerfLab.DotNet.Injection.csproj" -c Release -o "${work}/injection" -nologo -v q \
  > "${work}/publish.log" 2>&1 || { cat "${work}/publish.log" >&2; fail "the injection did not build"; }

mkdir -p "${work}/app"
cat > "${work}/app/app.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
</Project>
EOF
cat > "${work}/app/Program.cs" <<'EOF'
using System.Diagnostics;
using System.Diagnostics.Metrics;
using var spans = new ActivityListener
{
    ShouldListenTo = s => s.Name == "Microsoft.AspNetCore",
    Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllDataAndRecorded,
    ActivityStopped = a => Console.WriteLine($"SPAN run={a.GetTagItem("perf.run.id")} phase={a.GetTagItem("perf.phase")}"),
};
ActivitySource.AddActivityListener(spans);
using var meters = new MeterListener
{
    InstrumentPublished = (i, l) => { if (i.Name == "http.server.request.duration") l.EnableMeasurementEvents(i); },
};
meters.SetMeasurementEventCallback<double>((i, v, tags, _) =>
{
    var phase = "none";
    foreach (var t in tags) if (t.Key == "perf.phase") phase = t.Value?.ToString() ?? "null";
    Console.WriteLine($"METRIC phase={phase}");
});
meters.Start();
var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(o => o.IncludeScopes = true);
var app = builder.Build();
app.MapGet("/work", (ILogger<Program> log) => { log.LogWarning("handled work"); return "ok"; });
app.Run(Environment.GetEnvironmentVariable("INJECTION_TEST_URL")!);
EOF
dotnet build "${work}/app/app.csproj" -c Release -o "${work}/app/out" -nologo -v q > "${work}/build.log" 2>&1 \
  || { cat "${work}/build.log" >&2; fail "the throwaway app did not build"; }

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
url="http://127.0.0.1:${port}"
start_app() { # <startup-hook> <hosting-startup> <log>
  DOTNET_STARTUP_HOOKS="$1" ASPNETCORE_HOSTINGSTARTUPASSEMBLIES="$2" INJECTION_TEST_URL="${url}" \
    dotnet "${work}/app/out/app.dll" > "$3" 2>&1 &
  app_pid=$!
  for _ in $(seq 1 60); do curl -fsS -o /dev/null "${url}/work" 2>/dev/null && return 0; sleep 0.25; done
  cat "$3" >&2; fail "the app did not start"
}
stop_app() { kill "${app_pid}" 2>/dev/null || true; wait "${app_pid}" 2>/dev/null || true; app_pid=""; }

log="${work}/injected.log"
start_app "${work}/injection/PerfLab.DotNet.Injection.dll" PerfLab.DotNet.Injection "${log}"
probe="$(curl -fsS -H 'baggage: perf.run.id=run-42,perf.phase=measure,other=ignored' "${url}/perf/baggage")"
[[ "${probe}" == '{"contractVersion":"perflab-baggage-v1","runId":"run-42","phase":"measure","source":"injected"}' ]] \
  || fail "the probe did not echo exactly the validated run and phase: ${probe}"
[[ "$(curl -s -o /dev/null -w '%{http_code}' "${url}/perf/baggage")" == 400 ]] || fail "the probe accepted a request without baggage"
curl -fsS -H 'baggage: perf.run.id=run-42,perf.phase=measure' "${url}/work" >/dev/null
curl -fsS -H 'baggage: perf.run.id=bad%20value!,perf.phase=hacked' "${url}/work" >/dev/null
sleep 1
stop_app
grep -q 'SPAN run=run-42 phase=measure' "${log}" || fail "the request span did not carry the run and phase: $(grep SPAN "${log}")"
grep -q 'METRIC phase=measure' "${log}" || fail "the request-duration metric did not carry the phase"
grep 'handled work' "${log}" | grep -q '"perf.run.id":"run-42","perf.phase":"measure"' || fail "the log scope did not carry the run and phase"
# Only the one valid /work request is stamped: the probe answers before the
# stamping, and the hostile request and the readiness polls carry nothing.
[[ "$(grep -c 'SPAN run=run-42' "${log}")" == 1 && "$(grep -c 'SPAN run= phase=$' "${log}")" -ge 3 ]] \
  || fail "hostile or absent baggage was stamped on a span: $(grep SPAN "${log}")"
grep 'handled work' "${log}" | grep -q 'hacked' && fail "hostile baggage reached the log scope"

log="${work}/plain.log"
start_app "" "" "${log}"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'baggage: perf.run.id=run-42,perf.phase=measure' "${url}/perf/baggage")" == 404 ]] \
  || fail "the probe answered without the injection"
curl -fsS -H 'baggage: perf.run.id=run-42,perf.phase=measure' "${url}/work" >/dev/null
sleep 1
stop_app
grep -q 'SPAN run=run-42' "${log}" && fail "a run was stamped without the injection"

echo "telemetry injection tests passed"
