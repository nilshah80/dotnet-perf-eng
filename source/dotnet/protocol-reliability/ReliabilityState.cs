using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading.Channels;
using Grpc.Core;
using Microsoft.AspNetCore.SignalR;
using ProtocolReliability.Grpc;

namespace ProtocolReliability;

public sealed record QueueItem(long Id, string RunId, string Tenant, DateTimeOffset EnqueuedAt);

public sealed class ReliabilityState
{
    private static readonly IReadOnlyDictionary<string, int> TenantSloMilliseconds =
        new Dictionary<string, int>(StringComparer.Ordinal)
        {
            // The fixture intentionally has only two tenants. This makes
            // telemetry labels bounded and makes a noisy-neighbor comparison
            // meaningful instead of accepting arbitrary customer identifiers.
            ["noisy"] = 1_000,
            ["protected"] = 250,
        };
    private readonly Channel<QueueItem> _queue;
    private readonly ConcurrentDictionary<string, long> _tenantCompleted = new();
    private readonly IReadOnlyDictionary<string, TenantLane> _tenantLanes;
    private long _sequence;
    private long _accepted;
    private long _completed;
    private long _rejected;
    private long _failed;
    private long _httpRequests;
    private readonly ConcurrentDictionary<string, long> _distributedPartitions = new(StringComparer.Ordinal);
    private readonly long _processStartedAtUnixMilliseconds = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    private int _paused;
    private int _draining;
    private int _delayMilliseconds = 10;

    public ReliabilityState(IConfiguration configuration)
    {
        InstanceId = configuration["INSTANCE_ID"] ?? Environment.MachineName;
        var capacity = int.TryParse(configuration["QUEUE_CAPACITY"], out var configured)
            ? Math.Clamp(configured, 4, 100_000)
            : 64;
        Capacity = capacity;
        _queue = Channel.CreateBounded<QueueItem>(new BoundedChannelOptions(capacity)
        {
            // TryWrite must return false at capacity so callers receive an
            // explicit 429 instead of silently losing accepted work.
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = false
        });
        _tenantLanes = TenantSloMilliseconds.ToDictionary(
            pair => pair.Key,
            pair => new TenantLane(pair.Value),
            StringComparer.Ordinal);
    }

    public string InstanceId { get; }
    public int Capacity { get; }
    public bool Paused => Volatile.Read(ref _paused) == 1;
    public bool Draining => Volatile.Read(ref _draining) == 1;
    public int DelayMilliseconds => Volatile.Read(ref _delayMilliseconds);
    public ChannelReader<QueueItem> Reader => _queue.Reader;
    public long ProcessStartedAtUnixMilliseconds => _processStartedAtUnixMilliseconds;

    public bool TryEnqueue(string runId, string tenant, out QueueItem item)
    {
        item = new QueueItem(Interlocked.Increment(ref _sequence), runId, tenant,
            DateTimeOffset.UtcNow);
        if (Draining || !_queue.Writer.TryWrite(item))
        {
            Interlocked.Increment(ref _rejected);
            return false;
        }
        Interlocked.Increment(ref _accepted);
        return true;
    }

    public void MarkCompleted(QueueItem item)
    {
        Interlocked.Increment(ref _completed);
        _tenantCompleted.AddOrUpdate(item.Tenant, 1, (_, value) => value + 1);
    }

    public void MarkFailed() => Interlocked.Increment(ref _failed);
    public void RecordHttpRequest() => Interlocked.Increment(ref _httpRequests);
    // Distributed request agents use a bounded, target-echoed partition prefix.
    // Keeping the proof in the target (rather than trusting an agent's claim)
    // makes it possible to establish that separate agents actually exercised
    // separate data partitions during the measured interval.
    public void RecordDistributedPartition(string partition) =>
        _distributedPartitions.AddOrUpdate(partition, 1, (_, value) => value + 1);
    public void SetPaused(bool value) => Volatile.Write(ref _paused, value ? 1 : 0);
    public void SetDraining(bool value) => Volatile.Write(ref _draining, value ? 1 : 0);
    public void SetDelay(int value) => Volatile.Write(ref _delayMilliseconds,
        Math.Clamp(value, 0, 5_000));
    public long NextSequence() => Interlocked.Increment(ref _sequence);

    public bool IsKnownTenant(string tenant) => _tenantLanes.ContainsKey(tenant);

    public async Task<TenantWorkResult> RunTenantWorkAsync(string tenant, int workUnits, CancellationToken token)
    {
        if (!_tenantLanes.TryGetValue(tenant, out var lane))
        {
            throw new ArgumentOutOfRangeException(nameof(tenant), "tenant is not part of the bounded fairness fixture");
        }
        var boundedUnits = Math.Clamp(workUnits, 0, 10_000);
        var arrivedAt = Stopwatch.GetTimestamp();
        await lane.Gate.WaitAsync(token);
        var queueMilliseconds = Stopwatch.GetElapsedTime(arrivedAt).TotalMilliseconds;
        try
        {
            var workStartedAt = Stopwatch.GetTimestamp();
            var checksum = tenant.GetHashCode(StringComparison.Ordinal);
            for (var index = 0; index < boundedUnits * 100; index++)
            {
                checksum = unchecked((checksum * 31) ^ index);
            }
            var totalMilliseconds = Stopwatch.GetElapsedTime(arrivedAt).TotalMilliseconds;
            lane.Record(totalMilliseconds, queueMilliseconds);
            return new TenantWorkResult(tenant, boundedUnits, checksum, queueMilliseconds,
                Stopwatch.GetElapsedTime(workStartedAt).TotalMilliseconds, totalMilliseconds);
        }
        finally
        {
            lane.Gate.Release();
        }
    }

