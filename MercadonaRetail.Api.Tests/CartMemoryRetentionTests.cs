using MercadonaRetail.Api.Options;
using MercadonaRetail.Api.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace MercadonaRetail.Api.Tests;

public sealed class CartMemoryRetentionTests
{
    [Fact]
    public void ZeroModeRetainsNothing()
    {
        var service = CreateService(0, 640);

        var allocated = Retain(service, 1);

        Assert.Equal(0, allocated);
        Assert.Equal(0, service.RetainedBytes);
    }

    [Fact]
    public void TenMegabyteModeRetainsExactlyTenMebibytes()
    {
        var service = CreateService(10, 640);

        var allocated = Retain(service, 1);

        Assert.Equal(10L * 1024 * 1024, allocated);
        Assert.Equal(allocated, service.RetainedBytes);
    }

    [Fact]
    public void FreshServiceStartsEmpty()
    {
        Assert.Equal(0, CreateService(10, 640).RetainedBytes);
        Assert.Equal(0, CreateService(10, 640).RetainedBytes);
    }

    [Fact]
    public void HardCapPreventsAdditionalRetention()
    {
        var service = CreateService(10, 20);

        Assert.Equal(10L * 1024 * 1024, Retain(service, 1));
        Assert.Equal(10L * 1024 * 1024, Retain(service, 2));
        Assert.Equal(0, Retain(service, 3));
        Assert.Equal(20L * 1024 * 1024, service.RetainedBytes);
    }

    [Fact]
    public async Task ConcurrentAddsCannotCrossCap()
    {
        var service = CreateService(10, 40);

        await Task.WhenAll(Enumerable.Range(1, 32).Select(index => Task.Run(() => Retain(service, index))));

        Assert.Equal(40L * 1024 * 1024, service.RetainedBytes);
    }

    private static CartMemoryRetentionService CreateService(int perAddMb, int maxMb) =>
        new(
            Microsoft.Extensions.Options.Options.Create(new CartMemoryRetentionOptions
            {
                MegabytesPerValidAdd = perAddMb,
                MaxRetainedMegabytes = maxMb
            }),
            NullLogger<CartMemoryRetentionService>.Instance);

    private static long Retain(CartMemoryRetentionService service, int index) =>
        service.RetainAfterValidAdd($"CORR-{index}", "CART-TEST", "store-river", "product-apples", 1);
}
