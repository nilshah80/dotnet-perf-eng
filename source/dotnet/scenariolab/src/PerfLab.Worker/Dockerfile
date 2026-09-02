FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY Directory.Build.props Directory.Packages.props global.json PerfLab.slnx NuGet.config ./
COPY src/PerfLab.Shared/PerfLab.Shared.csproj src/PerfLab.Shared/
COPY src/PerfLab.Worker/PerfLab.Worker.csproj src/PerfLab.Worker/
RUN dotnet restore src/PerfLab.Worker/PerfLab.Worker.csproj

COPY src/PerfLab.Shared/ src/PerfLab.Shared/
COPY src/PerfLab.Worker/ src/PerfLab.Worker/
RUN dotnet publish src/PerfLab.Worker/PerfLab.Worker.csproj \
    --configuration Release \
    --no-restore \
    --output /app/publish

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
USER $APP_UID
ENTRYPOINT ["./PerfLab.Worker"]
