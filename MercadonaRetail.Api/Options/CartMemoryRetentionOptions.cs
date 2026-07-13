using Microsoft.Extensions.Options;

namespace MercadonaRetail.Api.Options;

public sealed class CartMemoryRetentionOptions
{
    public int MegabytesPerValidAdd { get; set; }
    public int MaxRetainedMegabytes { get; set; } = 640;
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

        return ValidateOptionsResult.Success;
    }
}
