using System.Diagnostics;
using System.Runtime.InteropServices;
using Pyroscope.OpenTelemetry;

namespace PerfLab.DotNet.Injection;

/// <summary>
/// Span-to-profile correlation (D-P1-3) without touching the application. The
/// Pyroscope span processor tags each local root span with
/// <c>pyroscope.profile.id</c> and labels the CPU samples taken while it runs
/// with the same id; here its own OnStart and OnEnd run from an ActivityListener
/// instead of from the application's tracer provider, so the tag reaches the
/// application's exporter on the same Activity. The listener never samples:
/// it sees only activities the application already records. It calls the
/// native profiler, which the image loads only when continuous CPU profiling is
/// on; without it nothing is registered.
///
/// Two conditions come from pyroscope-dotnet's managed library itself. It links
/// spans to samples only in an x64 process, so on Arm64 the listener is not
/// registered and one line says why. And it reads the Datadog-inherited
/// DD_PROFILING_ENABLED rather than PYROSCOPE_PROFILING_ENABLED: without it every
/// span was tagged while no sample carried the id. It is read lazily, so setting
/// it here, before any Pyroscope type loads, is early enough.
/// </summary>
internal static class SpanProfiles
{
    private static ActivityListener? listener;

    public static bool Enabled =>
        Environment.GetEnvironmentVariable("PYROSCOPE_PROFILING_ENABLED") == "1" &&
        string.Equals(
            Environment.GetEnvironmentVariable("PYROSCOPE_PROFILING_CPU_ENABLED"),
            "true",
            StringComparison.OrdinalIgnoreCase);

    public static void Start()
    {
        if (!Enabled || listener is not null)
        {
            return;
        }

        if (RuntimeInformation.ProcessArchitecture != Architecture.X64)
        {
            Console.Error.WriteLine(
                $"PerfLab span profiles: not linked -- pyroscope-dotnet links spans to CPU samples only in x64 processes; this one is {RuntimeInformation.ProcessArchitecture}.");
            return;
        }

        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DD_PROFILING_ENABLED")))
        {
            Environment.SetEnvironmentVariable("DD_PROFILING_ENABLED", "1");
        }

        var processor = new PyroscopeSpanProcessor();
        listener = new ActivityListener
        {
            ShouldListenTo = _ => true,
            ActivityStarted = processor.OnStart,
            ActivityStopped = processor.OnEnd,
        };
        ActivitySource.AddActivityListener(listener);
    }
}
