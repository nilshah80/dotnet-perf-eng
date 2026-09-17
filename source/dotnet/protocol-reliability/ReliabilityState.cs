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
    private readonly Channel<QueueItem> _queue;
    private readonly ConcurrentDictionary<string, long> _tenantCompleted = new();
    private long _sequence;
    private long _accepted;
    private long _completed;
    private long _rejected;
    private long _failed;
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
    }

    public string InstanceId { get; }
    public int Capacity { get; }
    public bool Paused => Volatile.Read(ref _paused) == 1;
    public bool Draining => Volatile.Read(ref _draining) == 1;
    public int DelayMilliseconds => Volatile.Read(ref _delayMilliseconds);
    public ChannelReader<QueueItem> Reader => _queue.Reader;

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
    public void SetPaused(bool value) => Volatile.Write(ref _paused, value ? 1 : 0);
    public void SetDraining(bool value) => Volatile.Write(ref _draining, value ? 1 : 0);
    public void SetDelay(int value) => Volatile.Write(ref _delayMilliseconds,
        Math.Clamp(value, 0, 5_000));
    public long NextSequence() => Interlocked.Increment(ref _sequence);
    public object Snapshot() => new
    {
        instanceId = InstanceId,
        capacity = Capacity,
        accepted = Interlocked.Read(ref _accepted),
        completed = Interlocked.Read(ref _completed),
        rejected = Interlocked.Read(ref _rejected),
        failed = Interlocked.Read(ref _failed),
        paused = Paused,
        draining = Draining,
        delayMilliseconds = DelayMilliseconds,
        tenantCompleted = _tenantCompleted.OrderBy(pair => pair.Key)
            .ToDictionary(pair => pair.Key, pair => pair.Value)
    };
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
