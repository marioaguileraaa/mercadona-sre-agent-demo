using Microsoft.Extensions.Options;

namespace MercadonaRetail.Api.Options;

public sealed class CartMemoryRetentionOptions
{
    public int MegabytesPerValidAdd { get; set; }
    public int MaxRetainedMegabytes { get; set; } = 640;
    public int FailureThresholdMegabytes { get; set; }
}

public sealed class CartMemoryRetentionOptionsValidator : IValidateOptions<CartMemoryRetentionOptions>
{
    public ValidateOptionsResult Validate(string? name, CartMemoryRetentionOptions options)
    {
        if (options.MegabytesPerValidAdd is < 0 or > 10)
        {
            return ValidateOptionsResult.Fail("DEMO_CART_MEMORY_MB_PER_ADD must be an integer from 0 through 10.");
        }

        if (options.MaxRetainedMegabytes is < 10 or > 640)
        {
            return ValidateOptionsResult.Fail("DEMO_CART_MEMORY_MAX_MB must be an integer from 10 through 640.");
        }

        if (options.MegabytesPerValidAdd > options.MaxRetainedMegabytes)
        {
            return ValidateOptionsResult.Fail("DEMO_CART_MEMORY_MAX_MB cannot be lower than DEMO_CART_MEMORY_MB_PER_ADD.");
        }

        if (options.FailureThresholdMegabytes < 0 ||
            options.FailureThresholdMegabytes > 640 ||
            options.FailureThresholdMegabytes is > 0 and < 10)
        {
            return ValidateOptionsResult.Fail("DEMO_CART_MEMORY_FAILURE_MB must be 0 or an integer from 10 through 640.");
        }

        if (options.FailureThresholdMegabytes > options.MaxRetainedMegabytes)
        {
            return ValidateOptionsResult.Fail("DEMO_CART_MEMORY_FAILURE_MB cannot be higher than DEMO_CART_MEMORY_MAX_MB.");
        }

        if (options.FailureThresholdMegabytes > 0 &&
            (options.MegabytesPerValidAdd == 0 ||
             options.FailureThresholdMegabytes < options.MegabytesPerValidAdd ||
             options.FailureThresholdMegabytes % options.MegabytesPerValidAdd != 0))
        {
            return ValidateOptionsResult.Fail(
                "DEMO_CART_MEMORY_FAILURE_MB must be 0 or an exact positive multiple of DEMO_CART_MEMORY_MB_PER_ADD.");
        }

        return ValidateOptionsResult.Success;
    }
}
