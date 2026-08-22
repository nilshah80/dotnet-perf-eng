namespace PerfLab.Shared.Data;

public sealed class Category
{
    public int Id { get; set; }
    public required string Name { get; set; }
}

public sealed class Customer
{
    public int Id { get; set; }
    public required string Name { get; set; }
    public required string Email { get; set; }
}

public sealed class Product
{
    public int Id { get; set; }
    public int CategoryId { get; set; }
    public required string Name { get; set; }
    public required string SearchText { get; set; }
    public decimal Price { get; set; }
    public bool IsActive { get; set; }
}

public sealed class Inventory
{
    public int ProductId { get; set; }
    public int Quantity { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class Order
{
    public long Id { get; set; }
    public int CustomerId { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public decimal Total { get; set; }
    public required string Status { get; set; }
    public List<OrderItem> Items { get; set; } = [];
}

public sealed class OrderItem
{
    public long Id { get; set; }
    public long OrderId { get; set; }
    public int ProductId { get; set; }
    public int Quantity { get; set; }
    public decimal UnitPrice { get; set; }
}

public sealed class OrderProcessingEvent
{
    public long Id { get; set; }
    public required string MessageId { get; set; }
    public long OrderId { get; set; }
    public required string Outcome { get; set; }
    public DateTimeOffset ProcessedAt { get; set; }
    public double DurationMs { get; set; }
}

