using System.Text.RegularExpressions;

namespace ECommerce.Api.Configuration;

// Mirrors the reference lab's LabRunContext but accepts any short scenario id
// (the harness scenario id is only a correlation key). The values become OTel
// resource attributes so evidence capture can scope to one run.
public sealed partial record EcommerceRunContext(
    string ScenarioId,
    string RunId,
    string RunMode)
{
    public bool IsDiagnosticRun =>
        string.Equals(RunMode, "diagnose", StringComparison.OrdinalIgnoreCase);

    public static EcommerceRunContext FromEnvironment()
    {
        var scenarioId = Environment.GetEnvironmentVariable("PERF_SCENARIO") ?? "E00";
        var runId = Environment.GetEnvironmentVariable("PERF_RUN_ID") ?? "local-manual";
        var runMode = Environment.GetEnvironmentVariable("PERF_RUN_MODE") ?? "measure";

        if (!ScenarioPattern().IsMatch(scenarioId))
        {
            throw new InvalidOperationException(
                $"PERF_SCENARIO must match [A-Za-z][A-Za-z0-9._-]{{0,15}}; received '{scenarioId}'.");
        }

        if (!RunIdPattern().IsMatch(runId))
        {
            throw new InvalidOperationException(
                "PERF_RUN_ID may contain only letters, numbers, '.', '_' and '-' (maximum 80 characters).");
        }

        if (runMode is not ("measure" or "diagnose"))
        {
            throw new InvalidOperationException(
                $"PERF_RUN_MODE must be 'measure' or 'diagnose'; received '{runMode}'.");
        }

        return new EcommerceRunContext(scenarioId.ToUpperInvariant(), runId, runMode);
    }

    [GeneratedRegex("^[A-Za-z][A-Za-z0-9._-]{0,15}$", RegexOptions.CultureInvariant)]
    private static partial Regex ScenarioPattern();

    [GeneratedRegex("^[A-Za-z0-9._-]{1,80}$", RegexOptions.CultureInvariant)]
    private static partial Regex RunIdPattern();
}
