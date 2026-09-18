using System.Diagnostics;
using Microsoft.AspNetCore.HttpLogging;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using PerfLab.Api.Contracts;
using PerfLab.Api.Services;
using PerfLab.Shared.Configuration;
using PerfLab.Shared.Data;
using PerfLab.Shared.Diagnostics;
using PerfLab.Shared.Messaging;
using StackExchange.Redis;

Activity.DefaultIdFormat = ActivityIdFormat.W3C;
Activity.ForceDefaultIdFormat = true;

var builder = WebApplication.CreateBuilder(args);
var runContext = LabRunContext.FromEnvironment();
var dependencySettings = DependencySettings.FromEnvironment();
var otlpEndpoint = new Uri(
    Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT") ?? "http://localhost:4317");

builder.Services.AddSingleton(runContext);
builder.Services.AddSingleton(dependencySettings);
builder.Services.AddSingleton(_ => NpgsqlDataSource.Create(dependencySettings.PostgreSql));
builder.Services.AddPooledDbContextFactory<LabDbContext>(options =>
    options.UseNpgsql(dependencySettings.PostgreSql, npgsql =>
        npgsql.CommandTimeout(5)));
builder.Services.AddSingleton<IConnectionMultiplexer>(_ =>
    ConnectionMultiplexer.Connect(dependencySettings.Redis));
builder.Services.AddSingleton(sp => new RabbitConnectionProvider(
    dependencySettings,
    "perflab-api"));

builder.Services.AddSingleton<DatabaseSeeder>();
builder.Services.AddScoped<CatalogService>();
builder.Services.AddScoped<OrderQueryService>();
builder.Services.AddScoped<CacheLabService>();
builder.Services.AddScoped<RuntimeLabService>();
builder.Services.AddSingleton<PoolLabService>();
builder.Services.AddSingleton<OrderPublisher>();
builder.Services.AddProblemDetails();

var resourceAttributes = new Dictionary<string, object>
{
    ["deployment.environment.name"] = "local-poc",
    ["perf.run.id"] = runContext.RunId,
    ["scenario.id"] = runContext.ScenarioId,
    ["perf.run.mode"] = runContext.RunMode
};

builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource
        .AddService(
            serviceName: "perflab-api",
            serviceVersion: Environment.GetEnvironmentVariable("SERVICE_VERSION") ?? "dev")
        .AddAttributes(resourceAttributes))
    .WithTracing(tracing => tracing
        .AddSource(LabTelemetry.SourceName)
        .AddAspNetCoreInstrumentation(options =>
        {
            options.Filter = context => !context.Request.Path.StartsWithSegments("/health");
            options.RecordException = true;
        })
        .AddHttpClientInstrumentation(options => options.RecordException = true)
        .AddNpgsql()
        // Redis was previously the only dependency with no tracing, which left the
        // cache scenarios unable to show dependency time at all. This instruments
        // the injected singleton multiplexer; multiplexers a scenario constructs
        // itself are still not traced.
        .AddRedisInstrumentation()
        .AddOtlpExporter(options => options.Endpoint = otlpEndpoint))
    .WithMetrics(metrics => metrics
        .AddMeter(LabTelemetry.MeterName, "Npgsql", "System.Net.Http")
        .AddAspNetCoreInstrumentation()
        .AddRuntimeInstrumentation()
        .AddOtlpExporter(options => options.Endpoint = otlpEndpoint));

builder.Logging.AddOpenTelemetry(logging =>
{
    logging.IncludeFormattedMessage = true;
    logging.IncludeScopes = true;
    logging.ParseStateValues = true;
    logging.SetResourceBuilder(ResourceBuilder.CreateDefault()
        .AddService("perflab-api")
        .AddAttributes(resourceAttributes));
    // The batch log processor defaults to a 2,048-record queue, and a scenario
    // that logs per message can emit tens of thousands of records per second, so
    // records were being dropped before export. A larger queue keeps moderate
    // volumes intact. A deliberate log storm still exceeds any queue: for those,
    // the reliable evidence is the counter metric, not individual log lines.
    logging.AddOtlpExporter((exporterOptions, processorOptions) =>
    {
        exporterOptions.Endpoint = otlpEndpoint;
        processorOptions.BatchExportProcessorOptions.MaxQueueSize = 20_000;
        processorOptions.BatchExportProcessorOptions.MaxExportBatchSize = 2_048;
    });
});