    public object TenantSloSnapshot()
    {
        var tenants = _tenantLanes.OrderBy(pair => pair.Key)
            .ToDictionary(pair => pair.Key, pair => pair.Value.Snapshot(pair.Key));
        var noisy = _tenantLanes["noisy"].Completed;
        var protectedCompleted = _tenantLanes["protected"].Completed;
        return new
        {
            tenants,
            // A zero noisy denominator is intentionally reported rather than
            // faked as fairness. Once both lanes have traffic this is a direct
            // completed-work comparison, while each tenant's p95 SLO remains
            // independently evaluable.
            protectedProgressPerNoisy = noisy == 0 ? (double?)null : (double)protectedCompleted / noisy,
            protectedObservedDuringNoisyLoad = noisy > 0 && protectedCompleted > 0
        };
    }
    public object Snapshot() => new
    {
        instanceId = InstanceId,
        capacity = Capacity,
        accepted = Interlocked.Read(ref _accepted),
        completed = Interlocked.Read(ref _completed),
        rejected = Interlocked.Read(ref _rejected),
        failed = Interlocked.Read(ref _failed),
        httpRequests = Interlocked.Read(ref _httpRequests),
        paused = Paused,
        draining = Draining,
        delayMilliseconds = DelayMilliseconds,
        tenantCompleted = _tenantCompleted.OrderBy(pair => pair.Key)
            .ToDictionary(pair => pair.Key, pair => pair.Value)
    };

    public object DistributedSnapshot() => new
    {
        partitionCount = _distributedPartitions.Count,
        requestsByPartition = _distributedPartitions.OrderBy(pair => pair.Key)
            .ToDictionary(pair => pair.Key, pair => pair.Value)
    };
}

public sealed record TenantWorkResult(string Tenant, int WorkUnits, int Checksum,
    double QueueMilliseconds, double ServerMilliseconds, double TotalMilliseconds);

internal sealed class TenantLane(int sloMilliseconds)
{
    private static readonly double[] HistogramUpperBounds = [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_000, double.PositiveInfinity];
    private readonly long[] _latencyBuckets = new long[HistogramUpperBounds.Length];
    private readonly long[] _queueBuckets = new long[HistogramUpperBounds.Length];
    private long _completed;

    internal SemaphoreSlim Gate { get; } = new(1, 1);
    internal long Completed => Interlocked.Read(ref _completed);

    internal void Record(double totalMilliseconds, double queueMilliseconds)
    {
        RecordHistogram(_latencyBuckets, totalMilliseconds);
        RecordHistogram(_queueBuckets, queueMilliseconds);
        Interlocked.Increment(ref _completed);
    }

    internal object Snapshot(string tenant)
    {
        var completed = Completed;
        var p95 = Percentile(_latencyBuckets, completed, 0.95);
        var queueP95 = Percentile(_queueBuckets, completed, 0.95);
        return new
        {
            tenant,
            completed,
            latencyP95Milliseconds = p95,
            queueP95Milliseconds = queueP95,
            sloP95Milliseconds = sloMilliseconds,
            observed = completed > 0,
            withinSlo = completed > 0 && p95 <= sloMilliseconds
        };
    }

    private static void RecordHistogram(long[] buckets, double value)
    {
        for (var index = 0; index < HistogramUpperBounds.Length; index++)
        {
            if (value <= HistogramUpperBounds[index])
            {
                Interlocked.Increment(ref buckets[index]);
                return;
            }
        }
    }

    private static double Percentile(long[] buckets, long count, double percentile)
    {
        if (count == 0)
        {
            return 0;
        }
        var rank = (long)Math.Ceiling(count * percentile);
        var observed = 0L;
        for (var index = 0; index < buckets.Length; index++)
        {
            observed += Interlocked.Read(ref buckets[index]);
            if (observed >= rank)
            {
                return HistogramUpperBounds[index];
            }
        }
        return HistogramUpperBounds[^1];
    }
}

public sealed class QueueWorker(ReliabilityState state, ILogger<QueueWorker> logger)
    : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var item in state.Reader.ReadAllAsync(stoppingToken))
        {
            while (state.Paused)
            {
                await Task.Delay(25, stoppingToken);
            }
            try
            {
                await Task.Delay(state.DelayMilliseconds, stoppingToken);
                state.MarkCompleted(item);
            }
            catch (Exception exception) when (!stoppingToken.IsCancellationRequested)
            {
                state.MarkFailed();
                logger.LogWarning(exception, "Queue item {ItemId} failed", item.Id);
            }
        }
    }
}

public sealed class EchoHub(ReliabilityState state) : Hub
{
    public object Echo(string runId, string tenant, string payload) => new
    {
        instanceId = state.InstanceId,
        runId,
        tenant,
        payload,
        sequence = state.NextSequence()
    };
}

public sealed class ReliabilityGrpcService(ReliabilityState state)
    : Reliability.ReliabilityBase
{
    public override Task<PingReply> Ping(PingRequest request, ServerCallContext context)
    {
        BoundedCpuWork(request.WorkUnits);
        return Task.FromResult(new PingReply
        {
            InstanceId = state.InstanceId,
            RunId = request.RunId,
            Tenant = request.Tenant,
            Sequence = state.NextSequence()
        });
    }

    private static void BoundedCpuWork(int units)
    {
        var iterations = Math.Clamp(units, 0, 10_000) * 100;
        var value = 17;
        for (var index = 0; index < iterations; index++)
        {
            value = unchecked((value * 31) ^ index);
        }
        GC.KeepAlive(value);
    }
}
