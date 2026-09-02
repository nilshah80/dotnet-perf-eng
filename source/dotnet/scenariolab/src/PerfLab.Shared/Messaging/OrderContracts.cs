namespace PerfLab.Shared.Messaging;

public sealed record OrderCreatedMessage(
    string MessageId,
    long OrderId,
    int CustomerId,
    int ProductId,
    int Quantity,
    bool Poison,
    string RunId,
    string ScenarioId,
    DateTimeOffset CreatedAt);

public static class RabbitTopology
{
    public const string Exchange = "perf.orders";
    public const string RoutingKey = "order.created";
    public const string Queue = "perf.orders.created";
    public const string DeadLetterExchange = "perf.orders.dlx";
    public const string DeadLetterRoutingKey = "order.dead";
    public const string DeadLetterQueue = "perf.orders.dead";
}
