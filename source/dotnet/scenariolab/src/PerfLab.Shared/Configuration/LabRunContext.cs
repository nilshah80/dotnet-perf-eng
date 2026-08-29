using System.Text.RegularExpressions;

namespace PerfLab.Shared.Configuration;

public sealed partial record LabRunContext(
    string ScenarioId,
    string RunId,
    string RunMode)
{
    public bool Is(string scenarioId) =>
        string.Equals(ScenarioId, scenarioId, StringComparison.OrdinalIgnoreCase);

    public bool IsDiagnosticRun =>
        string.Equals(RunMode, "diagnose", StringComparison.OrdinalIgnoreCase);

    public static LabRunContext FromEnvironment()
    {
        var scenarioId = Environment.GetEnvironmentVariable("PERF_SCENARIO") ?? "S00";
        var runId = Environment.GetEnvironmentVariable("PERF_RUN_ID") ?? "local-manual";
        var runMode = Environment.GetEnvironmentVariable("PERF_RUN_MODE") ?? "measure";

        if (!ScenarioPattern().IsMatch(scenarioId))
        {
            throw new InvalidOperationException(
                $"PERF_SCENARIO must be S00 through S26; received '{scenarioId}'.");
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

        return new LabRunContext(scenarioId.ToUpperInvariant(), runId, runMode);
    }

    [GeneratedRegex("^S(?:0[0-9]|1[0-9]|2[0-6])$", RegexOptions.CultureInvariant)]
    private static partial Regex ScenarioPattern();

    [GeneratedRegex("^[A-Za-z0-9._-]{1,80}$", RegexOptions.CultureInvariant)]
    private static partial Regex RunIdPattern();
}
