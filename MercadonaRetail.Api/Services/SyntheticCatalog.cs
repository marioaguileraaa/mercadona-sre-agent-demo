using MercadonaRetail.Api.Models;

namespace MercadonaRetail.Api.Services;

public static class SyntheticCatalog
{
    public static readonly IReadOnlyList<Store> Stores =
    [
        new("store-river", "Green River Market", "Valencia Demo District", "Synthetic same-day collection"),
        new("store-orchard", "Sunny Orchard Market", "Madrid Demo District", "Synthetic scheduled delivery"),
        new("store-harbour", "Harbour Basket Market", "Alicante Demo District", "Synthetic express collection")
    ];

    public static readonly IReadOnlyList<Product> Products =
    [
        new("product-apples", "store-river", "Crisp apples", "Produce", 2.35m, "1 kg", "apple"),
        new("product-tomatoes", "store-river", "Salad tomatoes", "Produce", 1.95m, "750 g", "produce"),
        new("product-rice", "store-river", "Long grain rice", "Pantry", 1.60m, "1 kg", "pantry"),
        new("product-soap", "store-river", "Gentle hand soap", "Household", 2.10m, "500 ml", "home"),
        new("product-bananas", "store-orchard", "Ripe bananas", "Produce", 1.75m, "1 kg", "produce"),
        new("product-pasta", "store-orchard", "Durum wheat pasta", "Pantry", 1.20m, "500 g", "pantry"),
        new("product-oats", "store-orchard", "Wholegrain oats", "Pantry", 1.85m, "500 g", "pantry"),
        new("product-cleaner", "store-orchard", "Multipurpose cleaner", "Household", 2.80m, "750 ml", "home"),
        new("product-pears", "store-harbour", "Conference pears", "Produce", 2.45m, "1 kg", "produce"),
        new("product-beans", "store-harbour", "Cooked white beans", "Pantry", 1.10m, "400 g", "pantry"),
        new("product-tissues", "store-harbour", "Recycled paper tissues", "Household", 1.90m, "12 packs", "home"),
        new("product-water", "store-harbour", "Still mineral water", "Pantry", 2.20m, "6 x 1.5 L", "pantry")
    ];
}
