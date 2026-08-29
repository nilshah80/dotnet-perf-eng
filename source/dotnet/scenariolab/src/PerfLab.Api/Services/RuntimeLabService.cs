using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using PerfLab.Api.Contracts;
using PerfLab.Shared.Configuration;
using PerfLab.Shared.Data;
using PerfLab.Shared.Diagnostics;

namespace PerfLab.Api.Services;

public sealed class RuntimeLabService(
    IDbContextFactory<LabDbContext> contextFactory,
    LabRunContext runContext)
{
    private static readonly SemaphoreSlim SharedGate = new(1, 1);
    private static long _retainedObserverCount;
    private const int MaximumRetainedObservers = 2_000;
    private static event Action? SamplePublished;

    public async Task<ThreadingResult> ExerciseThreadingAsync(CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        LabTelemetry.ScenarioExecutions.Add(
            1,
            LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId));

        if (runContext.Is("S02"))
        {
            Task.Delay(100, cancellationToken).GetAwaiter().GetResult();
            return Finish("blocking-wait", 1, stopwatch);
        }

        if (runContext.Is("S03"))
        {
            await SharedGate.WaitAsync(cancellationToken);
            try
            {
                await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
                _ = await db.Products.AsNoTracking().CountAsync(cancellationToken);
                await Task.Delay(50, cancellationToken);
            }
            finally
            {
                SharedGate.Release();
            }

            return Finish("global-gate", 1, stopwatch);
        }

        if (runContext.Is("S06"))
        {
            var tasks = Enumerable.Range(0, 128)
                .Select(index => Task.Run(() =>
                {
                    var buffer = new byte[16_384];
                    RandomNumberGenerator.Fill(buffer);
                    return buffer[index % buffer.Length];
                }, cancellationToken));
            await Task.WhenAll(tasks);
            return Finish("task-fanout", 128, stopwatch);
        }

        await Task.Delay(10, cancellationToken);
        return Finish("async-control", 1, stopwatch);
    }

    public Task<MemoryResult> ExerciseMemoryAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        LabTelemetry.ScenarioExecutions.Add(
            1,
            LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId));

        if (runContext.Is("S04"))
        {
            var next = Interlocked.Increment(ref _retainedObserverCount);
            if (next <= MaximumRetainedObservers)
            {
                var observerState = GC.AllocateUninitializedArray<byte>(64 * 1024);
                observerState[0] = (byte)(next % byte.MaxValue);
                SamplePublished += () => GC.KeepAlive(observerState);
            }

            SamplePublished?.Invoke();
            return Task.FromResult(new MemoryResult(
                "observer-retention",
                Math.Min(next, MaximumRetainedObservers),
                64 * 1024,
                (int)(next % int.MaxValue)));
        }

        if (runContext.Is("S05"))
        {
            var checksum = 0;
            long allocated = 0;
            for (var index = 0; index < 12; index++)
            {
                var bytes = GC.AllocateUninitializedArray<byte>(128 * 1024);
                RandomNumberGenerator.Fill(bytes);
                var base64 = Convert.ToBase64String(bytes);
                // Property names must match AllocationPayload's constructor
                // parameters exactly: this is a direct JsonSerializer call, so
                // JsonSerializerOptions.Default applies and property matching is
                // case-sensitive. Lower-cased names left Base64 null and the
                // length read below threw before any real round-trip happened.
                var json = JsonSerializer.Serialize(new { Index = index, Base64 = base64 });
                var copy = JsonSerializer.Deserialize<AllocationPayload>(json);
                checksum ^= copy?.Base64.Length ?? 0;
                allocated += bytes.LongLength + (base64.Length * sizeof(char)) + (json.Length * sizeof(char));
            }

            return Task.FromResult(new MemoryResult("large-object-churn", 0, allocated, checksum));
        }

        var control = new byte[4 * 1024];
        return Task.FromResult(new MemoryResult("allocation-control", 0, control.Length, control[0]));
    }

    private static ThreadingResult Finish(string path, int operations, Stopwatch stopwatch)
    {
        stopwatch.Stop();
        return new ThreadingResult(path, operations, stopwatch.Elapsed.TotalMilliseconds);
    }

    private sealed record AllocationPayload(int Index, string Base64);
}

