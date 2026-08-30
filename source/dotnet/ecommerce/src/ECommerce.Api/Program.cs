using System.Diagnostics;
using System.Security.Claims;
using System.Text;
using ECommerce.Api.Auth;
using ECommerce.Api.Configuration;
using ECommerce.Api.Contracts;
using ECommerce.Api.Data;
using ECommerce.Api.Diagnostics;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using Npgsql;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

Activity.DefaultIdFormat = ActivityIdFormat.W3C;
Activity.ForceDefaultIdFormat = true;

var builder = WebApplication.CreateBuilder(args);
var runContext = EcommerceRunContext.FromEnvironment();
var settings = EcommerceSettings.FromEnvironment();
var otlpEndpoint = new Uri(
    Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT") ?? "http://localhost:4317");

builder.Services.AddSingleton(runContext);
builder.Services.AddSingleton(settings);
builder.Services.AddPooledDbContextFactory<EcommerceDbContext>(options =>
    options.UseNpgsql(settings.PostgreSql, npgsql => npgsql.CommandTimeout(5)));
builder.Services.AddSingleton<DatabaseSeeder>();
builder.Services.AddSingleton<TokenService>();
builder.Services.AddProblemDetails();

var signingKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(settings.JwtKey));
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        // Keep claim types as issued ("sub"/"name"/"role") instead of the legacy
        // SOAP URIs, so endpoints read principal.FindFirstValue("sub") directly.
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = settings.JwtIssuer,
            ValidateAudience = true,
            ValidAudience = settings.JwtAudience,
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = signingKey,
            ValidateLifetime = true,
            NameClaimType = "name",
            RoleClaimType = "role",
            ClockSkew = TimeSpan.FromSeconds(30)
        };
    });
builder.Services.AddAuthorization();

var resourceAttributes = new Dictionary<string, object>
{
    ["deployment.environment.name"] = "local-poc",
    ["perf.run.id"] = runContext.RunId,
    ["scenario.id"] = runContext.ScenarioId,
    ["perf.run.mode"] = runContext.RunMode
};

builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource
        .AddService(
            serviceName: "ecommerce-api",
            serviceVersion: Environment.GetEnvironmentVariable("SERVICE_VERSION") ?? "dev")
        .AddAttributes(resourceAttributes))
    .WithTracing(tracing => tracing
        .AddSource(AppTelemetry.SourceName)
        .AddAspNetCoreInstrumentation(options =>
        {
            options.Filter = context => !context.Request.Path.StartsWithSegments("/health");
            options.RecordException = true;
        })
        .AddHttpClientInstrumentation(options => options.RecordException = true)
        .AddNpgsql()
        .AddOtlpExporter(options => options.Endpoint = otlpEndpoint))
    .WithMetrics(metrics => metrics
        .AddMeter(AppTelemetry.MeterName, "Npgsql", "System.Net.Http")
        .AddAspNetCoreInstrumentation()
        .AddRuntimeInstrumentation()
        .AddOtlpExporter(options => options.Endpoint = otlpEndpoint));

builder.Logging.AddOpenTelemetry(logging =>
{
    logging.IncludeFormattedMessage = true;
    logging.IncludeScopes = true;
    logging.ParseStateValues = true;
    logging.SetResourceBuilder(ResourceBuilder.CreateDefault()
        .AddService("ecommerce-api")
        .AddAttributes(resourceAttributes));
    logging.AddOtlpExporter((exporterOptions, processorOptions) =>
    {
        exporterOptions.Endpoint = otlpEndpoint;
        processorOptions.BatchExportProcessorOptions.MaxQueueSize = 20_000;
        processorOptions.BatchExportProcessorOptions.MaxExportBatchSize = 2_048;
    });
});

var app = builder.Build();
app.UseExceptionHandler();
app.UseAuthentication();
app.UseAuthorization();

app.Use(async (httpContext, next) =>
{
    Activity.Current?.SetTag("perf.run.id", runContext.RunId);
    Activity.Current?.SetTag("scenario.id", runContext.ScenarioId);
    httpContext.Response.Headers["X-Perf-Run-Id"] = runContext.RunId;
    httpContext.Response.Headers["X-Perf-Scenario"] = runContext.ScenarioId;

    if (!httpContext.Request.Path.StartsWithSegments("/health"))
    {
        AppTelemetry.ScenarioExecutions.Add(
            1,
            new KeyValuePair<string, object?>("scenario.id", runContext.ScenarioId),
            new KeyValuePair<string, object?>("perf.run.id", runContext.RunId));
    }

    using var scope = app.Logger.BeginScope(new Dictionary<string, object>
    {
        ["perf.run.id"] = runContext.RunId,
        ["scenario.id"] = runContext.ScenarioId,
        ["perf.run.mode"] = runContext.RunMode
    });
    await next(httpContext);
});

