#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_command docker
require_command jq

output_file="${repo_root}/ai/generated-mcp.json"
docker exec perflab-lgtm cat /etc/lgtm/mcp.json > "${output_file}"
jq empty "${output_file}"

echo "Saved the local Grafana/Tempo MCP configuration to ${output_file}."
echo "The analysis script will now pass it to Claude with --mcp-config."
