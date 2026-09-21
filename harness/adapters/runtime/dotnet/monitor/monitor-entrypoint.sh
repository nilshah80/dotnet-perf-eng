#!/bin/sh
# The monitor image is shared by normal measurement and post-incident
# diagnostics. Never leave a dump-producing collection rule configured in the
# normal image: configure it only for an owned, diagnose-mode recreation with
# both operator opt-ins present. This script deliberately emits no secrets and
# execs the pinned dotnet-monitor binary directly.
set -eu

armed=false
if [ "${PERFLAB_COLLECTION_RULES:-0}" = "1" ] \
  && [ "${PERFLAB_DUMP_ACK:-}" = "i-understand-sensitive-dump" ] \
  && [ "${PERF_RUN_MODE:-measure}" = "diagnose" ] \
  && [ "${PERFLAB_TARGET_KIND:-managed-compose}" = "managed-compose" ]; then
  armed=true
fi

if [ "${armed}" = true ]; then
  # This exact JSON file is a real dotnet-monitor CollectionRules
  # configuration. Its Filesystem egress is a 512 MiB tmpfs mounted by
  # Compose at the declared path, so the storage ceiling applies before a
  # dump can fill the shared volume. ActionCount permits one action per hour.
  exec dotnet-monitor "$@" --configuration-file-path /opt/perflab/collection-rules.json
fi

exec dotnet-monitor "$@"
