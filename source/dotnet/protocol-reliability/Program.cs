using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Net.WebSockets;
using System.Text;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using ProtocolReliability;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8080, listen => listen.Protocols = HttpProtocols.Http1);
    options.ListenAnyIP(8081, listen => listen.Protocols = HttpProtocols.Http2);
});
builder.Services.AddGrpc();
builder.Services.AddSignalR();
builder.Services.AddSingleton<ReliabilityState>();
builder.Services.AddHostedService<QueueWorker>();
var serviceName = Environment.GetEnvironmentVariable("OTEL_SERVICE_NAME") ??
    "protocol-reliability";
var configuredRunId = Environment.GetEnvironmentVariable("PERF_RUN_ID") ?? "unspecified";
var configuredScenario = Environment.GetEnvironmentVariable("PERF_SCENARIO") ?? "unspecified";
var resourceAttributes = new Dictionary<string, object>
{
    ["perf.run.id"] = configuredRunId,
    ["perf.scenario"] = configuredScenario
};
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource.AddService(serviceName)
        .AddAttributes(resourceAttributes))
    .WithTracing(tracing => tracing
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddOtlpExporter())
    .WithMetrics(metrics => metrics
        .AddMeter("ProtocolReliability")
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddOtlpExporter());
builder.Logging.AddOpenTelemetry(logging =>
{
    logging.IncludeScopes = true;
    logging.ParseStateValues = true;
    logging.SetResourceBuilder(ResourceBuilder.CreateDefault().AddService(serviceName)
            .AddAttributes(resourceAttributes))
        .AddOtlpExporter();
});

var app = builder.Build();
var contention = new SemaphoreSlim(1, 1);
var heldMemory = new System.Collections.Concurrent.ConcurrentQueue<byte[]>();
var meter = new Meter("ProtocolReliability", "1.0.0");
var requestCounter = meter.CreateCounter<long>("protocol_reliability.requests");
var requestDuration = meter.CreateHistogram<double>("protocol_reliability.request.duration", "ms");
var telemetryLogger = app.Services.GetRequiredService<ILoggerFactory>()
    .CreateLogger("ProtocolReliability.Request");
long nextTelemetryLogEpoch = 0;

app.UseWebSockets();
app.UseDefaultFiles();
app.UseStaticFiles();
app.Use(async (context, next) =>
{
    var state = context.RequestServices.GetRequiredService<ReliabilityState>();
    var runId = context.Request.Headers["X-Perf-Run-Id"].FirstOrDefault() ??
        configuredRunId;
    var scenario = configuredScenario;
    Activity.Current?.SetTag("perf.run.id", runId);
    Activity.Current?.SetTag("perf.scenario", scenario);
    context.Response.Headers["X-Instance-Id"] = state.InstanceId;
    var started = Stopwatch.GetTimestamp();
    using (telemetryLogger.BeginScope(new Dictionary<string, object>
    {
        ["perf.run.id"] = runId,
        ["perf.scenario"] = scenario,
        ["service.instance.id"] = state.InstanceId
    }))
    {
        await next(context);
        var currentEpoch = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var expectedEpoch = Volatile.Read(ref nextTelemetryLogEpoch);
        if (currentEpoch >= expectedEpoch && Interlocked.CompareExchange(
                ref nextTelemetryLogEpoch, currentEpoch + 10, expectedEpoch) == expectedEpoch)
        {
            telemetryLogger.LogInformation(
                "Performance telemetry heartbeat for run {RunId} scenario {Scenario}",
                runId, scenario);
        }
    }
    var tags = new TagList
    {
        { "perf.run.id", runId },
        { "perf.scenario", scenario },
        { "service.instance.id", state.InstanceId },
        { "http.response.status_code", context.Response.StatusCode }
    };
    requestCounter.Add(1, tags);
    requestDuration.Record(Stopwatch.GetElapsedTime(started).TotalMilliseconds, tags);
});

app.MapGrpcService<ReliabilityGrpcService>();
app.MapHub<EchoHub>("/signalr");
app.MapGet("/favicon.ico", () => Results.NoContent());
app.MapGet("/health/live", (ReliabilityState state) => Results.Ok(new
{
    status = "live",
    instanceId = state.InstanceId
}));
app.MapGet("/health/ready", (ReliabilityState state) => state.Draining
    ? Results.Json(new { status = "draining", instanceId = state.InstanceId }, statusCode: 503)
    : Results.Ok(new { status = "ready", instanceId = state.InstanceId }));
