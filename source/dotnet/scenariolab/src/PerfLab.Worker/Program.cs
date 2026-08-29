using System.Diagnostics;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Hosting;
using Npgsql;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using PerfLab.Shared.Configuration;
using PerfLab.Shared.Data;
using PerfLab.Shared.Diagnostics;
using PerfLab.Shared.Messaging;
using PerfLab.Worker;

Activity.DefaultIdFormat = ActivityIdFormat.W3C;
Activity.ForceDefaultIdFormat = true;

var builder = Host.CreateApplicationBuilder(args);
var runContext = LabRunContext.FromEnvironment();
var dependencySettings = DependencySettings.FromEnvironment();
var otlpEndpoint = new Uri(
    Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT") ?? "http://localhost:4317");

builder.Services.AddSingleton(runContext);
builder.Services.AddSingleton(dependencySettings);
builder.Services.AddPooledDbContextFactory<LabDbContext>(options =>
    options.UseNpgsql(dependencySettings.PostgreSql, npgsql => npgsql.CommandTimeout(5)));
builder.Services.AddSingleton(_ => new RabbitConnectionProvider(
    dependencySettings,
    "perflab-worker"));
builder.Services.AddHostedService<OrderConsumerService>();

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
            serviceName: "perflab-worker",
            serviceVersion: Environment.GetEnvironmentVariable("SERVICE_VERSION") ?? "dev")
        .AddAttributes(resourceAttributes))
    .WithTracing(tracing => tracing
        .AddSource(LabTelemetry.SourceName)
        .AddHttpClientInstrumentation(options => options.RecordException = true)
        .AddNpgsql()
        .AddOtlpExporter(options => options.Endpoint = otlpEndpoint))
    .WithMetrics(metrics => metrics
        .AddMeter(LabTelemetry.MeterName, "Npgsql")
        .AddRuntimeInstrumentation()
        .AddOtlpExporter(options => options.Endpoint = otlpEndpoint));

builder.Logging.AddOpenTelemetry(logging =>
{
    logging.IncludeFormattedMessage = true;
    logging.IncludeScopes = true;
    logging.ParseStateValues = true;
    logging.SetResourceBuilder(ResourceBuilder.CreateDefault()
        .AddService("perflab-worker")
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

var host = builder.Build();
await host.RunAsync();
