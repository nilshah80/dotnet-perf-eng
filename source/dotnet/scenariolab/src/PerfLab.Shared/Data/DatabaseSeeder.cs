using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;

namespace PerfLab.Shared.Data;

public sealed class DatabaseSeeder(
    IDbContextFactory<LabDbContext> contextFactory,
    ILogger<DatabaseSeeder> logger)
{
    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await db.Database.EnsureCreatedAsync(cancellationToken);

        if (await db.Products.AsNoTracking().AnyAsync(cancellationToken))
        {
            logger.LogInformation("Database already contains seed data");
            return;
        }

        var scale = (Environment.GetEnvironmentVariable("SEED_SCALE") ?? "smoke").ToLowerInvariant();
        var (products, customers, orders) = scale switch
        {
            "demo" => (100_000, 10_000, 200_000),
            "smoke" => (20_000, 2_000, 20_000),
            _ => throw new InvalidOperationException("SEED_SCALE must be 'smoke' or 'demo'.")
        };

        logger.LogInformation(
            "Seeding {Scale} dataset: {Products} products, {Customers} customers, {Orders} orders",
            scale,
            products,
            customers,
            orders);

        await db.Database.ExecuteSqlRawAsync(
            """
            INSERT INTO categories (id, name)
            SELECT n, 'Category ' || n
            FROM generate_series(1, 20) AS n;
            """,
            cancellationToken);

        await db.Database.ExecuteSqlInterpolatedAsync(
            $"""
            INSERT INTO customers (id, name, email)
            SELECT n, 'Customer ' || n, 'customer-' || n || '@example.test'
            FROM generate_series(1, {customers}) AS n;
            """,
            cancellationToken);

        await db.Database.ExecuteSqlInterpolatedAsync(
            $"""
            INSERT INTO products (id, category_id, name, search_text, price, is_active)
            SELECT n,
                   1 + (n % 20),
                   'Product ' || n,
                   repeat('feature-' || (n % 97) || ' ', 12),
                   round((5 + (n % 5000) / 10.0)::numeric, 2),
                   true
            FROM generate_series(1, {products}) AS n;

            INSERT INTO inventory (product_id, quantity, updated_at)
            SELECT n, 20 + (n % 200), now()
            FROM generate_series(1, {products}) AS n;
            """,
            cancellationToken);

        await db.Database.ExecuteSqlInterpolatedAsync(
            $"""
            INSERT INTO orders (id, customer_id, created_at, total, status)
            SELECT n,
                   CASE WHEN n % 5 = 0 THEN 1 ELSE 1 + (n % {customers}) END,
                   now() - ((n % 730) || ' hours')::interval,
                   round((20 + (n % 25000) / 100.0)::numeric, 2),
                   CASE WHEN n % 13 = 0 THEN 'processing' ELSE 'completed' END
            FROM generate_series(1, {orders}) AS n;

            INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
            SELECT ((o.id - 1) * 3) + item_no,
                   o.id,
                   1 + ((o.id * 17 + item_no * 31) % {products}),
                   1 + ((o.id + item_no) % 3),
                   round((5 + ((o.id + item_no) % 5000) / 10.0)::numeric, 2)
            FROM orders AS o
            CROSS JOIN generate_series(1, 3) AS item_no;

            SELECT setval(pg_get_serial_sequence('orders', 'id'), (SELECT max(id) FROM orders), true);
            SELECT setval(pg_get_serial_sequence('order_items', 'id'), (SELECT max(id) FROM order_items), true);
            ANALYZE;
            """,
            cancellationToken);

        logger.LogInformation("Database seed completed");
    }
}
