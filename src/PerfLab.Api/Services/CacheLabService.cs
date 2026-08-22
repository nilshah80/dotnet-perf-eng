using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using PerfLab.Api.Contracts;
using PerfLab.Shared.Configuration;
using PerfLab.Shared.Data;
using PerfLab.Shared.Diagnostics;
using StackExchange.Redis;

namespace PerfLab.Api.Services;

public sealed class CacheLabService(
    IConnectionMultiplexer sharedMultiplexer,
    DependencySettings dependencySettings,
    IDbContextFactory<LabDbContext> contextFactory,
    LabRunContext runContext)
{
    private static readonly ConcurrentDictionary<int, SemaphoreSlim> RefreshGates = new();

    public async Task<CacheResult> GetCategoryAsync(int categoryId, CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        var tags = LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId);
        LabTelemetry.ScenarioExecutions.Add(1, tags);

        if (runContext.Is("S13"))
        {
            var result = await ReadManySequentiallyAsync(categoryId);
            stopwatch.Stop();
            return result with { ElapsedMs = stopwatch.Elapsed.TotalMilliseconds };
        }

        if (runContext.Is("S14"))
        {
            using var transient = await ConnectionMultiplexer.ConnectAsync(dependencySettings.Redis);
            var result = await ReadCategoryAsync(
                transient.GetDatabase(),
                categoryId,
                useSingleFlight: false,
                uniqueKey: false,
                cancellationToken);
            stopwatch.Stop();
            return result with { Strategy = "request-connection", ElapsedMs = stopwatch.Elapsed.TotalMilliseconds };
        }

        var uniqueKey = runContext.Is("S15");
        var useSingleFlight = !runContext.Is("S12") && !uniqueKey;
        var response = await ReadCategoryAsync(
            sharedMultiplexer.GetDatabase(),
            categoryId,
            useSingleFlight,
            uniqueKey,
            cancellationToken);
        stopwatch.Stop();
        return response with { ElapsedMs = stopwatch.Elapsed.TotalMilliseconds };
    }

    private async Task<CacheResult> ReadCategoryAsync(
        IDatabase cache,
        int categoryId,
        bool useSingleFlight,
        bool uniqueKey,
        CancellationToken cancellationToken)
    {
        var key = uniqueKey
            ? $"catalog:{categoryId}:{Guid.NewGuid():N}"
            : $"catalog:{categoryId}";

        var cached = await cache.StringGetAsync(key);
        if (cached.HasValue)
        {
            LabTelemetry.CacheRequests.Add(
                1,
                LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId, ("cache.result", "hit")));
            return CreateCacheResult("cached", true, cached);
        }

        if (!useSingleFlight)
        {
            return await PopulateAsync(cache, key, categoryId, uniqueKey, cancellationToken);
        }

        var gate = RefreshGates.GetOrAdd(categoryId, static _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(cancellationToken);
        try
        {
            cached = await cache.StringGetAsync(key);
            if (cached.HasValue)
            {
                return CreateCacheResult("single-flight-waiter", true, cached);
            }

            return await PopulateAsync(cache, key, categoryId, uniqueKey, cancellationToken);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<CacheResult> PopulateAsync(
        IDatabase cache,
        RedisKey key,
        int categoryId,
        bool noExpiry,
        CancellationToken cancellationToken)
    {
        using var activity = LabTelemetry.ActivitySource.StartActivity("cache.populate");
        activity?.SetTag("cache.key", key.ToString());

        await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
        var products = await db.Products
            .AsNoTracking()
            .Where(x => x.CategoryId == categoryId && x.IsActive)
            .OrderBy(x => x.Id)
            .Take(1_000)
            .Select(x => new { x.Id, x.Name, x.Price })
            .ToArrayAsync(cancellationToken);

        if (runContext.Is("S12"))
        {
            await Task.Delay(150, cancellationToken);
        }

        var payload = JsonSerializer.SerializeToUtf8Bytes(products);
        if (noExpiry)
        {
            await cache.StringSetAsync(key, payload);
        }
        else
        {
            await cache.StringSetAsync(key, payload, TimeSpan.FromSeconds(5));
        }

        LabTelemetry.CacheRequests.Add(
            1,
            LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId, ("cache.result", "miss")));

        return new CacheResult(
            noExpiry ? "unbounded-keys" : "database-refresh",
            false,
            products.Length,
            payload.LongLength,
            0);
    }

    private async Task<CacheResult> ReadManySequentiallyAsync(int categoryId)
    {
        var cache = sharedMultiplexer.GetDatabase();
        var bytes = 0L;
        var hits = 0;
        for (var index = 0; index < 100; index++)
        {
            var key = $"catalog-fragment:{categoryId}:{index}";
            var value = await cache.StringGetAsync(key);
            if (!value.HasValue)
            {
                value = JsonSerializer.SerializeToUtf8Bytes(new { categoryId, index, value = index * 7 });
                await cache.StringSetAsync(key, value, TimeSpan.FromMinutes(5));
            }
            else
            {
                hits++;
            }

            bytes += value.Length();
        }

        return new CacheResult("sequential-fragments", hits == 100, 100, bytes, 0);
    }

    private static CacheResult CreateCacheResult(string strategy, bool hit, RedisValue value)
    {
        using var document = JsonDocument.Parse((byte[]?)value!);
        return new CacheResult(
            strategy,
            hit,
            document.RootElement.GetArrayLength(),
            value.Length(),
            0);
    }
}