// Per-request logging is an explicit opt-in (D-P0-12). The knob is
// PERFLAB_REQUEST_LOGGING, which compose maps onto the logging categories; it is
// OFF by default because at this lab's throughput two lines per request is over
// a million records per window, which perturbs the measurement and instantly
// truncates the log budget.
//
// It has to be HTTP logging middleware rather than a category level: raising
// Microsoft.AspNetCore to Information does NOT produce per-request records on
// this framework version, so the knob silently did nothing and every run
// reported an empty log window. Fields are restricted to what correlates a line
// to a trace and a route -- bodies and headers are never logged, because this
// runs against synthetic data but the habit should not depend on that.
var requestLogging = Environment.GetEnvironmentVariable("PERFLAB_REQUEST_LOGGING");
var requestLoggingEnabled = requestLogging is not null && (
    requestLogging.Equals("Trace", StringComparison.OrdinalIgnoreCase) ||
    requestLogging.Equals("Debug", StringComparison.OrdinalIgnoreCase) ||
    requestLogging.Equals("Information", StringComparison.OrdinalIgnoreCase));
if (requestLoggingEnabled)
{
    // The filter is set here rather than left to configuration layering. The
    // compose variable sets Logging:LogLevel:Microsoft.AspNetCore.HttpLogging,
    // but appsettings.json pins the parent Microsoft.AspNetCore to Warning and
    // that pin wins in practice -- so the documented knob silently did nothing.
    // An explicit filter makes the knob authoritative instead of dependent on
    // which of two files is read last.
    builder.Logging.AddFilter("Microsoft.AspNetCore.HttpLogging", LogLevel.Information);
    builder.Services.AddHttpLogging(options =>
    {
        options.LoggingFields =
            HttpLoggingFields.RequestMethod |
            HttpLoggingFields.RequestPath |
            HttpLoggingFields.ResponseStatusCode |
            HttpLoggingFields.Duration;
        options.CombineLogs = true;
    });
}

var app = builder.Build();
app.UseExceptionHandler();

if (requestLoggingEnabled)
{
    app.UseHttpLogging();
}


app.Use(async (httpContext, next) =>
{
    Activity.Current?.SetTag("perf.run.id", runContext.RunId);
    Activity.Current?.SetTag("scenario.id", runContext.ScenarioId);
    httpContext.Response.Headers["X-Perf-Run-Id"] = runContext.RunId;
    httpContext.Response.Headers["X-Perf-Scenario"] = runContext.ScenarioId;

    using var scope = app.Logger.BeginScope(new Dictionary<string, object>
    {
        ["perf.run.id"] = runContext.RunId,
        ["scenario.id"] = runContext.ScenarioId,
        ["perf.run.mode"] = runContext.RunMode
    });
    await next(httpContext);
});

app.MapGet("/", () => Results.Ok(new
{
    service = "perflab-api",
    scenario = runContext.ScenarioId,
    runId = runContext.RunId,
    mode = runContext.RunMode
}));

app.MapGet("/health/live", () => Results.Ok(new { status = "live" }));

app.MapGet("/health/ready", async (
    IDbContextFactory<LabDbContext> contextFactory,
    IConnectionMultiplexer redis,
    RabbitConnectionProvider rabbit,
    CancellationToken cancellationToken) =>
{
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    await db.Database.ExecuteSqlRawAsync("SELECT 1", cancellationToken);
    var redisLatency = await redis.GetDatabase().PingAsync();
    var rabbitConnection = await rabbit.GetConnectionAsync(cancellationToken);
    return Results.Ok(new
    {
        status = "ready",
        postgres = "ok",
        redis = new { status = "ok", latencyMs = redisLatency.TotalMilliseconds },
        rabbitmq = rabbitConnection.IsOpen ? "ok" : "closed"
    });
});

app.MapGet("/api/scenario", () => Results.Ok(new
{
    runContext.ScenarioId,
    runContext.RunId,
    runContext.RunMode,
    safety = new
    {
        memoryRetentionLimitMb = 125,
        databasePoolSize = 20,
        databasePoolExperimentSizes = new[] { 2, 64 },
        redisMultiplexerPoolExperimentSizes = new[] { 1, 32 },
        httpConnectionPoolExperimentSizes = new[] { 2, 128 },
        requestTimeoutSeconds = 5,
        rabbitQueueLimit = 10_000
    }
}));

app.MapGet("/api/catalog/recommendations", async (
    int categoryId,
    int? take,
    CatalogService service,
    CancellationToken cancellationToken) =>
{
    var results = await service.GetRecommendationsAsync(
        Math.Clamp(categoryId, 1, 20),
        Math.Clamp(take ?? 20, 1, 100),
        cancellationToken);
    return Results.Ok(results);
});

