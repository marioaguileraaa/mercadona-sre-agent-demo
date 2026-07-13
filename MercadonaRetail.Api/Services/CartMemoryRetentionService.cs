using MercadonaRetail.Api.Options;
using Microsoft.Extensions.Options;

namespace MercadonaRetail.Api.Services;

public sealed class CartMemoryRetentionService
{
    public const string ErrorCode = "DEMO_CART_MEMORY_RETENTION";
    public const string RootCauseClue = "Fictional demo: valid cart additions retain touched byte arrays in a process-lifetime collection with no eviction.";
    private const int BytesPerMegabyte = 1024 * 1024;
    private const int PageSize = 4096;

    private readonly object _gate = new();
    private readonly List<byte[]> _retainedBlocks = [];
    private readonly ILogger<CartMemoryRetentionService> _logger;
    private readonly long _allocationBytes;
    private readonly long _maxRetainedBytes;
    private long _retainedBytes;

    public CartMemoryRetentionService(
        IOptions<CartMemoryRetentionOptions> options,
        ILogger<CartMemoryRetentionService> logger)
    {
        _logger = logger;
        _allocationBytes = checked((long)options.Value.MegabytesPerValidAdd * BytesPerMegabyte);
        _maxRetainedBytes = checked((long)options.Value.MaxRetainedMegabytes * BytesPerMegabyte);
    }

    public long RetainedBytes => Interlocked.Read(ref _retainedBytes);

    public long MaxRetainedBytes => _maxRetainedBytes;

    public long RetainAfterValidAdd(string correlationId, string cartId, string storeId, string productId, int quantity)
    {
        if (_allocationBytes == 0)
        {
            return 0;
        }

        lock (_gate)
        {
            if (_retainedBytes > _maxRetainedBytes - _allocationBytes)
            {
                LogRetentionEvent(
                    LogLevel.Warning,
                    correlationId,
                    cartId,
                    storeId,
                    productId,
                    quantity,
                    0,
                    "Cart memory retention cap reached; the valid cart add remains successful.");
                return 0;
            }

            var block = GC.AllocateUninitializedArray<byte>(checked((int)_allocationBytes));
            for (var offset = 0; offset < block.Length; offset += PageSize)
            {
                block[offset] = 0x5A;
            }
            block[^1] = 0x5A;

            _retainedBlocks.Add(block);
            _retainedBytes += block.LongLength;
            LogRetentionEvent(
                LogLevel.Information,
                correlationId,
                cartId,
                storeId,
                productId,
                quantity,
                block.LongLength,
                "Valid cart add retained synthetic demo memory.");
            return block.LongLength;
        }
    }

    private void LogRetentionEvent(
        LogLevel level,
        string correlationId,
        string cartId,
        string storeId,
        string productId,
        int quantity,
        long allocationBytes,
        string message)
    {
        _logger.Log(
            level,
            new EventId(4201, ErrorCode),
            "{Message} CorrelationId={CorrelationId} CartId={CartId} StoreId={StoreId} ProductId={ProductId} Quantity={Quantity} AllocationBytes={AllocationBytes} RetainedBytes={RetainedBytes} MaxRetainedBytes={MaxRetainedBytes} ErrorCode={ErrorCode} RootCauseClue={RootCauseClue}",
            message,
            correlationId,
            cartId,
            storeId,
            productId,
            quantity,
            allocationBytes,
            _retainedBytes,
            _maxRetainedBytes,
            ErrorCode,
            RootCauseClue);
    }
}
