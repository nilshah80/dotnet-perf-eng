FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY Directory.Build.props Directory.Packages.props global.json ECommerce.slnx NuGet.config ./
COPY src/ECommerce.Api/ECommerce.Api.csproj src/ECommerce.Api/
RUN dotnet restore src/ECommerce.Api/ECommerce.Api.csproj

COPY src/ECommerce.Api/ src/ECommerce.Api/
RUN dotnet publish src/ECommerce.Api/ECommerce.Api.csproj \
    --configuration Release \
    --no-restore \
    --output /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["./ECommerce.Api"]