app.MapGet("/api/customers/{customerId:int}/orders", async (
    int customerId,
    int? page,
    int? pageSize,
    OrderQueryService service,
    CancellationToken cancellationToken) =>
{
    var results = await service.GetOrdersAsync(
        Math.Max(customerId, 1),
        Math.Clamp(page ?? 1, 1, 5_000),
        Math.Clamp(pageSize ?? 25, 1, 100),
        cancellationToken);
    return Results.Ok(results);
});

app.MapGet("/api/cache/catalog/{categoryId:int}", async (
    int categoryId,
    CacheLabService service,
    CancellationToken cancellationToken) =>
    Results.Ok(await service.GetCategoryAsync(
        Math.Clamp(categoryId, 1, 20),
        cancellationToken)));

app.MapGet("/api/runtime/threading", async (
    RuntimeLabService service,
    CancellationToken cancellationToken) =>
    Results.Ok(await service.ExerciseThreadingAsync(cancellationToken)));

app.MapGet("/api/runtime/memory", async (
    RuntimeLabService service,
    CancellationToken cancellationToken) =>
    Results.Ok(await service.ExerciseMemoryAsync(cancellationToken)));

app.MapGet("/api/pools/postgres", async (
    PoolLabService service,
    CancellationToken cancellationToken) =>
    Results.Ok(await service.ExercisePostgresAsync(cancellationToken)));

app.MapGet("/api/pools/redis", async (
    PoolLabService service,
    CancellationToken cancellationToken) =>
    Results.Ok(await service.ExerciseRedisAsync(cancellationToken)));

app.MapGet("/api/pools/http", async (
    PoolLabService service,
    CancellationToken cancellationToken) =>
    Results.Ok(await service.ExerciseHttpAsync(cancellationToken)));

app.MapGet("/internal/pool-delay", async (CancellationToken cancellationToken) =>
{
    await Task.Delay(100, cancellationToken);
    return Results.Ok(new { status = "ok" });
});

app.MapPost("/api/orders", async (
    PublishOrderRequest request,
    OrderPublisher publisher,
    CancellationToken cancellationToken) =>
    Results.Accepted(
        value: await publisher.PublishAsync(request, cancellationToken)));

// S27 inventory-deadlock: force a real PostgreSQL circular-wait deadlock. Two
// concurrent transactions lock the SAME two inventory rows in OPPOSITE order
// (1->2 and 2->1), with a gap between the two locks so both are holding one row
// and reaching for the other. The server's deadlock detector then aborts one
// side with SQLSTATE 40P01. This is the case S10 does NOT cover: S10's requests
// all lock a single row, which serializes into a convoy but never forms a cycle;
// alternating the lock order per request is what creates the circular wait. The
// 40P01 abort is surfaced as a 409 so it is a countable outcome in the HTTP
// metrics and pg_stat_database.deadlocks, not an opaque 500. Kept at 16
// connections (< the 20 pool) so the evidence is the deadlock, not pool
// exhaustion; deadlock_timeout (~1s) fires before the 5s command timeout.
var deadlockToggle = 0;
app.MapGet("/api/inventory/deadlock", async (
    IDbContextFactory<LabDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    var forward = System.Threading.Interlocked.Increment(ref deadlockToggle) % 2 == 0;
    var (first, second) = forward ? (1, 2) : (2, 1);

    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
    try
    {
        await db.Inventory
            .FromSqlInterpolated($"SELECT * FROM inventory WHERE product_id = {first} FOR UPDATE")
            .AsNoTracking().ToListAsync(cancellationToken);
        await Task.Delay(50, cancellationToken);
        await db.Inventory
            .FromSqlInterpolated($"SELECT * FROM inventory WHERE product_id = {second} FOR UPDATE")
            .AsNoTracking().ToListAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return Results.Ok(new { lockedOrder = new[] { first, second }, outcome = "committed" });
    }
    catch (PostgresException ex) when (ex.SqlState == PostgresErrorCodes.DeadlockDetected)
    {
        await transaction.RollbackAsync(CancellationToken.None);
        return Results.Conflict(new
        {
            lockedOrder = new[] { first, second },
            outcome = "deadlock_detected",
            sqlState = ex.SqlState,
        });
    }
});

await using (var seedScope = app.Services.CreateAsyncScope())
{
    var seeder = seedScope.ServiceProvider.GetRequiredService<DatabaseSeeder>();
    await seeder.InitializeAsync();
}

app.Logger.LogInformation(
    "PerfLab API starting with scenario {ScenarioId}, run {RunId}, mode {RunMode}",
    runContext.ScenarioId,
    runContext.RunId,
    runContext.RunMode);

await app.RunAsync();
