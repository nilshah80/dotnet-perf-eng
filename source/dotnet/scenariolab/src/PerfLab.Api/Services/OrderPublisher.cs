using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using PerfLab.Api.Contracts;
using PerfLab.Shared.Configuration;
using PerfLab.Shared.Data;
using PerfLab.Shared.Diagnostics;
using PerfLab.Shared.Messaging;
using RabbitMQ.Client;
using StackExchange.Redis;

namespace PerfLab.Api.Services;

public sealed class OrderPublisher(
    RabbitConnectionProvider connectionProvider,
    IDbContextFactory<LabDbContext> contextFactory,
    IConnectionMultiplexer redis,
    LabRunContext runContext,
    ILogger<OrderPublisher> logger) : IAsyncDisposable
{
    private readonly SemaphoreSlim _channelGate = new(1, 1);
    private IChannel? _sharedChannel;

    public async Task<PublishOrderResult> PublishAsync(
        PublishOrderRequest request,
        CancellationToken cancellationToken)
    {
        using var activity = LabTelemetry.ActivitySource.StartActivity(
            "rabbitmq.publish order.created",
            ActivityKind.Producer);
        activity?.SetTag("messaging.system", "rabbitmq");
        activity?.SetTag("messaging.destination.name", RabbitTopology.Exchange);
        activity?.SetTag("messaging.rabbitmq.destination.routing_key", RabbitTopology.RoutingKey);

        var message = new OrderCreatedMessage(
            Guid.NewGuid().ToString("N"),
            Random.Shared.NextInt64(1_000_000, 9_000_000),
            request.CustomerId,
            request.ProductId,
            Math.Clamp(request.Quantity, 1, 10),
            request.Poison,
            runContext.RunId,
            runContext.ScenarioId,
            DateTimeOffset.UtcNow);
        var body = JsonSerializer.SerializeToUtf8Bytes(message);
        var properties = CreateProperties(message.MessageId, activity);
        await using var hotInventoryLease = await AcquireHotInventoryLeaseAsync(
            request.ProductId,
            message.Quantity,
            cancellationToken);

        if (runContext.Is("S16"))
        {
            var factory = connectionProvider.CreateFactory();
            await using var connection = await factory.CreateConnectionAsync(
                clientProvidedName: "perflab-api-transient",
                cancellationToken: cancellationToken);
            await using var channel = await connection.CreateChannelAsync(cancellationToken: cancellationToken);
            await RabbitConnectionProvider.DeclareTopologyAsync(channel, cancellationToken);
            await PublishCoreAsync(channel, properties, body, cancellationToken);
        }
        else if (runContext.Is("S19"))
        {
            var channel = await GetSharedChannelAsync(cancellationToken);
            await PublishCoreAsync(channel, properties, body, cancellationToken);
        }
        else
        {
            await _channelGate.WaitAsync(cancellationToken);
            try
            {
                var channel = await GetSharedChannelAsync(cancellationToken);
                await PublishCoreAsync(channel, properties, body, cancellationToken);
            }
            finally
            {
                _channelGate.Release();
            }
        }

        if (hotInventoryLease is not null)
        {
            await hotInventoryLease.CommitAsync(cancellationToken);
        }

        LabTelemetry.OrdersPublished.Add(
            1,
            LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId));
        logger.LogInformation(
            "Published order {OrderId} with message {MessageId}",
            message.OrderId,
            message.MessageId);
        return new PublishOrderResult(message.MessageId, message.OrderId, "published");
    }

    private async Task<IChannel> GetSharedChannelAsync(CancellationToken cancellationToken)
    {
        if (_sharedChannel is { IsOpen: true })
        {
            return _sharedChannel;
        }

        var connection = await connectionProvider.GetConnectionAsync(cancellationToken);
        _sharedChannel = await connection.CreateChannelAsync(cancellationToken: cancellationToken);
        await RabbitConnectionProvider.DeclareTopologyAsync(_sharedChannel, cancellationToken);
        return _sharedChannel;
    }

    private async Task<HotInventoryLease?> AcquireHotInventoryLeaseAsync(
        int productId,
        int quantity,
        CancellationToken cancellationToken)
    {
        if (!runContext.Is("S10"))
        {
            return null;
        }

        var db = await contextFactory.CreateDbContextAsync(cancellationToken);
        var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        try
        {
            var inventory = await db.Inventory
                .FromSqlInterpolated(
                    $"SELECT * FROM inventory WHERE product_id = {Math.Max(productId, 1)} FOR UPDATE")
                .SingleAsync(cancellationToken);
            inventory.Quantity = Math.Max(0, inventory.Quantity - quantity);
            inventory.UpdatedAt = DateTimeOffset.UtcNow;
            await db.SaveChangesAsync(cancellationToken);

            await redis.GetDatabase().StringSetAsync(
                $"inventory:{inventory.ProductId}",
                inventory.Quantity,
                TimeSpan.FromSeconds(5));
            await Task.Delay(100, cancellationToken);
            return new HotInventoryLease(db, transaction);
        }
        catch
        {
            await transaction.RollbackAsync(CancellationToken.None);
            await transaction.DisposeAsync();
            await db.DisposeAsync();
            throw;
        }
    }

    private static BasicProperties CreateProperties(string messageId, Activity? activity)
    {
        var headers = new Dictionary<string, object?>();
        if (activity is not null)
        {
            headers["traceparent"] = Encoding.UTF8.GetBytes(activity.Id!);
            if (!string.IsNullOrWhiteSpace(activity.TraceStateString))
            {
                headers["tracestate"] = Encoding.UTF8.GetBytes(activity.TraceStateString);
            }
        }

        return new BasicProperties
        {
            MessageId = messageId,
            ContentType = "application/json",
            Type = nameof(OrderCreatedMessage),
            DeliveryMode = DeliveryModes.Persistent,
            Headers = headers
        };
    }

    private static ValueTask PublishCoreAsync(
        IChannel channel,
        BasicProperties properties,
        ReadOnlyMemory<byte> body,
        CancellationToken cancellationToken) =>
        channel.BasicPublishAsync(
            RabbitTopology.Exchange,
            RabbitTopology.RoutingKey,
            mandatory: true,
            basicProperties: properties,
            body,
            cancellationToken);

    public async ValueTask DisposeAsync()
    {
        if (_sharedChannel is not null)
        {
            await _sharedChannel.DisposeAsync();
        }

        _channelGate.Dispose();
    }

    private sealed class HotInventoryLease(
        LabDbContext db,
        IDbContextTransaction transaction) : IAsyncDisposable
    {
        private bool _committed;

        public async Task CommitAsync(CancellationToken cancellationToken)
        {
            await transaction.CommitAsync(cancellationToken);
            _committed = true;
        }

        public async ValueTask DisposeAsync()
        {
            if (!_committed)
            {
                await transaction.RollbackAsync(CancellationToken.None);
            }

            await transaction.DisposeAsync();
            await db.DisposeAsync();
        }
    }
}
