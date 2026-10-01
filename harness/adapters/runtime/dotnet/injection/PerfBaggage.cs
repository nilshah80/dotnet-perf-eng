using System.Diagnostics;

namespace PerfLab.DotNet.Injection;

/// <summary>
/// The perflab-baggage-v1 request contract. A load generator sends the W3C
/// header <c>baggage: perf.run.id=&lt;run&gt;,perf.phase=&lt;phase&gt;</c>; the
/// application stamps the run and phase it can validate on spans, logs and
/// request metrics, and forwards them with the work it hands off. The run id
/// set when the process started only names the deployment; the baggage names
/// the run and phase the request belongs to, which is what a shared or remote
/// target needs. Every other baggage member is ignored: arbitrary request
/// baggage must never become a label.
/// </summary>
internal readonly record struct PerfBaggage(string? RunId, string? Phase)
{
    public const string HeaderName = "baggage";
    public const string ContractVersion = "perflab-baggage-v1";
    public const string RunIdKey = "perf.run.id";
    public const string PhaseKey = "perf.phase";
    private const int MaxHeaderLength = 8192;
    public bool IsEmpty => RunId is null && Phase is null;

    public static PerfBaggage Parse(string? header)
    {
        if (string.IsNullOrEmpty(header) || header.Length > MaxHeaderLength)
        {
            return default;
        }

        string? runId = null;
        string? phase = null;
        foreach (var member in header.Split(','))
        {
            var separator = member.IndexOf('=');
            if (separator <= 0)
            {
                continue;
            }

            var key = member[..separator].Trim();
            var value = member[(separator + 1)..];
            var properties = value.IndexOf(';');
            if (properties >= 0)
            {
                value = value[..properties];
            }

            value = Unescape(value.Trim());
            if (key == RunIdKey && value is not null && IsRunId(value))
            {
                runId = value;
            }
            else if (key == PhaseKey && value is not null && IsPhase(value))
            {
                phase = value;
            }
        }

        return new PerfBaggage(runId, phase);
    }

    private static bool IsRunId(string value) =>
        value.Length is > 0 and <= 128 &&
        value.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-' or ':');

    private static bool IsPhase(string value) => value is "warmup" or "measure" or "diagnostic";

    public void Stamp(Activity? activity)
    {
        if (activity is null)
        {
            return;
        }

        if (RunId is not null)
        {
            activity.SetTag(RunIdKey, RunId);
        }

        if (Phase is not null)
        {
            activity.SetTag(PhaseKey, Phase);
        }
    }

    private static string? Unescape(string value)
    {
        try
        {
            return Uri.UnescapeDataString(value);
        }
        catch (UriFormatException)
        {
            return null;
        }
    }
}
