FROM mcr.microsoft.com/dotnet/sdk:10.0

RUN dotnet tool install --tool-path /tools dotnet-trace --version 9.0.661903 \
    && dotnet tool install --tool-path /tools dotnet-gcdump --version 9.0.661903 \
    && dotnet tool install --tool-path /tools dotnet-dump --version 9.0.661903 \
    && dotnet tool install --tool-path /tools dotnet-counters --version 9.0.661903

ENV PATH="/tools:${PATH}"
WORKDIR /workspace
CMD ["bash"]
