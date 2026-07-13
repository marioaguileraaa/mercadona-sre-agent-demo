using MercadonaRetail.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace MercadonaRetail.Api.Controllers;

[ApiController]
[Route("api/stores")]
public sealed class StoresController(RetailStateService retail) : ControllerBase
{
    [HttpGet]
    public IActionResult GetStores() => Ok(retail.GetStores());
}
