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

# Pin grafana/pyroscope-dotnet 1.5.1. TARGETARCH is the image architecture, not
# the host. Checksums are immutable SHA-256 of the published glibc tarballs.
FROM alpine:3.22 AS pyroscope
ARG TARGETARCH
ARG PYROSCOPE_VERSION=1.5.1
ARG PYROSCOPE_SHA256_AMD64=06bc3888e45d53cecefc3263db957833b1c0cb082f9129d1b1e5f63c84b88d18
ARG PYROSCOPE_SHA256_ARM64=745752f5f07dd51a6d0fbbcfe4d5a0e0a2d7f9a9286eb661a84b2370a595e87d
RUN apk add --no-cache curl ca-certificates \
 && case "${TARGETARCH}" in \
      amd64) arch=x86_64; sha="${PYROSCOPE_SHA256_AMD64}" ;; \
      arm64) arch=aarch64; sha="${PYROSCOPE_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && file="pyroscope.${PYROSCOPE_VERSION}-glibc-${arch}.tar.gz" \
 && url="https://github.com/grafana/pyroscope-dotnet/releases/download/pyroscope-${PYROSCOPE_VERSION}/${file}" \
 && curl -fsSL --retry 3 --retry-delay 2 -o "/tmp/${file}" "${url}" \
 && echo "${sha}  /tmp/${file}" | sha256sum -c - \
 && mkdir -p /opt/pyroscope \
 && tar -xzf "/tmp/${file}" -C /opt/pyroscope \
 && rm -f "/tmp/${file}" \
 && chmod -R a+rX /opt/pyroscope

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
COPY --from=pyroscope /opt/pyroscope /opt/pyroscope
COPY docker/pyroscope-entrypoint.sh /usr/local/bin/pyroscope-entrypoint.sh
RUN chmod 0755 /usr/local/bin/pyroscope-entrypoint.sh \
    && mkdir -p /opt/pyroscope/logs \
    && chmod a+rX /opt/pyroscope \
    && chmod 0777 /opt/pyroscope/logs
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/pyroscope-entrypoint.sh"]
CMD ["./ECommerce.Api"]
