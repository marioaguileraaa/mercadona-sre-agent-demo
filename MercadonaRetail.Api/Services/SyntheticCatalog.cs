using MercadonaRetail.Api.Models;

namespace MercadonaRetail.Api.Services;

public static class SyntheticCatalog
{
    public static readonly IReadOnlyList<Store> Stores =
    [
        new("store-river", "Mercado Río Verde", "Distrito Demo de Valencia", "Recogida sintética en el día"),
        new("store-orchard", "Mercado Huerta Soleada", "Distrito Demo de Madrid", "Entrega sintética programada"),
        new("store-harbour", "Mercado Cesta del Puerto", "Distrito Demo de Alicante", "Recogida exprés sintética")
    ];

    public static readonly IReadOnlyList<Product> Products =
    [
        new("product-apples", "store-river", "Manzanas crujientes", "Fruta y verdura", 2.35m, "1 kg", "apple"),
        new("product-tomatoes", "store-river", "Tomates de ensalada", "Fruta y verdura", 1.95m, "750 g", "produce"),
        new("product-rice", "store-river", "Arroz de grano largo", "Despensa", 1.60m, "1 kg", "pantry"),
        new("product-soap", "store-river", "Jabón de manos suave", "Hogar", 2.10m, "500 ml", "home"),
        new("product-bananas", "store-orchard", "Plátanos maduros", "Fruta y verdura", 1.75m, "1 kg", "produce"),
        new("product-pasta", "store-orchard", "Pasta de trigo duro", "Despensa", 1.20m, "500 g", "pantry"),
        new("product-oats", "store-orchard", "Copos de avena integrales", "Despensa", 1.85m, "500 g", "pantry"),
        new("product-cleaner", "store-orchard", "Limpiador multiusos", "Hogar", 2.80m, "750 ml", "home"),
        new("product-pears", "store-harbour", "Peras conferencia", "Fruta y verdura", 2.45m, "1 kg", "produce"),
        new("product-beans", "store-harbour", "Alubias blancas cocidas", "Despensa", 1.10m, "400 g", "pantry"),
        new("product-tissues", "store-harbour", "Pañuelos de papel reciclado", "Hogar", 1.90m, "12 paquetes", "home"),
        new("product-water", "store-harbour", "Agua mineral sin gas", "Despensa", 2.20m, "6 x 1,5 L", "pantry")
    ];
}
