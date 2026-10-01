using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Security.Cryptography.X509Certificates;
using System.Net.WebSockets;
using System.Text;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.Server.Kestrel.Https;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using ProtocolReliability;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
var httpPort = int.TryParse(Environment.GetEnvironmentVariable("PERFLAB_HTTP_PORT"), out var configuredHttpPort)
    ? Math.Clamp(configuredHttpPort, 1, 65535)
    : 8080;
var secondaryHttpPort = int.TryParse(Environment.GetEnvironmentVariable("PERFLAB_HTTP_SECONDARY_PORT"), out var configuredSecondaryHttpPort)
    ? Math.Clamp(configuredSecondaryHttpPort, 1, 65535)
    : 0;
var grpcPort = int.TryParse(Environment.GetEnvironmentVariable("PERFLAB_GRPC_PORT"), out var configuredGrpcPort)
    ? Math.Clamp(configuredGrpcPort, 1, 65535)
    : 8081;
var httpsPort = int.TryParse(Environment.GetEnvironmentVariable("PERFLAB_HTTPS_PORT"), out var configuredHttpsPort)
    ? Math.Clamp(configuredHttpsPort, 1, 65535)
    : 0;
var tlsCertificatePath = Environment.GetEnvironmentVariable("PERFLAB_TLS_CERT_PATH");
var tlsCertificatePassword = Environment.GetEnvironmentVariable("PERFLAB_TLS_CERT_PASSWORD");
var requireClientCertificate = string.Equals(Environment.GetEnvironmentVariable("PERFLAB_TLS_REQUIRE_CLIENT_CERT"), "1", StringComparison.Ordinal);
var clientCaPath = Environment.GetEnvironmentVariable("PERFLAB_TLS_CLIENT_CA_PATH");
X509Certificate2? trustedClientCa = null;
if (secondaryHttpPort > 0 && (secondaryHttpPort == httpPort || secondaryHttpPort == grpcPort || secondaryHttpPort == httpsPort))
{
    throw new InvalidOperationException("PERFLAB_HTTP_SECONDARY_PORT must differ from every configured listener port.");
}
if (httpsPort > 0)
{
    if (string.IsNullOrWhiteSpace(tlsCertificatePath) || !File.Exists(tlsCertificatePath))
    {
        throw new InvalidOperationException("PERFLAB_HTTPS_PORT requires an existing PERFLAB_TLS_CERT_PATH.");
    }
    if (requireClientCertificate && (string.IsNullOrWhiteSpace(clientCaPath) || !File.Exists(clientCaPath)))
    {
        throw new InvalidOperationException("PERFLAB_TLS_REQUIRE_CLIENT_CERT=1 requires an existing PERFLAB_TLS_CLIENT_CA_PATH.");
    }
    if (requireClientCertificate)
    {
        trustedClientCa = X509CertificateLoader.LoadCertificateFromFile(clientCaPath!);
    }
}
builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(httpPort, listen => listen.Protocols = HttpProtocols.Http1);
    if (secondaryHttpPort > 0)
    {
        // A second listener is a real distinct origin for the Protocol
        // Reliability multi-origin journey. It deliberately serves the same
        // application surface so tests isolate routing authorization from
        // application semantics.
        options.ListenAnyIP(secondaryHttpPort, listen => listen.Protocols = HttpProtocols.Http1);
    }
    options.ListenAnyIP(grpcPort, listen => listen.Protocols = HttpProtocols.Http2);
    if (httpsPort > 0)
    {
        // Kestrel owns the certificate lifetime. Do not request EphemeralKeySet:
        // it is unsupported on some Unix hosts and would turn a configured
        // secure edge into a startup failure.
        var serverCertificate = X509CertificateLoader.LoadPkcs12FromFile(
            tlsCertificatePath!, tlsCertificatePassword);
        options.ListenAnyIP(httpsPort, listen => listen.UseHttps(https =>
        {
            https.ServerCertificate = serverCertificate;
            if (requireClientCertificate)
            {
                https.ClientCertificateMode = ClientCertificateMode.RequireCertificate;
                https.ClientCertificateValidation = (certificate, _, _) =>
                    certificate is not null && trustedClientCa is not null && TrustedBy(certificate, trustedClientCa);
            }
        }));
    }
});
builder.Services.AddGrpc();
builder.Services.AddSignalR();
builder.Services.AddSingleton<ReliabilityState>();
builder.Services.AddSingleton<SecurityJourneyState>();
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
var tenantRequestCounter = meter.CreateCounter<long>("protocol_reliability.tenant.requests");
var tenantDuration = meter.CreateHistogram<double>("protocol_reliability.tenant.duration", "ms");
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
    state.RecordHttpRequest();
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
app.MapGet("/api/reliability/correlation", (HttpRequest request, ReliabilityState state) =>
{
    var runID = request.Headers["X-Perf-Run-Id"].FirstOrDefault();
    return string.IsNullOrWhiteSpace(runID)
        ? Results.BadRequest(new { error = "X-Perf-Run-Id is required for the correlation contract" })
        : Results.Ok(new
        {
            contractVersion = "perflab-run-id-v1",
            runId = runID,
            instanceId = state.InstanceId
        });
});
// The target-owned measurement-window attestation is intentionally distinct
// from a process resource attribute. It proves which concrete instance served
// a generated run at each measurement boundary, so a later restart cannot be
// silently folded into a stale instance's telemetry.
app.MapGet("/api/reliability/window", (HttpRequest request, ReliabilityState state) =>
{
    var runId = request.Headers["X-Perf-Run-Id"].FirstOrDefault();
    var windowId = request.Headers["X-Perf-Measurement-Window"].FirstOrDefault();
    if (!ContractToken(runId) || !ContractToken(windowId))
    {
        return Results.BadRequest(new { error = "bounded X-Perf-Run-Id and X-Perf-Measurement-Window are required" });
    }
    return Results.Ok(new
    {
        contractVersion = "perflab-measurement-window-v1",
        runId,
        measurementWindowId = windowId,
        instanceId = state.InstanceId,
        processStartedAtUnixMilliseconds = state.ProcessStartedAtUnixMilliseconds
    });
});
// This endpoint is intentionally narrower than the general reliability surface:
// a distributed agent can exercise only a GET request with a generated,
// target-validated partition. It is a live proof target for the authenticated
// k6 execution-segment protocol, not a remote command channel.
app.MapGet("/api/reliability/distributed/{partition}/{shard}/{vu:int}/{iteration:long}",
    (string partition, string shard, int vu, long iteration, HttpResponse response, ReliabilityState state) =>
{
    if (!ContractToken(partition) || !ContractToken(shard) || vu < 1 || iteration < 0)
    {
        return Results.BadRequest(new { error = "bounded partition, shard, VU, and iteration are required" });
    }
    state.RecordDistributedPartition(partition);
    response.Headers["X-Perf-Data-Partition"] = partition;
    return Results.Ok(new { partition, shard, vu, iteration, instanceId = state.InstanceId });
});
app.MapGet("/api/reliability/distributed/proof", (ReliabilityState state) => Results.Ok(state.DistributedSnapshot()));
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
app.MapGet("/api/reliability/connection-churn", async (HttpResponse response, int? queueMs, int? serverMs,
    CancellationToken token) =>
{
    // A controlled application queue and work interval make client-side DNS,
    // TLS, connect, queue, and server timing decomposition reproducible. The
    // headers state the two server components explicitly; they are not guessed
    // from client elapsed time.
    var queue = Math.Clamp(queueMs ?? 0, 0, 2_000);
    var server = Math.Clamp(serverMs ?? 5, 1, 2_000);
    if (queue > 0)
    {
        await Task.Delay(queue, token);
    }
    var started = Stopwatch.GetTimestamp();
    await Task.Delay(server, token);
    response.Headers["X-Perf-Server-Queue-Ms"] = queue.ToString(System.Globalization.CultureInfo.InvariantCulture);
    response.Headers["X-Perf-Server-Work-Ms"] = Stopwatch.GetElapsedTime(started).TotalMilliseconds
        .ToString("F3", System.Globalization.CultureInfo.InvariantCulture);
    return Results.Ok(new { queueMilliseconds = queue, serverMilliseconds = server });
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
app.MapGet("/api/reliability/tenant/{tenant}", async (string tenant, int? workUnits, ReliabilityState state,
    CancellationToken token) =>
{
    if (!state.IsKnownTenant(tenant))
    {
        return Results.BadRequest(new { error = "tenant must be one of noisy or protected" });
    }
    var result = await state.RunTenantWorkAsync(tenant, workUnits ?? 10, token);
    var tags = new TagList { { "tenant", tenant } };
    tenantRequestCounter.Add(1, tags);
    tenantDuration.Record(result.TotalMilliseconds, tags);
    return Results.Ok(result);
});
app.MapGet("/api/reliability/tenant-slos", (ReliabilityState state) => Results.Ok(state.TenantSloSnapshot()));
app.MapPost("/api/reliability/journey/login", (HttpRequest request, HttpResponse response,
    SecurityJourneyState security) =>
{
    var login = security.CreateLogin();
    response.Cookies.Append("perflab_journey_session", login.SessionID, new CookieOptions
    {
        HttpOnly = true,
        IsEssential = true,
        SameSite = SameSiteMode.Strict,
        Secure = request.IsHttps,
        Path = "/api/reliability/journey",
        MaxAge = TimeSpan.FromMinutes(15)
    });
    // The first access token is intentionally expired. A successful journey
    // must demonstrate an actual refresh before it can perform the mutation.
    return Results.Json(new
    {
        accessToken = login.AccessToken,
        refreshToken = login.RefreshToken,
        tokenState = "expired",
        expiresInSeconds = 0
    }, statusCode: StatusCodes.Status201Created);
});
app.MapGet("/api/reliability/journey/form", (HttpRequest request, SecurityJourneyState security) =>
{
    return security.TryGetForm(JourneySessionID(request), out var csrfToken)
        ? Results.Ok(new { csrfToken })
        : Results.Unauthorized();
});
app.MapGet("/api/reliability/journey/protected", (HttpRequest request, SecurityJourneyState security) =>
{
    return security.CheckAccess(JourneySessionID(request), BearerToken(request)) switch
    {
        AccessResult.Active => Results.Ok(new { status = "active" }),
        AccessResult.Expired => Results.Json(new { error = "access-token-expired" },
            statusCode: StatusCodes.Status401Unauthorized),
        AccessResult.Invalid => Results.Json(new { error = "access-token-invalid" },
            statusCode: StatusCodes.Status401Unauthorized),
        _ => Results.Json(new { error = "session-required" },
            statusCode: StatusCodes.Status401Unauthorized)
    };
});
app.MapPost("/api/reliability/journey/refresh", (HttpRequest request,
    JourneyRefreshRequest refresh, SecurityJourneyState security) =>
{
    return security.TryRefresh(JourneySessionID(request), refresh.RefreshToken, out var rotated)
        ? Results.Ok(new
        {
            accessToken = rotated.AccessToken,
            refreshToken = rotated.RefreshToken,
            csrfToken = rotated.CsrfToken,
            tokenState = "active"
        })
        : Results.Json(new { error = "refresh-rejected" }, statusCode: StatusCodes.Status401Unauthorized);
});
app.MapPost("/api/reliability/journey/submit", (HttpRequest request,
    SecurityJourneyState security) =>
{
    var result = security.TrySubmit(JourneySessionID(request), BearerToken(request),
        request.Headers["X-Perf-CSRF"].FirstOrDefault());
    if (result.Accepted)
    {
        return Results.Json(new
        {
            submission = result.Submission,
            nextCsrfToken = result.NextCsrfToken
        }, statusCode: StatusCodes.Status201Created);
    }
    return result.Disposition == SubmitDisposition.CsrfDenied
        ? Results.Json(new { error = "csrf-rejected" }, statusCode: StatusCodes.Status403Forbidden)
        : Results.Json(new { error = "access-or-session-rejected" },
            statusCode: StatusCodes.Status401Unauthorized);
});
app.MapGet("/api/reliability/journey/status", (SecurityJourneyState security) => Results.Ok(security.Snapshot()));
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

static string? JourneySessionID(HttpRequest request) =>
    request.Cookies.TryGetValue("perflab_journey_session", out var sessionID) ? sessionID : null;

static string? BearerToken(HttpRequest request)
{
    var header = request.Headers.Authorization.FirstOrDefault();
    const string prefix = "Bearer ";
    return !string.IsNullOrWhiteSpace(header) && header.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
        ? header[prefix.Length..]
        : null;
}

static bool TrustedBy(X509Certificate2 certificate, X509Certificate2 trustedRoot)
{
    using var chain = new X509Chain();
    chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
    chain.ChainPolicy.CustomTrustStore.Add(trustedRoot);
    chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
    chain.ChainPolicy.VerificationFlags = X509VerificationFlags.NoFlag;
    return chain.Build(certificate);
}

static bool ContractToken(string? value) =>
    !string.IsNullOrWhiteSpace(value) && value.Length <= 128 &&
    value.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-');

public sealed record JourneyRefreshRequest(string? RefreshToken);

public partial class Program;
