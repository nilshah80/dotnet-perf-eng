# Keep the pinned dotnet-monitor image as the runtime.  It is deliberately
# distroless, so add only BusyBox's static executable to make the small
# policy-gating entrypoint possible; no package manager or interactive shell is
# introduced into the running monitor image.
FROM busybox:1.37.0-musl AS busybox

FROM mcr.microsoft.com/dotnet/monitor:10.0
COPY --from=busybox /bin/busybox /bin/busybox
# Source-purge helpers intentionally invoke `sh -c` in a running monitor.
# BusyBox's static shell keeps that recovery path available without adding a
# package manager or general-purpose base image.
COPY --from=busybox /bin/sh /bin/sh
# `performance_crash_dump_collect_path_from` deliberately uses ordinary POSIX
# tool names in `compose exec` and the stopped-container fallback. Copy the
# small static BusyBox applets it needs so a live monitor egress can be bounded
# and purged even though the upstream monitor image is distroless.
COPY --from=busybox /bin/cat /bin/cat
COPY --from=busybox /bin/find /bin/find
COPY --from=busybox /bin/rm /bin/rm
COPY --from=busybox /bin/sort /bin/sort
COPY --from=busybox /bin/tr /bin/tr
COPY --from=busybox /bin/wc /bin/wc
COPY monitor-entrypoint.sh /opt/perflab/monitor-entrypoint.sh
COPY collection-rules.json /opt/perflab/collection-rules.json
ENTRYPOINT ["/bin/busybox", "sh", "/opt/perflab/monitor-entrypoint.sh"]
CMD ["collect", "--no-auth"]
