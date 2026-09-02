FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY Directory.Build.props Directory.Packages.props global.json PerfLab.slnx NuGet.config ./
COPY src/PerfLab.Shared/PerfLab.Shared.csproj src/PerfLab.Shared/
COPY src/PerfLab.Api/PerfLab.Api.csproj src/PerfLab.Api/
RUN dotnet restore src/PerfLab.Api/PerfLab.Api.csproj

COPY src/PerfLab.Shared/ src/PerfLab.Shared/
COPY src/PerfLab.Api/ src/PerfLab.Api/
RUN dotnet publish src/PerfLab.Api/PerfLab.Api.csproj \
    --configuration Release \
    --no-restore \
    --output /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["./PerfLab.Api"]
