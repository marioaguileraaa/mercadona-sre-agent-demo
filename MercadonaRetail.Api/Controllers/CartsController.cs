using MercadonaRetail.Api.Models;
using MercadonaRetail.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace MercadonaRetail.Api.Controllers;

[ApiController]
[Route("api/carts")]
public sealed class CartsController(RetailStateService retail) : ControllerBase
{
    [HttpPost]
    public IActionResult CreateCart(CreateCartRequest request)
    {
        var cart = retail.CreateCart(request.StoreId);
        return cart is null
            ? BadRequest(new { errorCode = "STORE_NOT_FOUND", correlationId = HttpContext.TraceIdentifier })
            : CreatedAtAction(nameof(GetCart), new { cartId = cart.Id }, new { cart, correlationId = HttpContext.TraceIdentifier });
    }

    [HttpGet("{cartId}")]
    public IActionResult GetCart(string cartId)
    {
        var cart = retail.GetCart(cartId);
        return cart is null
            ? NotFound(new { errorCode = "CART_NOT_FOUND", correlationId = HttpContext.TraceIdentifier })
            : Ok(new { cart, correlationId = HttpContext.TraceIdentifier });
    }

    [HttpPost("{cartId}/items")]
    public IActionResult AddItem(string cartId, AddCartItemRequest request)
    {
        var result = retail.AddItem(cartId, request.ProductId, request.Quantity, HttpContext.TraceIdentifier);
        if (result.IsSuccess)
        {
            return Ok(new
            {
                result.Cart,
                result.AllocationBytes,
                result.RetainedBytes,
                result.MaxRetainedBytes,
                correlationId = HttpContext.TraceIdentifier
            });
        }

        if (result.ErrorCode == CartMemoryRetentionService.CapacityErrorCode)
        {
            return StatusCode(StatusCodes.Status503ServiceUnavailable, new
            {
                message = "El carrito sintético alcanzó el límite seguro de memoria de la demo. Inténtalo tras la recuperación controlada.",
                result.ErrorCode,
                result.AllocationBytes,
                result.RetainedBytes,
                result.MaxRetainedBytes,
                RootCauseClue = CartMemoryRetentionService.RootCauseClue,
                correlationId = HttpContext.TraceIdentifier
            });
        }

        return result.ErrorCode == "CART_NOT_FOUND"
            ? NotFound(new { result.ErrorCode, correlationId = HttpContext.TraceIdentifier })
            : BadRequest(new { result.ErrorCode, correlationId = HttpContext.TraceIdentifier });
    }
}
