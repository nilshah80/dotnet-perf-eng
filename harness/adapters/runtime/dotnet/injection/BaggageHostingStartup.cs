using System.Diagnostics;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

[assembly: HostingStartup(typeof(PerfLab.DotNet.Injection.BaggageHostingStartup))]

namespace PerfLab.DotNet.Injection;

/// <summary>
/// perflab-baggage-v1 (D-P1-8) for any ASP.NET Core application, injected with
/// ASPNETCORE_HOSTINGSTARTUPASSEMBLIES. A startup filter puts one middleware in
/// front of the application's pipeline. It stamps the request's validated run
/// and phase on the request span and the log scope, adds the phase to
/// http.server.request.duration (never the run id: the process's resource
/// attribute already carries a run id, and a second value under the same label
/// would be ambiguous), and answers the contract's probe.
/// </summary>
public sealed class BaggageHostingStartup : IHostingStartup
{
    public void Configure(IWebHostBuilder builder) =>
        builder.ConfigureServices(services => services.AddTransient<IStartupFilter, BaggageStartupFilter>());
}

internal sealed class BaggageStartupFilter : IStartupFilter
{
    public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
    {
        var logger = app.ApplicationServices.GetRequiredService<ILoggerFactory>().CreateLogger("PerfLab.Baggage");
        app.Use((context, nextMiddleware) => BaggageMiddleware.InvokeAsync(context, nextMiddleware, logger));
        next(app);
    };
}

internal static class BaggageMiddleware
{
    /// <summary>
    /// Echoes what this process read from the request, so a harness can prove
    /// the target honours perflab-baggage-v1 before any measured traffic.
    /// </summary>
    public const string ProbePath = "/perf/baggage";

    public static async Task InvokeAsync(HttpContext context, RequestDelegate next, ILogger logger)
    {
        var baggage = PerfBaggage.Parse(context.Request.Headers[PerfBaggage.HeaderName].ToString());
        if (HttpMethods.IsGet(context.Request.Method) && context.Request.Path.Equals(ProbePath, StringComparison.Ordinal))
        {
            if (baggage.RunId is null || baggage.Phase is null)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                await context.Response.WriteAsJsonAsync(new
                {
                    error = "baggage with a bounded perf.run.id and perf.phase is required",
                    contractVersion = PerfBaggage.ContractVersion,
                });
                return;
            }

            await context.Response.WriteAsJsonAsync(new
            {
                contractVersion = PerfBaggage.ContractVersion,
                runId = baggage.RunId,
                phase = baggage.Phase,
                source = "injected",
            });
            return;
        }

        if (baggage.IsEmpty)
        {
            await next(context);
            return;
        }

        baggage.Stamp(Activity.Current);
        if (baggage.Phase is not null)
        {
            context.Features.Get<IHttpMetricsTagsFeature>()?.Tags.Add(new(PerfBaggage.PhaseKey, baggage.Phase));
        }

        var scope = new Dictionary<string, object>(2);
        if (baggage.RunId is not null)
        {
            scope[PerfBaggage.RunIdKey] = baggage.RunId;
        }

        if (baggage.Phase is not null)
        {
            scope[PerfBaggage.PhaseKey] = baggage.Phase;
        }

        using (logger.BeginScope(scope))
        {
            await next(context);
        }
    }
}
