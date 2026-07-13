using MercadonaRetail.Api.Options;
using Xunit;

namespace MercadonaRetail.Api.Tests;

public sealed class OptionsValidationTests
{
    private readonly CartMemoryRetentionOptionsValidator _validator = new();

    [Theory]
    [InlineData(-1, 640)]
    [InlineData(11, 640)]
    [InlineData(10, 9)]
    [InlineData(0, 641)]
    public void InvalidStartupConfigurationFails(int perAddMb, int maxMb)
    {
        var result = _validator.Validate(null, new CartMemoryRetentionOptions
        {
            MegabytesPerValidAdd = perAddMb,
            MaxRetainedMegabytes = maxMb
        });

        Assert.True(result.Failed);
    }

    [Theory]
    [InlineData(0, 640)]
    [InlineData(10, 640)]
    [InlineData(10, 10)]
    public void ValidStartupConfigurationSucceeds(int perAddMb, int maxMb)
    {
        var result = _validator.Validate(null, new CartMemoryRetentionOptions
        {
            MegabytesPerValidAdd = perAddMb,
            MaxRetainedMegabytes = maxMb
        });

        Assert.True(result.Succeeded);
    }
}
