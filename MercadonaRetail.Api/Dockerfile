FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src
COPY MercadonaRetail.Api.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app
COPY --from=build /app/publish .
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080
ENV ASPNETCORE_ENVIRONMENT=Production
ENV DEMO_CART_MEMORY_MB_PER_ADD=0
ENV DEMO_CART_MEMORY_MAX_MB=640
USER $APP_UID
ENTRYPOINT ["dotnet", "MercadonaRetail.Api.dll"]
