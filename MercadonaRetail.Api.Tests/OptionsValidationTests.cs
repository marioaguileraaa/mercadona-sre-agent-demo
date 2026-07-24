using MercadonaRetail.Api.Options;
using Xunit;

namespace MercadonaRetail.Api.Tests;

public sealed class OptionsValidationTests
{
    private readonly CartMemoryRetentionOptionsValidator _validator = new();

    [Theory]
    [InlineData(-1, 640, 0)]
    [InlineData(11, 640, 0)]
    [InlineData(10, 9, 0)]
    [InlineData(0, 641, 0)]
    [InlineData(0, 640, 600)]
    [InlineData(10, 640, -1)]
    [InlineData(1, 640, 1)]
    [InlineData(10, 640, 641)]
    [InlineData(10, 500, 600)]
    [InlineData(10, 640, 605)]
    public void InvalidStartupConfigurationFails(int perAddMb, int maxMb, int failureMb)
    {
        var result = _validator.Validate(null, new CartMemoryRetentionOptions
        {
            MegabytesPerValidAdd = perAddMb,
            MaxRetainedMegabytes = maxMb,
            FailureThresholdMegabytes = failureMb
        });

        Assert.True(result.Failed);
    }

    [Theory]
    [InlineData(0, 640, 0)]
    [InlineData(10, 640, 0)]
    [InlineData(10, 10, 10)]
    [InlineData(10, 640, 600)]
    public void ValidStartupConfigurationSucceeds(int perAddMb, int maxMb, int failureMb)
    {
        var result = _validator.Validate(null, new CartMemoryRetentionOptions
        {
            MegabytesPerValidAdd = perAddMb,
            MaxRetainedMegabytes = maxMb,
            FailureThresholdMegabytes = failureMb
        });

        Assert.True(result.Succeeded);
    }
}
