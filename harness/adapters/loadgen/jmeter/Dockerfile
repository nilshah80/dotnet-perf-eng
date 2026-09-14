# Native JMeter load adapter. The binary and Apache JMeter runtime are built
# here; nothing is copied from a peer product.
#
# Stage 1 compiles a static helper for Docker's selected target platform. Stage
# 2 installs Apache JMeter 5.6.3 on eclipse-temurin:17-jre-jammy. A local
# apache-jmeter.tgz in the build context is used when present; otherwise the
# official archive is downloaded.

FROM golang:1.22-bookworm AS build
ARG TARGETOS=linux
ARG TARGETARCH
WORKDIR /src
COPY runner/go.mod ./
COPY runner/*.go ./
COPY adapter-manifest.json ./adapter-manifest.json
RUN test -n "${TARGETARCH}" && CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
    go build -trimpath -ldflags="-s -w" -o /out/dotnet-perf-eng-load-jmeter .

FROM eclipse-temurin:17-jre-jammy
ARG JMETER_VERSION=5.6.3
ARG JMETER_SHA512=5978a1a35edb5a7d428e270564ff49d2b1b257a65e17a759d259a9283fc17093e522fe46f474a043864aea6910683486340706d745fcdf3db1505fd71e689083
COPY vendor/ /tmp/vendor/
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    if [ -f /tmp/vendor/apache-jmeter.tgz ]; then \
      cp /tmp/vendor/apache-jmeter.tgz /tmp/apache-jmeter.tgz; \
    else \
      curl -fsSL -o /tmp/apache-jmeter.tgz \
        "https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"; \
    fi; \
    echo "${JMETER_SHA512}  /tmp/apache-jmeter.tgz" | sha512sum -c -; \
    mkdir -p /opt; \
    tar -xzf /tmp/apache-jmeter.tgz -C /opt; \
    mv /opt/apache-jmeter-${JMETER_VERSION} /opt/apache-jmeter; \
    rm -rf /tmp/apache-jmeter.tgz /opt/apache-jmeter/docs /opt/apache-jmeter/printable_docs; \
    apt-get purge -y curl; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /out/dotnet-perf-eng-load-jmeter /usr/local/bin/dotnet-perf-eng-load-jmeter
COPY adapter-manifest.json /opt/dotnet-perf-eng/adapter-manifest.json
RUN chmod 0555 /usr/local/bin/dotnet-perf-eng-load-jmeter \
    && mkdir -p /workload /results \
    && chmod 0777 /workload /results
ENV JMETER_HOME=/opt/apache-jmeter
ENV ADAPTER_MANIFEST=/opt/dotnet-perf-eng/adapter-manifest.json
WORKDIR /workload
ENTRYPOINT ["/usr/local/bin/dotnet-perf-eng-load-jmeter"]
LABEL org.opencontainers.image.title="dotnet-perf-eng-load-jmeter" \
      org.opencontainers.image.description="Native JMeter load adapter for dotnet-perf-eng" \
      adapter.id="dotnet-perf-eng.load.jmeter" \
      adapter.version="0.1.0" \
      adapter.jmeter.version="5.6.3"
