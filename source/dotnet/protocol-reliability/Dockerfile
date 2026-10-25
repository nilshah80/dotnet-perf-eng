FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY Directory.Packages.props ProtocolReliability.Api.csproj ./
COPY Protos/ Protos/
RUN dotnet restore ProtocolReliability.Api.csproj
COPY . .
RUN dotnet publish ProtocolReliability.Api.csproj -c Release -o /app

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
 && chmod -R a+rX /opt/pyroscope

FROM mcr.microsoft.com/dotnet/monitor:10.0 AS monitor

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
COPY --from=pyroscope /opt/pyroscope /opt/pyroscope
# dotnet-monitor's opt-in call-stack endpoint injects this startup hook and its
# native channel by absolute /app/shared paths. In a sidecar topology those files
# must exist at the same paths inside the target container.
COPY --from=monitor /app/shared /app/shared
COPY docker/pyroscope-entrypoint.sh /usr/local/bin/pyroscope-entrypoint.sh
RUN chmod 0755 /usr/local/bin/pyroscope-entrypoint.sh \
    && mkdir -p /opt/pyroscope/logs \
    && chmod 0777 /opt/pyroscope/logs
USER $APP_UID
EXPOSE 8080 8081
ENTRYPOINT ["/usr/local/bin/pyroscope-entrypoint.sh"]
CMD ["./ProtocolReliability.Api"]
