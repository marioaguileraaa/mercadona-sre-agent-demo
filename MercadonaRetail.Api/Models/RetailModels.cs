namespace MercadonaRetail.Api.Models;

public sealed record Store(string Id, string Name, string Area, string FulfilmentNote);

public sealed record Product(
    string Id,
    string StoreId,
    string Name,
    string Category,
    decimal Price,
    string Unit,
    string Icon);

public sealed class Cart
{
    public required string Id { get; init; }
    public required string StoreId { get; init; }
    public DateTimeOffset CreatedAt { get; init; }
    public List<CartItem> Items { get; } = [];
}

public sealed record CartItem(string ProductId, string Name, int Quantity, decimal UnitPrice)
{
    public decimal LineTotal => UnitPrice * Quantity;
}

public sealed class Order
{
    public required string Id { get; init; }
    public required string CartId { get; init; }
    public required string StoreId { get; init; }
    public required string Status { get; init; }
    public required string TrackingCode { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }
    public required IReadOnlyList<CartItem> Items { get; init; }
    public decimal Total => Items.Sum(item => item.LineTotal);
}

public sealed record CreateCartRequest(string StoreId);

public sealed record AddCartItemRequest(string ProductId, int Quantity);

public sealed record CreateOrderRequest(string CartId);

public sealed record TrackingResponse(
    string OrderId,
    string TrackingCode,
    string Status,
    DateTimeOffset UpdatedAt,
    string Message);
