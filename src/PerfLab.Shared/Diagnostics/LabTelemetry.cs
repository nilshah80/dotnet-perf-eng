using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace PerfLab.Shared.Diagnostics;

public static class LabTelemetry
{
    public const string SourceName = "PerfLab.Application";
    public const string MeterName = "PerfLab.Application";

    public static readonly ActivitySource ActivitySource = new(SourceName);
    public static readonly Meter Meter = new(MeterName);

    public static readonly Counter<long> ScenarioExecutions =
        Meter.CreateCounter<long>("perflab.scenario.executions", unit: "{execution}");

    public static readonly Counter<long> CacheRequests =
        Meter.CreateCounter<long>("perflab.cache.requests", unit: "{request}");

    public static readonly Counter<long> OrdersPublished =
        Meter.CreateCounter<long>("perflab.orders.published", unit: "{message}");

    public static readonly Counter<long> OrdersProcessed =
        Meter.CreateCounter<long>("perflab.orders.processed", unit: "{message}");

    public static readonly Counter<long> OrdersRetried =
        Meter.CreateCounter<long>("perflab.orders.retried", unit: "{message}");

    public static readonly Counter<long> CorrectnessFailures =
        Meter.CreateCounter<long>("perflab.correctness.failures", unit: "{failure}");

    public static readonly Histogram<double> OrderProcessingDuration =
        Meter.CreateHistogram<double>("perflab.order.processing.duration", unit: "ms");

    public static readonly Histogram<long> ResponseItems =
        Meter.CreateHistogram<long>("perflab.response.items", unit: "{item}");

    public static readonly Histogram<double> PoolWaitDuration =
        Meter.CreateHistogram<double>("perflab.pool.wait.duration", unit: "ms");

    public static readonly Histogram<double> PoolLeaseDuration =
        Meter.CreateHistogram<double>("perflab.pool.lease.duration", unit: "ms");

    public static readonly UpDownCounter<long> PoolActiveLeases =
        Meter.CreateUpDownCounter<long>("perflab.pool.active_leases", unit: "{lease}");

    public static readonly Counter<long> PoolResourcesCreated =
        Meter.CreateCounter<long>("perflab.pool.resources.created", unit: "{resource}");

    public static readonly Counter<long> PoolTimeouts =
        Meter.CreateCounter<long>("perflab.pool.timeouts", unit: "{timeout}");

    public static TagList Tags(string scenarioId, string runId, params (string Key, object? Value)[] additional)
    {
        var tags = new TagList
        {
            { "scenario.id", scenarioId },
            { "perf.run.id", runId }
        };

        foreach (var (key, value) in additional)
        {
            tags.Add(key, value);
        }

        return tags;
    }
}
