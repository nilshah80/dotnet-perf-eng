using System.Diagnostics;
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
        .AddOtlpExporter(options => options.Endpoint = otlpEndpoint))
    .WithMetrics(metrics => metrics
        .AddMeter(LabTelemetry.MeterName, "Npgsql")
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
    logging.AddOtlpExporter(options => options.Endpoint = otlpEndpoint);
});

var app = builder.Build();
app.UseExceptionHandler();

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

app.MapPost("/api/orders", async (
    PublishOrderRequest request,
    OrderPublisher publisher,
    CancellationToken cancellationToken) =>
    Results.Accepted(
        value: await publisher.PublishAsync(request, cancellationToken)));

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

