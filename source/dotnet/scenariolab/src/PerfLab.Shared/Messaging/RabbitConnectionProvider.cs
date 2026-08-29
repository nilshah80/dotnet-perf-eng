using PerfLab.Shared.Configuration;
using RabbitMQ.Client;

namespace PerfLab.Shared.Messaging;

public sealed class RabbitConnectionProvider(
    DependencySettings settings,
    string clientName) : IAsyncDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private IConnection? _connection;

    public ConnectionFactory CreateFactory(ushort consumerDispatchConcurrency = 1) => new()
    {
        HostName = settings.RabbitMqHost,
        Port = settings.RabbitMqPort,
        UserName = settings.RabbitMqUser,
        Password = settings.RabbitMqPassword,
        AutomaticRecoveryEnabled = true,
        TopologyRecoveryEnabled = true,
        RequestedHeartbeat = TimeSpan.FromSeconds(15),
        ConsumerDispatchConcurrency = consumerDispatchConcurrency
    };

    public async Task<IConnection> GetConnectionAsync(CancellationToken cancellationToken = default)
    {
        if (_connection is { IsOpen: true })
        {
            return _connection;
        }

        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_connection is { IsOpen: true })
            {
                return _connection;
            }

            if (_connection is not null)
            {
                await _connection.DisposeAsync();
            }

            _connection = await CreateFactory().CreateConnectionAsync(
                clientProvidedName: clientName,
                cancellationToken: cancellationToken);
            return _connection;
        }
        finally
        {
            _gate.Release();
        }
    }

    public static async Task DeclareTopologyAsync(
        IChannel channel,
        CancellationToken cancellationToken = default)
    {
        await channel.ExchangeDeclareAsync(
            RabbitTopology.Exchange,
            ExchangeType.Topic,
            durable: true,
            autoDelete: false,
            cancellationToken: cancellationToken);

        await channel.ExchangeDeclareAsync(
            RabbitTopology.DeadLetterExchange,
            ExchangeType.Topic,
            durable: true,
            autoDelete: false,
            cancellationToken: cancellationToken);

        var queueArguments = new Dictionary<string, object?>
        {
            ["x-max-length"] = 10_000,
            ["x-overflow"] = "reject-publish-dlx",
            ["x-dead-letter-exchange"] = RabbitTopology.DeadLetterExchange,
            ["x-dead-letter-routing-key"] = RabbitTopology.DeadLetterRoutingKey
        };

        await channel.QueueDeclareAsync(
            RabbitTopology.Queue,
            durable: true,
            exclusive: false,
            autoDelete: false,
            arguments: queueArguments,
            cancellationToken: cancellationToken);

        await channel.QueueBindAsync(
            RabbitTopology.Queue,
            RabbitTopology.Exchange,
            RabbitTopology.RoutingKey,
            cancellationToken: cancellationToken);

        await channel.QueueDeclareAsync(
            RabbitTopology.DeadLetterQueue,
            durable: true,
            exclusive: false,
            autoDelete: false,
            cancellationToken: cancellationToken);

        await channel.QueueBindAsync(
            RabbitTopology.DeadLetterQueue,
            RabbitTopology.DeadLetterExchange,
            RabbitTopology.DeadLetterRoutingKey,
            cancellationToken: cancellationToken);
    }

    public async ValueTask DisposeAsync()
    {
        if (_connection is not null)
        {
            await _connection.DisposeAsync();
        }

        _gate.Dispose();
    }
}
