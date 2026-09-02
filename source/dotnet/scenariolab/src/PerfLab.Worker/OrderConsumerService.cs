using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using PerfLab.Shared.Configuration;
using PerfLab.Shared.Data;
using PerfLab.Shared.Diagnostics;
using PerfLab.Shared.Messaging;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

namespace PerfLab.Worker;

public sealed class OrderConsumerService(
    RabbitConnectionProvider connectionProvider,
    IDbContextFactory<LabDbContext> contextFactory,
    LabRunContext runContext,
    ILogger<OrderConsumerService> logger) : BackgroundService
{
    private static readonly ConcurrentDictionary<string, int> PoisonAttempts = new();
    private static readonly ConcurrentQueue<ReadOnlyMemory<byte>> DeferredPayloads = new();
    private const int MaximumDeferredPayloads = 1_000;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await ConsumeUntilDisconnectedAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "RabbitMQ consumer stopped unexpectedly; retrying");
                await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
            }
        }
    }

    private async Task ConsumeUntilDisconnectedAsync(CancellationToken stoppingToken)
    {
        var dispatchConcurrency = runContext.Is("S17") ? (ushort)1 : (ushort)8;
        var prefetch = runContext.Is("S17") ? (ushort)500 : (ushort)32;
        var factory = connectionProvider.CreateFactory(dispatchConcurrency);

        await using var connection = await factory.CreateConnectionAsync(
            clientProvidedName: "perflab-worker-consumer",
            cancellationToken: stoppingToken);
        await using var channel = await connection.CreateChannelAsync(cancellationToken: stoppingToken);
        await RabbitConnectionProvider.DeclareTopologyAsync(channel, stoppingToken);
        await channel.BasicQosAsync(
            prefetchSize: 0,
            prefetchCount: prefetch,
            global: false,
            cancellationToken: stoppingToken);

        var consumer = new AsyncEventingBasicConsumer(channel);
        consumer.ReceivedAsync += (_, eventArgs) => HandleMessageAsync(channel, eventArgs, stoppingToken);

        await channel.BasicConsumeAsync(
            RabbitTopology.Queue,
            autoAck: false,
            consumer,
            cancellationToken: stoppingToken);

        logger.LogInformation(
            "Consuming {Queue} with prefetch {Prefetch} and dispatch concurrency {Concurrency}",
            RabbitTopology.Queue,
            prefetch,
            dispatchConcurrency);

        await Task.Delay(Timeout.InfiniteTimeSpan, stoppingToken);
    }

    private async Task HandleMessageAsync(
        IChannel channel,
        BasicDeliverEventArgs eventArgs,
        CancellationToken cancellationToken)
    {
        var parentContext = ExtractParentContext(eventArgs.BasicProperties.Headers);
        using var activity = parentContext != default
            ? LabTelemetry.ActivitySource.StartActivity(
                "rabbitmq.process order.created",
                ActivityKind.Consumer,
                parentContext)
            : LabTelemetry.ActivitySource.StartActivity(
                "rabbitmq.process order.created",
                ActivityKind.Consumer);
        activity?.SetTag("messaging.system", "rabbitmq");
        activity?.SetTag("messaging.destination.name", RabbitTopology.Queue);
        activity?.SetTag("messaging.operation.type", "process");

        if (runContext.Is("S20"))
        {
            if (DeferredPayloads.Count < MaximumDeferredPayloads)
            {
                DeferredPayloads.Enqueue(eventArgs.Body);
            }

            await channel.BasicAckAsync(eventArgs.DeliveryTag, multiple: false, cancellationToken);
            return;
        }

        var ownedPayload = eventArgs.Body.ToArray();
        var message = JsonSerializer.Deserialize<OrderCreatedMessage>(ownedPayload)
            ?? throw new InvalidOperationException("RabbitMQ message payload was empty.");
        activity?.SetTag("messaging.message.id", message.MessageId);
        activity?.SetTag("perf.run.id", message.RunId);
        activity?.SetTag("scenario.id", message.ScenarioId);

        if (runContext.Is("S18") && message.Poison)
        {
            var attempt = PoisonAttempts.AddOrUpdate(message.MessageId, 1, static (_, current) => current + 1);
            LabTelemetry.OrdersRetried.Add(
                1,
                LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId));

            if (attempt <= 50)
            {
                logger.LogWarning(
                    "Immediately requeueing poison message {MessageId}; attempt {Attempt}",
                    message.MessageId,
                    attempt);
                await channel.BasicNackAsync(
                    eventArgs.DeliveryTag,
                    multiple: false,
                    requeue: true,
                    cancellationToken);
                return;
            }

            logger.LogError(
                "Poison message {MessageId} exceeded local safety cap and will be dead-lettered",
                message.MessageId);
            await channel.BasicNackAsync(
                eventArgs.DeliveryTag,
                multiple: false,
                requeue: false,
                cancellationToken);
            return;
        }

        var stopwatch = Stopwatch.StartNew();
        if (runContext.Is("S17"))
        {
            Thread.Sleep(100);
        }
        else
        {
            await Task.Delay(5, cancellationToken);
        }

        await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
        db.OrderProcessingEvents.Add(new OrderProcessingEvent
        {
            MessageId = message.MessageId,
            OrderId = message.OrderId,
            Outcome = "processed",
            ProcessedAt = DateTimeOffset.UtcNow,
            DurationMs = stopwatch.Elapsed.TotalMilliseconds
        });
        await db.SaveChangesAsync(cancellationToken);

        stopwatch.Stop();
        await channel.BasicAckAsync(eventArgs.DeliveryTag, multiple: false, cancellationToken);
        LabTelemetry.OrdersProcessed.Add(
            1,
            LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId));
        LabTelemetry.OrderProcessingDuration.Record(
            stopwatch.Elapsed.TotalMilliseconds,
            LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId));
        logger.LogInformation(
            "Processed order {OrderId} from message {MessageId} in {DurationMs:F2} ms",
            message.OrderId,
            message.MessageId,
            stopwatch.Elapsed.TotalMilliseconds);
    }

    private static ActivityContext ExtractParentContext(IDictionary<string, object?>? headers)
    {
        if (headers is null || !TryReadHeader(headers, "traceparent", out var traceParent))
        {
            return default;
        }

        _ = TryReadHeader(headers, "tracestate", out var traceState);
        return ActivityContext.TryParse(traceParent, traceState, isRemote: true, out var context)
            ? context
            : default;
    }

    private static bool TryReadHeader(
        IDictionary<string, object?> headers,
        string key,
        out string? value)
    {
        if (headers.TryGetValue(key, out var rawValue) && rawValue is byte[] bytes)
        {
            value = Encoding.UTF8.GetString(bytes);
            return true;
        }

        value = null;
        return false;
    }
}
