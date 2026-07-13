using System.Collections.Concurrent;
using MercadonaRetail.Api.Models;

namespace MercadonaRetail.Api.Services;

public sealed class RetailStateService(CartMemoryRetentionService memoryRetention)
{
    private readonly ConcurrentDictionary<string, Cart> _carts = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, Order> _orders = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<Store> GetStores() => SyntheticCatalog.Stores;

    public IReadOnlyList<Product> GetProducts(string storeId) =>
        SyntheticCatalog.Products
            .Where(product => product.StoreId.Equals(storeId, StringComparison.OrdinalIgnoreCase))
            .ToArray();

    public Cart? GetCart(string cartId)
    {
        return _carts.TryGetValue(cartId, out var cart)
            ? SnapshotCart(cart)
            : null;
    }

    public Cart? CreateCart(string storeId)
    {
        if (!SyntheticCatalog.Stores.Any(store => store.Id.Equals(storeId, StringComparison.OrdinalIgnoreCase)))
        {
            return null;
        }

        var cart = new Cart
        {
            Id = $"CART-{Guid.NewGuid():N}",
            StoreId = storeId,
            CreatedAt = DateTimeOffset.UtcNow
        };
        _carts[cart.Id] = cart;
        return SnapshotCart(cart);
    }

    public AddItemResult AddItem(string cartId, string productId, int quantity, string correlationId)
    {
        if (!_carts.TryGetValue(cartId, out var cart))
        {
            return AddItemResult.Failure("CART_NOT_FOUND");
        }

        if (quantity is < 1 or > 100)
        {
            return AddItemResult.Failure("INVALID_QUANTITY");
        }

        var product = SyntheticCatalog.Products.FirstOrDefault(candidate =>
            candidate.Id.Equals(productId, StringComparison.OrdinalIgnoreCase) &&
            candidate.StoreId.Equals(cart.StoreId, StringComparison.OrdinalIgnoreCase));
        if (product is null)
        {
            return AddItemResult.Failure("PRODUCT_NOT_FOUND");
        }

        lock (cart.Items)
        {
            var existingIndex = cart.Items.FindIndex(item =>
                item.ProductId.Equals(product.Id, StringComparison.OrdinalIgnoreCase));
            if (existingIndex >= 0)
            {
                var existing = cart.Items[existingIndex];
                if (existing.Quantity > 100 - quantity)
                {
                    return AddItemResult.Failure("INVALID_QUANTITY");
                }
                cart.Items[existingIndex] = existing with { Quantity = existing.Quantity + quantity };
            }
            else
            {
                cart.Items.Add(new CartItem(product.Id, product.Name, quantity, product.Price));
            }

            var allocationBytes = memoryRetention.RetainAfterValidAdd(
                correlationId,
                cart.Id,
                cart.StoreId,
                product.Id,
                quantity);
            return AddItemResult.Success(
                SnapshotCartUnsafe(cart),
                allocationBytes,
                memoryRetention.RetainedBytes,
                memoryRetention.MaxRetainedBytes);
        }
    }

    public OrderResult CreateOrder(string cartId)
    {
        if (!_carts.TryGetValue(cartId, out var cart))
        {
            return OrderResult.Failure("CART_NOT_FOUND");
        }

        lock (cart.Items)
        {
            if (cart.Items.Count == 0)
            {
                return OrderResult.Failure("CART_EMPTY");
            }

            var order = new Order
            {
                Id = $"ORDER-{Guid.NewGuid():N}",
                CartId = cart.Id,
                StoreId = cart.StoreId,
                Status = "Preparing",
                TrackingCode = $"TRACK-{Guid.NewGuid():N}",
                CreatedAt = DateTimeOffset.UtcNow,
                Items = cart.Items.ToArray()
            };
            _orders[order.Id] = order;
            return OrderResult.Success(order);
        }
    }

    public TrackingResponse? GetTracking(string orderId)
    {
        if (!_orders.TryGetValue(orderId, out var order))
        {
            return null;
        }

        return new TrackingResponse(
            order.Id,
            order.TrackingCode,
            order.Status,
            DateTimeOffset.UtcNow,
            "Synthetic order is being prepared for the demo.");
    }

    private static Cart SnapshotCart(Cart cart)
    {
        lock (cart.Items)
        {
            return SnapshotCartUnsafe(cart);
        }
    }

    private static Cart SnapshotCartUnsafe(Cart cart)
    {
        var snapshot = new Cart
        {
            Id = cart.Id,
            StoreId = cart.StoreId,
            CreatedAt = cart.CreatedAt
        };
        snapshot.Items.AddRange(cart.Items);
        return snapshot;
    }
}

public sealed record AddItemResult(
    bool IsSuccess,
    string? ErrorCode,
    Cart? Cart,
    long AllocationBytes,
    long RetainedBytes,
    long MaxRetainedBytes)
{
    public static AddItemResult Failure(string errorCode) => new(false, errorCode, null, 0, 0, 0);

    public static AddItemResult Success(Cart cart, long allocationBytes, long retainedBytes, long maxRetainedBytes) =>
        new(true, null, cart, allocationBytes, retainedBytes, maxRetainedBytes);
}

public sealed record OrderResult(bool IsSuccess, string? ErrorCode, Order? Order)
{
    public static OrderResult Failure(string errorCode) => new(false, errorCode, null);

    public static OrderResult Success(Order order) => new(true, null, order);
}
