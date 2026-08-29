using Microsoft.EntityFrameworkCore;

namespace PerfLab.Shared.Data;

public sealed class LabDbContext(DbContextOptions<LabDbContext> options) : DbContext(options)
{
    public DbSet<Category> Categories => Set<Category>();
    public DbSet<Customer> Customers => Set<Customer>();
    public DbSet<Product> Products => Set<Product>();
    public DbSet<Inventory> Inventory => Set<Inventory>();
    public DbSet<Order> Orders => Set<Order>();
    public DbSet<OrderItem> OrderItems => Set<OrderItem>();
    public DbSet<OrderProcessingEvent> OrderProcessingEvents => Set<OrderProcessingEvent>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Category>(entity =>
        {
            entity.ToTable("categories");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Id).HasColumnName("id");
            entity.Property(x => x.Name).HasColumnName("name").HasMaxLength(100);
        });

        modelBuilder.Entity<Customer>(entity =>
        {
            entity.ToTable("customers");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Id).HasColumnName("id");
            entity.Property(x => x.Name).HasColumnName("name").HasMaxLength(150);
            entity.Property(x => x.Email).HasColumnName("email").HasMaxLength(200);
            entity.HasIndex(x => x.Email).IsUnique();
        });

        modelBuilder.Entity<Product>(entity =>
        {
            entity.ToTable("products");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Id).HasColumnName("id");
            entity.Property(x => x.CategoryId).HasColumnName("category_id");
            entity.Property(x => x.Name).HasColumnName("name").HasMaxLength(200);
            entity.Property(x => x.SearchText).HasColumnName("search_text").HasMaxLength(600);
            entity.Property(x => x.Price).HasColumnName("price").HasPrecision(12, 2);
            entity.Property(x => x.IsActive).HasColumnName("is_active");
            entity.HasIndex(x => x.CategoryId);
        });

        modelBuilder.Entity<Inventory>(entity =>
        {
            entity.ToTable("inventory");
            entity.HasKey(x => x.ProductId);
            entity.Property(x => x.ProductId).HasColumnName("product_id").ValueGeneratedNever();
            entity.Property(x => x.Quantity).HasColumnName("quantity");
            entity.Property(x => x.UpdatedAt).HasColumnName("updated_at");
        });

        modelBuilder.Entity<Order>(entity =>
        {
            entity.ToTable("orders");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Id).HasColumnName("id");
            entity.Property(x => x.CustomerId).HasColumnName("customer_id");
            entity.Property(x => x.CreatedAt).HasColumnName("created_at");
            entity.Property(x => x.Total).HasColumnName("total").HasPrecision(12, 2);
            entity.Property(x => x.Status).HasColumnName("status").HasMaxLength(40);
            entity.HasIndex(x => x.CustomerId);
            entity.HasMany(x => x.Items)
                .WithOne()
                .HasForeignKey(x => x.OrderId);
        });

        modelBuilder.Entity<OrderItem>(entity =>
        {
            entity.ToTable("order_items");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Id).HasColumnName("id");
            entity.Property(x => x.OrderId).HasColumnName("order_id");
            entity.Property(x => x.ProductId).HasColumnName("product_id");
            entity.Property(x => x.Quantity).HasColumnName("quantity");
            entity.Property(x => x.UnitPrice).HasColumnName("unit_price").HasPrecision(12, 2);
            entity.HasIndex(x => x.OrderId);
        });

        modelBuilder.Entity<OrderProcessingEvent>(entity =>
        {
            entity.ToTable("order_processing_events");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Id).HasColumnName("id");
            entity.Property(x => x.MessageId).HasColumnName("message_id").HasMaxLength(100);
            entity.Property(x => x.OrderId).HasColumnName("order_id");
            entity.Property(x => x.Outcome).HasColumnName("outcome").HasMaxLength(50);
            entity.Property(x => x.ProcessedAt).HasColumnName("processed_at");
            entity.Property(x => x.DurationMs).HasColumnName("duration_ms");
            entity.HasIndex(x => x.MessageId);
        });
    }
}