static int CurrentUserId(ClaimsPrincipal principal) =>
    int.TryParse(principal.FindFirstValue("sub"), out var id) ? id : 0;

app.MapGet("/", () => Results.Ok(new
{
    service = "ecommerce-api",
    scenario = runContext.ScenarioId,
    runId = runContext.RunId,
    mode = runContext.RunMode
}));

app.MapGet("/health/live", () => Results.Ok(new { status = "live" }));

app.MapGet("/health/ready", async (
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    await db.Database.ExecuteSqlRawAsync("SELECT 1", cancellationToken);
    return Results.Ok(new { status = "ready", postgres = "ok" });
});

// ---- Auth (public) ----
app.MapPost("/api/auth/login", async (
    LoginRequest request,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    TokenService tokens,
    EcommerceSettings cfg,
    CancellationToken cancellationToken) =>
{
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    var user = await db.Users.AsNoTracking()
        .FirstOrDefaultAsync(u => u.Username == request.Username, cancellationToken);

    if (user is null || !PasswordHasher.Verify(request.Password, user.PasswordHash))
    {
        AppTelemetry.AuthFailures.Add(1);
        return Results.Problem(statusCode: StatusCodes.Status401Unauthorized, title: "Invalid credentials");
    }

    AppTelemetry.Logins.Add(1);
    var token = tokens.Issue(user);
    return Results.Ok(new LoginResponse(token, cfg.JwtLifetimeMinutes * 60));
});

// ---- Protected API ----
var api = app.MapGroup("/api").RequireAuthorization();

api.MapGet("/products", async (
    int? page, int? pageSize, string? search,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    var p = Math.Clamp(page ?? 1, 1, 100_000);
    var ps = Math.Clamp(pageSize ?? 25, 1, 100);
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);

    var query = db.Products.AsNoTracking().Where(x => x.IsActive);
    if (!string.IsNullOrWhiteSpace(search))
    {
        query = query.Where(x => EF.Functions.ILike(x.Name, $"%{search}%"));
    }

    var total = await query.LongCountAsync(cancellationToken);
    var items = await query
        .OrderBy(x => x.Id)
        .Skip((p - 1) * ps)
        .Take(ps)
        .Select(x => new ProductResponse(x.Id, x.Name, x.Description, x.Price, x.Stock, x.CategoryId))
        .ToListAsync(cancellationToken);

    return Results.Ok(new PagedResponse<ProductResponse>(items, p, ps, total));
});

api.MapGet("/products/{id:int}", async (
    int id,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    var x = await db.Products.AsNoTracking().FirstOrDefaultAsync(p => p.Id == id, cancellationToken);
    return x is null
        ? Results.NotFound()
        : Results.Ok(new ProductResponse(x.Id, x.Name, x.Description, x.Price, x.Stock, x.CategoryId));
});

api.MapPost("/products", async (
    CreateProductRequest request,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    var product = new Product
    {
        CategoryId = Math.Clamp(request.CategoryId, 1, 20),
        Name = request.Name,
        Description = request.Description,
        Price = request.Price,
        Stock = request.Stock,
        IsActive = true,
        CreatedAt = DateTimeOffset.UtcNow
    };
    db.Products.Add(product);
    await db.SaveChangesAsync(cancellationToken);
    return Results.Created(
        $"/api/products/{product.Id}",
        new ProductResponse(product.Id, product.Name, product.Description, product.Price, product.Stock, product.CategoryId));
});

api.MapPatch("/products/{id:int}", async (
    int id,
    UpdateProductRequest request,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    var product = await db.Products.FirstOrDefaultAsync(p => p.Id == id, cancellationToken);
    if (product is null)
    {
        return Results.NotFound();
    }

    if (request.Price is { } price)
    {
        product.Price = price;
    }
    if (request.Stock is { } stock)
    {
        product.Stock = stock;
    }
    if (request.IsActive is { } active)
    {
        product.IsActive = active;
    }

    await db.SaveChangesAsync(cancellationToken);
    return Results.Ok(
        new ProductResponse(product.Id, product.Name, product.Description, product.Price, product.Stock, product.CategoryId));
});

