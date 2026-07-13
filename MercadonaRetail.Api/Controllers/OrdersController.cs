using MercadonaRetail.Api.Models;
using MercadonaRetail.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace MercadonaRetail.Api.Controllers;

[ApiController]
[Route("api/orders")]
public sealed class OrdersController(RetailStateService retail) : ControllerBase
{
    [HttpPost]
    public IActionResult CreateOrder(CreateOrderRequest request)
    {
        var result = retail.CreateOrder(request.CartId);
        if (!result.IsSuccess)
        {
            return result.ErrorCode == "CART_NOT_FOUND"
                ? NotFound(new { result.ErrorCode, correlationId = HttpContext.TraceIdentifier })
                : BadRequest(new { result.ErrorCode, correlationId = HttpContext.TraceIdentifier });
        }

        return CreatedAtAction(
            nameof(GetTracking),
            new { orderId = result.Order!.Id },
            new { order = result.Order, correlationId = HttpContext.TraceIdentifier });
    }

    [HttpGet("{orderId}/tracking")]
    public IActionResult GetTracking(string orderId)
    {
        var tracking = retail.GetTracking(orderId);
        return tracking is null
            ? NotFound(new { errorCode = "ORDER_NOT_FOUND", correlationId = HttpContext.TraceIdentifier })
            : Ok(new { tracking, correlationId = HttpContext.TraceIdentifier });
    }
}
