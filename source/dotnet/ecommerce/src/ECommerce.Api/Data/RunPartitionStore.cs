using System.Collections.Concurrent;

namespace ECommerce.Api.Data;

public sealed class RunPartitionStore
{
    private readonly ConcurrentDictionary<string, Partition> partitions = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, byte> cleanupReceipts = new(StringComparer.Ordinal);

    public sealed class Partition
    {
        public required string RunId { get; init; }
        public bool Seeded { get; set; }
        public bool Reset { get; set; }
        public int Budget { get; set; }
        public int Writes { get; set; }
        public int ReservedWrites { get; set; }
        public bool Cleaned { get; set; }
        public ConcurrentDictionary<long, string> Orders { get; } = new();

        public bool Ready => Seeded && Reset && !Cleaned;
    }

    public Partition Seed(string runId, int budget)
    {
        if (budget <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(budget), "write budget must be positive");
        }

        var partition = new Partition { RunId = runId, Seeded = true, Budget = budget };
        if (cleanupReceipts.ContainsKey(runId) || !partitions.TryAdd(runId, partition))
        {
            throw new InvalidOperationException("run partition already exists; use a unique run id");
        }
        return partition;
    }

    public bool TryReset(string runId, out Partition partition)
    {
        if (!partitions.TryGetValue(runId, out partition!) || !partition.Seeded)
        {
            partition = null!;
            return false;
        }

        lock (partition)
        {
            if (partition.Cleaned || partition.ReservedWrites != 0)
            {
                return false;
            }
            partition.Reset = true;
            partition.Writes = 0;
        }
        return true;
    }

    public bool TryReserveWrite(string runId, out Partition partition)
    {
        if (!partitions.TryGetValue(runId, out partition!))
        {
            partition = null!;
            return false;
        }
        lock (partition)
        {
            if (!partition.Ready || partition.Writes + partition.ReservedWrites >= partition.Budget)
            {
                return false;
            }
            partition.ReservedWrites++;
            return true;
        }
    }

    public bool TryGet(string runId, out Partition partition) =>
        partitions.TryGetValue(runId, out partition!);

    public void CommitWrite(Partition partition, long orderId, string status)
    {
        lock (partition)
        {
            if (partition.ReservedWrites <= 0)
            {
                throw new InvalidOperationException("partition has no reserved write");
            }
            partition.ReservedWrites--;
            partition.Writes++;
            partition.Orders[orderId] = status;
        }
    }

    public void CancelWrite(Partition partition)
    {
        lock (partition)
        {
            if (partition.ReservedWrites > 0)
            {
                partition.ReservedWrites--;
            }
        }
    }

    public bool TryBeginCleanup(string runId, out Partition partition)
    {
        if (!partitions.TryGetValue(runId, out partition!))
        {
            partition = null!;
            return false;
        }
        lock (partition)
        {
            if (partition.ReservedWrites != 0)
            {
                return false;
            }
            partition.Cleaned = true;
            return true;
        }
    }

    public void CompleteCleanup(Partition partition)
    {
        partitions.TryRemove(new KeyValuePair<string, Partition>(partition.RunId, partition));
        cleanupReceipts[partition.RunId] = 1;
    }

    public bool WasCleaned(string runId) => cleanupReceipts.ContainsKey(runId);

    public void RestoreAfterFailedCleanup(Partition partition)
    {
        lock (partition)
        {
            partition.Cleaned = false;
        }
    }
}
