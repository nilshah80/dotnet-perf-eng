namespace ECommerce.Api.Contracts;

public sealed record LoginRequest(string Username, string Password);

public sealed record LoginResponse(string Token, int ExpiresInSeconds);

public sealed record ProductResponse(
    int Id, string Name, string Description, decimal Price, int Stock, int CategoryId);

public sealed record CreateProductRequest(
    string Name, string Description, decimal Price, int Stock, int CategoryId);

public sealed record UpdateProductRequest(decimal? Price, int? Stock, bool? IsActive);

public sealed record OrderResponse(long Id, DateTimeOffset CreatedAt, decimal Total, string Status);

public sealed record OrderItemResponse(int ProductId, int Quantity, decimal UnitPrice);

public sealed record OrderDetailResponse(
    long Id, DateTimeOffset CreatedAt, decimal Total, string Status, IReadOnlyList<OrderItemResponse> Items);

public sealed record CreateOrderItem(int ProductId, int Quantity);

public sealed record CreateOrderRequest(IReadOnlyList<CreateOrderItem> Items);

public sealed record UserResponse(int Id, string Username, string Email, string Role);

public sealed record PagedResponse<T>(IReadOnlyList<T> Items, int Page, int PageSize, long Total);
