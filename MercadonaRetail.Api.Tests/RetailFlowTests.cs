using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using MercadonaRetail.Api.Models;
using MercadonaRetail.Api.Options;
using MercadonaRetail.Api.Services;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace MercadonaRetail.Api.Tests;

public sealed class RetailFlowTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public RetailFlowTests(WebApplicationFactory<Program> factory)
    {
        _factory = factory.WithWebHostBuilder(builder =>
        {
            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<CartMemoryRetentionService>();
                services.AddSingleton(CreateRetention(0, 640));
            });
        });
    }

    [Fact]
    public async Task HealthyCartOrderAndTrackingFlowWorks()
    {
        using var client = _factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
        var cart = await CreateCart(client);

        var add = await client.PostAsJsonAsync(
            $"/api/carts/{cart}/items",
            new AddCartItemRequest("product-apples", 2));
        Assert.Equal(HttpStatusCode.OK, add.StatusCode);

        var orderResponse = await client.PostAsJsonAsync("/api/orders", new CreateOrderRequest(cart));
        Assert.Equal(HttpStatusCode.Created, orderResponse.StatusCode);
        var orderJson = await ReadJson(orderResponse);
        var orderId = orderJson.GetProperty("order").GetProperty("id").GetString();
        Assert.False(string.IsNullOrWhiteSpace(orderId));

        var tracking = await client.GetAsync($"/api/orders/{orderId}/tracking");
        Assert.Equal(HttpStatusCode.OK, tracking.StatusCode);
    }

    [Fact]
    public async Task InvalidCartAndProductDoNotAllocate()
    {
        var retention = CreateRetention(10, 640);
        using var app = _factory.WithWebHostBuilder(builder =>
        {
            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<CartMemoryRetentionService>();
                services.AddSingleton(retention);
            });
        });
        using var client = app.CreateClient();

        var missingCart = await client.PostAsJsonAsync(
            "/api/carts/CART-MISSING/items",
            new AddCartItemRequest("product-apples", 1));
        Assert.Equal(HttpStatusCode.NotFound, missingCart.StatusCode);

        var cart = await CreateCart(client);
        var missingProduct = await client.PostAsJsonAsync(
            $"/api/carts/{cart}/items",
            new AddCartItemRequest("product-missing", 1));
        Assert.Equal(HttpStatusCode.BadRequest, missingProduct.StatusCode);
        Assert.Equal(0, retention.RetainedBytes);
    }

    [Fact]
    public async Task CorrelationIdIsPropagated()
    {
        using var client = _factory.CreateClient();
        const string correlationId = "CORR-TEST-PROPAGATION";
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/stores");
        request.Headers.Add("X-Correlation-ID", correlationId);

        var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(correlationId, response.Headers.GetValues("X-Correlation-ID").Single());
    }

    [Fact]
    public async Task ConcurrentAddsAndReadsReturnStableSnapshots()
    {
        var retail = new RetailStateService(CreateRetention(0, 640));
        var cart = retail.CreateCart("store-river")!;

        await Task.WhenAll(Enumerable.Range(1, 40).Select(index => Task.Run(() =>
        {
            var result = retail.AddItem(cart.Id, "product-apples", 1, $"CORR-{index}");
            Assert.True(result.IsSuccess);
            var snapshot = retail.GetCart(cart.Id);
            Assert.NotNull(snapshot);
            _ = JsonSerializer.Serialize(snapshot);
        })));

        var finalCart = retail.GetCart(cart.Id)!;
        Assert.Equal(40, finalCart.Items.Single().Quantity);
    }

    private static async Task<string> CreateCart(HttpClient client)
    {
        var response = await client.PostAsJsonAsync("/api/carts", new CreateCartRequest("store-river"));
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var json = await ReadJson(response);
        return json.GetProperty("cart").GetProperty("id").GetString()!;
    }

    private static async Task<JsonElement> ReadJson(HttpResponseMessage response) =>
        JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.Clone();

    private static CartMemoryRetentionService CreateRetention(int perAddMb, int maxMb) =>
        new(
            Microsoft.Extensions.Options.Options.Create(new CartMemoryRetentionOptions
            {
                MegabytesPerValidAdd = perAddMb,
                MaxRetainedMegabytes = maxMb
            }),
            NullLogger<CartMemoryRetentionService>.Instance);
}