app.MapGet("/api/reliability/status", (ReliabilityState state) => Results.Ok(state.Snapshot()));
app.MapPost("/api/reliability/messages", (HttpRequest request, ReliabilityState state) =>
{
    var runId = request.Headers["X-Perf-Run-Id"].FirstOrDefault() ?? "unspecified";
    var tenant = request.Query["tenant"].FirstOrDefault() ?? "default";
    return state.TryEnqueue(runId, tenant, out var item)
        ? Results.Accepted(value: item)
        : Results.Json(new { error = state.Draining ? "draining" : "backpressure" },
            statusCode: state.Draining ? 503 : 429);
});
app.MapPost("/api/reliability/control", (HttpRequest request, ReliabilityState state) =>
{
    if (!AdminAuthorized(request))
    {
        return Results.Unauthorized();
    }
    if (bool.TryParse(request.Query["paused"], out var paused))
    {
        state.SetPaused(paused);
    }
    if (bool.TryParse(request.Query["draining"], out var draining))
    {
        state.SetDraining(draining);
    }
    if (int.TryParse(request.Query["delayMs"], out var delay))
    {
        state.SetDelay(delay);
    }
    return Results.Ok(state.Snapshot());
});
app.MapGet("/api/reliability/contention", async (int? holdMs, CancellationToken token) =>
{
    var queuedAt = Stopwatch.GetTimestamp();
    await contention.WaitAsync(token);
    try
    {
        var waited = Stopwatch.GetElapsedTime(queuedAt).TotalMilliseconds;
        await Task.Delay(Math.Clamp(holdMs ?? 10, 0, 250), token);
        return Results.Ok(new { waitedMilliseconds = waited });
    }
    finally
    {
        contention.Release();
    }
});
app.MapGet("/api/reliability/cpu", (int? milliseconds) =>
{
    var duration = TimeSpan.FromMilliseconds(Math.Clamp(milliseconds ?? 20, 1, 250));
    var started = Stopwatch.GetTimestamp();
    long operations = 0;
    while (Stopwatch.GetElapsedTime(started) < duration)
    {
        operations = unchecked((operations * 31) + 17);
    }
    return Results.Ok(new { durationMilliseconds = duration.TotalMilliseconds, operations });
});
app.MapGet("/api/reliability/memory", async (int? megabytes, int? holdMs) =>
{
    var size = Math.Clamp(megabytes ?? 4, 1, 64) * 1024 * 1024;
    var buffer = GC.AllocateUninitializedArray<byte>(size);
    buffer[0] = 1;
    heldMemory.Enqueue(buffer);
    await Task.Delay(Math.Clamp(holdMs ?? 50, 1, 2_000));
    while (heldMemory.Count > 8 && heldMemory.TryDequeue(out _))
    {
    }
    return Results.Ok(new { allocatedBytes = size, retainedBuffers = heldMemory.Count });
});
app.MapGet("/api/reliability/exceptions", (int? count) =>
{
    var requested = Math.Clamp(count ?? 100, 1, 10_000);
    var caught = 0;
    for (var index = 0; index < requested; index++)
    {
        try
        {
            throw new InvalidOperationException($"controlled-profile-sample-{index % 8}");
        }
        catch (InvalidOperationException)
        {
            caught++;
        }
    }
    return Results.Ok(new { requested, caught });
});
app.MapGet("/api/reliability/tenant/{tenant}", (string tenant, int? workUnits) =>
{
    var iterations = Math.Clamp(workUnits ?? 10, 0, 10_000) * 100;
    var checksum = tenant.GetHashCode(StringComparison.Ordinal);
    for (var index = 0; index < iterations; index++)
    {
        checksum = unchecked((checksum * 31) ^ index);
    }
    return Results.Ok(new { tenant, workUnits = iterations / 100, checksum });
});
app.Map("/ws", async context =>
{
    if (!context.WebSockets.IsWebSocketRequest)
    {
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        return;
    }
    var state = context.RequestServices.GetRequiredService<ReliabilityState>();
    using var socket = await context.WebSockets.AcceptWebSocketAsync();
    var buffer = new byte[16 * 1024];
    while (socket.State == WebSocketState.Open)
    {
        var received = await socket.ReceiveAsync(buffer, context.RequestAborted);
        if (received.MessageType == WebSocketMessageType.Close)
        {
            await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "closed",
                context.RequestAborted);
            break;
        }
        var text = Encoding.UTF8.GetString(buffer, 0, received.Count);
        var response = Encoding.UTF8.GetBytes($"{state.InstanceId}|{state.NextSequence()}|{text}");
        await socket.SendAsync(response, WebSocketMessageType.Text, true,
            context.RequestAborted);
    }
});

app.Run();

static bool AdminAuthorized(HttpRequest request)
{
    var expected = Environment.GetEnvironmentVariable("PERF_ADMIN_TOKEN") ??
        "protocol-reliability-local";
    return request.Headers.TryGetValue("X-Perf-Admin", out var supplied) &&
        System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(supplied.ToString()));
}

public partial class Program;
