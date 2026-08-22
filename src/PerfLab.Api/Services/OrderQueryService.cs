using System.Collections.Concurrent;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using PerfLab.Api.Contracts;
using PerfLab.Shared.Configuration;
using PerfLab.Shared.Data;
using PerfLab.Shared.Diagnostics;

namespace PerfLab.Api.Services;

public sealed class OrderQueryService(
    IDbContextFactory<LabDbContext> contextFactory,
    NpgsqlDataSource dataSource,
    LabRunContext runContext)
{
    private static readonly ConcurrentBag<NpgsqlConnection> RetainedConnections = [];

    public async Task<IReadOnlyList<OrderResult>> GetOrdersAsync(
        int customerId,
        int page,
        int pageSize,
        CancellationToken cancellationToken)
    {
        LabTelemetry.ScenarioExecutions.Add(
            1,
            LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId));

        using var activity = LabTelemetry.ActivitySource.StartActivity("orders.query");
        activity?.SetTag("customer.id", customerId);
        activity?.SetTag("orders.page", page);
        activity?.SetTag("orders.page_size", pageSize);

        if (runContext.Is("S09"))
        {
            return await ExecuteWithRetainedConnectionAsync(customerId, pageSize, cancellationToken);
        }

        await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);

        if (runContext.Is("S07"))
        {
            var orders = await db.Orders
                .AsNoTracking()
                .Where(x => x.CustomerId == customerId)
                .OrderByDescending(x => x.CreatedAt)
                .Take(pageSize)
                .ToListAsync(cancellationToken);

            var result = new List<OrderResult>(orders.Count);
            foreach (var order in orders)
            {
                var items = await db.OrderItems
                    .AsNoTracking()
                    .Where(x => x.OrderId == order.Id)
                    .Select(x => new OrderItemResult(x.ProductId, x.Quantity, x.UnitPrice))
                    .ToListAsync(cancellationToken);

                result.Add(ToResult(order, items));
            }

            return result;
        }

        if (runContext.Is("S11"))
        {
            var trackedGraph = await db.Orders
                .Include(x => x.Items)
                .Where(x => x.CustomerId == customerId)
                .OrderByDescending(x => x.CreatedAt)
                .ToListAsync(cancellationToken);

            return trackedGraph
                .Skip((page - 1) * pageSize)
                .Take(pageSize)
                .Select(x => ToResult(
                    x,
                    x.Items.Select(i => new OrderItemResult(i.ProductId, i.Quantity, i.UnitPrice)).ToArray()))
                .ToArray();
        }

        var effectivePage = runContext.Is("S08") ? Math.Max(page, 100) : page;
        var pageOfOrders = await db.Orders
            .AsNoTracking()
            .AsSplitQuery()
            .Include(x => x.Items)
            .Where(x => x.CustomerId == customerId)
            .OrderByDescending(x => x.CreatedAt)
            .ThenByDescending(x => x.Id)
            .Skip((effectivePage - 1) * pageSize)
            .Take(pageSize)
            .ToListAsync(cancellationToken);

        return pageOfOrders
            .Select(x => ToResult(
                x,
                x.Items.Select(i => new OrderItemResult(i.ProductId, i.Quantity, i.UnitPrice)).ToArray()))
            .ToArray();
    }

    private async Task<IReadOnlyList<OrderResult>> ExecuteWithRetainedConnectionAsync(
        int customerId,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var connection = await dataSource.OpenConnectionAsync(CancellationToken.None);
        RetainedConnections.Add(connection);

        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT id, created_at, total, status
            FROM orders
            WHERE customer_id = $1
            ORDER BY created_at DESC
            LIMIT $2
            """;
        command.Parameters.AddWithValue(customerId);
        command.Parameters.AddWithValue(pageSize);

        var result = new List<OrderResult>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new OrderResult(
                reader.GetInt64(0),
                reader.GetFieldValue<DateTimeOffset>(1),
                reader.GetDecimal(2),
                reader.GetString(3),
                []));
        }

        return result;
    }

    private static OrderResult ToResult(Order order, IReadOnlyList<OrderItemResult> items) =>
        new(order.Id, order.CreatedAt, order.Total, order.Status, items);
}
