using MercadonaRetail.Api.Middleware;
using MercadonaRetail.Api.Options;
using MercadonaRetail.Api.Services;
using Microsoft.AspNetCore.HttpOverrides;

var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole();

builder.Services.AddControllers();
builder.Services.AddOpenApi();
builder.Services.AddApplicationInsightsTelemetry();
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();
});

builder.Services
    .AddOptions<CartMemoryRetentionOptions>()
    .Configure(options =>
    {
        options.MegabytesPerValidAdd = builder.Configuration.GetValue<int?>("DEMO_CART_MEMORY_MB_PER_ADD")
            ?? builder.Configuration.GetValue<int>("Demo:CartMemoryMegabytesPerAdd");
        options.MaxRetainedMegabytes = builder.Configuration.GetValue<int?>("DEMO_CART_MEMORY_MAX_MB")
            ?? builder.Configuration.GetValue<int>("Demo:CartMemoryMaxMegabytes");
        options.FailureThresholdMegabytes = builder.Configuration.GetValue<int?>("DEMO_CART_MEMORY_FAILURE_MB")
            ?? builder.Configuration.GetValue<int>("Demo:CartMemoryFailureMegabytes");
    })
    .ValidateOnStart();
builder.Services.AddSingleton<Microsoft.Extensions.Options.IValidateOptions<CartMemoryRetentionOptions>, CartMemoryRetentionOptionsValidator>();
builder.Services.AddSingleton<CartMemoryRetentionService>();
builder.Services.AddSingleton<RetailStateService>();

var app = builder.Build();

app.UseForwardedHeaders();
app.UseMiddleware<CorrelationIdMiddleware>();
if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseAuthorization();
app.MapControllers();
app.MapGet("/healthz", () => Results.Ok(new { status = "healthy", service = "mercadona-retail-api", dataClassification = "synthetic" }));
app.MapGet("/api/healthz", () => Results.Ok(new { status = "healthy", service = "mercadona-retail-api", dataClassification = "synthetic" }));

app.Run();

public partial class Program;
