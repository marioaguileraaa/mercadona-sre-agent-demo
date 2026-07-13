using MercadonaRetail.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace MercadonaRetail.Api.Controllers;

[ApiController]
[Route("api/products")]
public sealed class ProductsController(RetailStateService retail) : ControllerBase
{
    [HttpGet("store/{storeId}")]
    public IActionResult GetProducts(string storeId)
    {
        var products = retail.GetProducts(storeId);
        return products.Count == 0
            ? NotFound(new { errorCode = "STORE_NOT_FOUND" })
            : Ok(products);
    }
}
