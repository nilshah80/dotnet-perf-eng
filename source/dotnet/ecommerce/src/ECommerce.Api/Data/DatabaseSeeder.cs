using ECommerce.Api.Auth;
using Microsoft.EntityFrameworkCore;

namespace ECommerce.Api.Data;

// Seeds a known dataset at startup so protected reads (GET/GET-all with
// pagination) run against present data without a create-first step -- the same
// "seed, don't chain" pattern the reference lab uses. Seeded users share the
// password "Password123!"; user1 is the admin the load generator logs in as, and
// ~25% of orders belong to user1 so deep order pagination is meaningful.
public sealed class DatabaseSeeder(
    IDbContextFactory<EcommerceDbContext> contextFactory,
    ILogger<DatabaseSeeder> logger)
{
    public const string SeedPassword = "Password123!";

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
        var (products, users, orders) = scale switch
        {
            "demo" => (100_000, 2_000, 200_000),
            "smoke" => (20_000, 200, 20_000),
            _ => throw new InvalidOperationException("SEED_SCALE must be 'smoke' or 'demo'.")
        };

        logger.LogInformation(
            "Seeding {Scale} dataset: {Products} products, {Users} users, {Orders} orders",
            scale, products, users, orders);

        // Bulk demo seeding exceeds the five-second request command timeout.
        // Keep the larger budget on this startup context only, and commit all
        // rows together so a failed attempt cannot look like a complete seed.
        var requestTimeout = db.Database.GetCommandTimeout();
        try
        {
            db.Database.SetCommandTimeout(TimeSpan.FromMinutes(3));
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var passwordHash = PasswordHasher.Hash(SeedPassword);

            await db.Database.ExecuteSqlRawAsync(
                "INSERT INTO categories (id, name) SELECT n, 'Category ' || n FROM generate_series(1, 20) AS n;",
                cancellationToken);

            await db.Database.ExecuteSqlInterpolatedAsync(
                $"""
                INSERT INTO users (id, username, password_hash, role, email)
                SELECT n,
                       'user' || n,
                       {passwordHash},
                       CASE WHEN n = 1 THEN 'admin' ELSE 'user' END,
                       'user' || n || '@example.test'
                FROM generate_series(1, {users}) AS n;
                """,
                cancellationToken);

            await db.Database.ExecuteSqlInterpolatedAsync(
                $"""
                INSERT INTO products (id, category_id, name, description, price, stock, is_active, created_at)
                SELECT n,
                       1 + (n % 20),
                       'Product ' || n,
                       'Description for product ' || n || ' ' || repeat('feature-' || (n % 97) || ' ', 8),
                       round((5 + (n % 5000) / 10.0)::numeric, 2),
                       10 + (n % 500),
                       true,
                       now() - ((n % 365) || ' days')::interval
                FROM generate_series(1, {products}) AS n;
                """,
                cancellationToken);

            await db.Database.ExecuteSqlInterpolatedAsync(
                $"""
                INSERT INTO orders (id, user_id, created_at, total, status)
                SELECT n,
                       CASE WHEN n % 4 = 0 THEN 1 ELSE 1 + (n % {users}) END,
                       now() - ((n % 720) || ' hours')::interval,
                       round((20 + (n % 25000) / 100.0)::numeric, 2),
                       CASE WHEN n % 11 = 0 THEN 'pending' ELSE 'completed' END
                FROM generate_series(1, {orders}) AS n;

                INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
                SELECT ((o.id - 1) * 3) + item_no,
                       o.id,
                       1 + ((o.id * 17 + item_no * 31) % {products}),
                       1 + ((o.id + item_no) % 3),
                       round((5 + ((o.id + item_no) % 5000) / 10.0)::numeric, 2)
                FROM orders AS o
                CROSS JOIN generate_series(1, 3) AS item_no;

                SELECT setval(pg_get_serial_sequence('products', 'id'), (SELECT max(id) FROM products), true);
                SELECT setval(pg_get_serial_sequence('users', 'id'), (SELECT max(id) FROM users), true);
                SELECT setval(pg_get_serial_sequence('orders', 'id'), (SELECT max(id) FROM orders), true);
                SELECT setval(pg_get_serial_sequence('order_items', 'id'), (SELECT max(id) FROM order_items), true);
                ANALYZE;
                """,
                cancellationToken);

            await transaction.CommitAsync(cancellationToken);
        }
        finally
        {
            db.Database.SetCommandTimeout(requestTimeout);
        }

        logger.LogInformation("Database seed completed");
    }
}
