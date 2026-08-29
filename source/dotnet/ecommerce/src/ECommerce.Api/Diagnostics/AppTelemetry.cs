using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace ECommerce.Api.Diagnostics;

// The meter's metric names all begin with "ecommerce." so they surface in
// Prometheus as ecommerce_* -- which is what the harness captures when the lab
// sets PERFLAB_APP_METRIC_PREFIX=ecommerce. ecommerce.scenario.executions
// becomes ecommerce_scenario_executions_total, the metric evidence capture reads
// to derive the service-instance scope for runtime/dependency metrics.
public static class AppTelemetry
{
    public const string SourceName = "ECommerce.Application";
    public const string MeterName = "ECommerce.Application";

    public static readonly ActivitySource ActivitySource = new(SourceName);
    public static readonly Meter Meter = new(MeterName);

    public static readonly Counter<long> ScenarioExecutions =
        Meter.CreateCounter<long>("ecommerce.scenario.executions", unit: "{execution}");

    public static readonly Counter<long> Logins =
        Meter.CreateCounter<long>("ecommerce.logins", unit: "{login}");

    public static readonly Counter<long> AuthFailures =
        Meter.CreateCounter<long>("ecommerce.auth.failures", unit: "{failure}");

    public static readonly Counter<long> OrdersCreated =
        Meter.CreateCounter<long>("ecommerce.orders.created", unit: "{order}");

    public static readonly Histogram<long> ResponseItems =
        Meter.CreateHistogram<long>("ecommerce.response.items", unit: "{item}");
}