api.MapGet("/orders", async (
    ClaimsPrincipal principal, int? page, int? pageSize,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    var userId = CurrentUserId(principal);
    var p = Math.Clamp(page ?? 1, 1, 100_000);
    var ps = Math.Clamp(pageSize ?? 25, 1, 100);
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);

    var query = db.Orders.AsNoTracking().Where(o => o.UserId == userId);
    var total = await query.LongCountAsync(cancellationToken);
    var items = await query
        .OrderByDescending(o => o.CreatedAt)
        .ThenByDescending(o => o.Id)
        .Skip((p - 1) * ps)
        .Take(ps)
        .Select(o => new OrderResponse(o.Id, o.CreatedAt, o.Total, o.Status))
        .ToListAsync(cancellationToken);

    return Results.Ok(new PagedResponse<OrderResponse>(items, p, ps, total));
});

api.MapGet("/orders/{id:long}", async (
    long id, ClaimsPrincipal principal,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    var userId = CurrentUserId(principal);
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    var order = await db.Orders.AsNoTracking()
        .Include(o => o.Items)
        .FirstOrDefaultAsync(o => o.Id == id && o.UserId == userId, cancellationToken);
    if (order is null)
    {
        return Results.NotFound();
    }

    var items = order.Items
        .Select(i => new OrderItemResponse(i.ProductId, i.Quantity, i.UnitPrice))
        .ToList();
    return Results.Ok(new OrderDetailResponse(order.Id, order.CreatedAt, order.Total, order.Status, items));
});

api.MapPost("/orders", async (
    CreateOrderRequest request, ClaimsPrincipal principal,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    var userId = CurrentUserId(principal);
    if (request.Items is null || request.Items.Count == 0)
    {
        return Results.BadRequest(new { error = "order must contain at least one item" });
    }

    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    var productIds = request.Items.Select(i => i.ProductId).Distinct().ToList();
    var products = await db.Products.AsNoTracking()
        .Where(p => productIds.Contains(p.Id))
        .ToDictionaryAsync(p => p.Id, cancellationToken);

    var order = new Order
    {
        UserId = userId,
        CreatedAt = DateTimeOffset.UtcNow,
        Status = "pending",
        Items = []
    };

    decimal total = 0m;
    foreach (var item in request.Items)
    {
        if (!products.TryGetValue(item.ProductId, out var product))
        {
            return Results.BadRequest(new { error = $"unknown product {item.ProductId}" });
        }

        var quantity = Math.Clamp(item.Quantity, 1, 100);
        order.Items.Add(new OrderItem
        {
            ProductId = product.Id,
            Quantity = quantity,
            UnitPrice = product.Price
        });
        total += product.Price * quantity;
    }

    order.Total = total;
    db.Orders.Add(order);
    await db.SaveChangesAsync(cancellationToken);
    AppTelemetry.OrdersCreated.Add(1);

    return Results.Created(
        $"/api/orders/{order.Id}",
        new OrderResponse(order.Id, order.CreatedAt, order.Total, order.Status));
});

api.MapGet("/users/me", async (
    ClaimsPrincipal principal,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    var userId = CurrentUserId(principal);
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    var user = await db.Users.AsNoTracking().FirstOrDefaultAsync(u => u.Id == userId, cancellationToken);
    return user is null
        ? Results.NotFound()
        : Results.Ok(new UserResponse(user.Id, user.Username, user.Email, user.Role));
});

api.MapGet("/users", async (
    int? page, int? pageSize,
    IDbContextFactory<EcommerceDbContext> contextFactory,
    CancellationToken cancellationToken) =>
{
    var p = Math.Clamp(page ?? 1, 1, 100_000);
    var ps = Math.Clamp(pageSize ?? 25, 1, 100);
    await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
    var query = db.Users.AsNoTracking();
    var total = await query.LongCountAsync(cancellationToken);
    var items = await query
        .OrderBy(u => u.Id)
        .Skip((p - 1) * ps)
        .Take(ps)
        .Select(u => new UserResponse(u.Id, u.Username, u.Email, u.Role))
        .ToListAsync(cancellationToken);
    return Results.Ok(new PagedResponse<UserResponse>(items, p, ps, total));
});

await using (var seedScope = app.Services.CreateAsyncScope())
{
    var seeder = seedScope.ServiceProvider.GetRequiredService<DatabaseSeeder>();
    await seeder.InitializeAsync();
}

app.Logger.LogInformation(
    "ECommerce API starting with scenario {ScenarioId}, run {RunId}, mode {RunMode}",
    runContext.ScenarioId,
    runContext.RunId,
    runContext.RunMode);

await app.RunAsync();
