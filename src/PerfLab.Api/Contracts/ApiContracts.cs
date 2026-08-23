namespace PerfLab.Api.Contracts;

public sealed record ProductResult(int Id, string Name, decimal Price, double Score);

public sealed record OrderItemResult(int ProductId, int Quantity, decimal UnitPrice);

public sealed record OrderResult(
    long Id,
    DateTimeOffset CreatedAt,
    decimal Total,
    string Status,
    IReadOnlyList<OrderItemResult> Items);

public sealed record CacheResult(
    string Strategy,
    bool Hit,
    int ItemCount,
    long PayloadBytes,
    double ElapsedMs);

public sealed record ThreadingResult(string Path, int Operations, double ElapsedMs);

public sealed record MemoryResult(string Path, long RetainedObjects, long AllocatedBytes, int Checksum);

public sealed record PoolResult(
    string Resource,
    string Strategy,
    int ConfiguredSize,
    int? CreatedResources,
    int Operations,
    double ElapsedMs,
    double? WaitMs);

public sealed record PublishOrderRequest(
    int CustomerId = 1,
    int ProductId = 1,
    int Quantity = 1,
    bool Poison = false);

public sealed record PublishOrderResult(string MessageId, long OrderId, string Status);
