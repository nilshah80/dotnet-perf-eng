# Deploy-time telemetry injection (D-P1-3, D-P1-8). The build stage compiles
# the startup-hook assembly; the final image only copies it into the volume that
# the .NET services mount read-only, the way a platform delivers an agent with
# an init container. The application image is never rebuilt for it.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY PerfLab.DotNet.Injection.csproj ./
RUN dotnet restore
COPY *.cs ./
RUN dotnet publish --no-restore -c Release -o /out

FROM busybox:1.37.0-musl
COPY --from=build /out/ /injection/
ENTRYPOINT ["sh", "-c", "cp -R /injection/. /mnt/injection/ && echo 'telemetry injection staged'"]
