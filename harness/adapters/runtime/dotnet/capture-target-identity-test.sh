#!/usr/bin/env bash
# Diagnostic target selection tests.
#
# capture.sh used to pick its target with `head -1` over the processes whose
# assembly matched. That is wrong the moment two replicas share an assembly:
# protocol-reliability maps api-a and api-b to ProtocolReliability.Api, so a
# capture requested for api-b attached to api-a and filed the result under
# api-b's name -- no error, no warning, every downstream number attributed to
# the wrong process.
#
# Two properties, because fixing only the first would still leave a reader
# trusting a label instead of checking it:
#   1. ambiguity fails closed rather than choosing,
#   2. the identity actually attached is recorded as evidence.
#
# jqd here delegates to the real jq so the selector under test is the one that
# ships, not a stub that agrees with it.
set -euo pipefail

adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/capture-identity-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT HUP INT TERM
mkdir -p "${test_root}/harness/core/lib" "${test_root}/bin"
fail() { echo "capture-target-identity-test: $*" >&2; exit 1; }

command -v jq >/dev/null || fail "jq is required to exercise the real selector"

cat > "${test_root}/harness/core/lib/common.sh" <<'EOF'
load_generator=k6
diagnostics_url=http://monitor
jqd() { jq "$@"; }
diag_target() { printf 'Fixture.Api'; }
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s}"; }
loadgen_warmup() { mkdir -p "$1"; printf '{}' > "$1/warmup.json"; }
loadgen_measure() { mkdir -p "$1"; printf '{}' > "$1/diagnostic.json"; }
monitor_curl() { curl "$@"; }
compose() {
  # Mirrors `compose ps --format json <service>`: one JSON object per line.
  if [[ "${1:-}" == "ps" && "${PERFLAB_TEST_COMPOSE_PS:-1}" == "1" ]]; then
    printf '{"ID":"c0ffee123456","Image":"fixture-api","Service":"api"}\n'
    return 0
  fi
  return 1
}
EOF
mkdir -p "${test_root}/harness/adapters/runtime/dotnet"
cp "${adapter_dir}/capability.sh" "${test_root}/harness/adapters/runtime/dotnet/capability.sh"

# Two replicas of the same service. Both match assembly 'Fixture.Api', which is
# exactly the shape that used to resolve silently to whichever came first.
cat > "${test_root}/processes-ambiguous.json" <<'EOF'
[{"uid":"uid-api-a","pid":101,"name":"Fixture.Api"},
 {"uid":"uid-api-b","pid":202,"name":"Fixture.Api"}]
EOF

cat > "${test_root}/processes-single.json" <<'EOF'
[{"uid":"uid-api-a","pid":101,"name":"Fixture.Api"},
 {"uid":"uid-worker","pid":303,"name":"Fixture.Worker"}]
EOF

cat > "${test_root}/detail-single.json" <<'EOF'
[{"uid":"uid-api-a","pid":101,"name":"Fixture.Api","managedEntryPointAssemblyName":"Fixture.Api","commandLine":"/app/Fixture.Api","operatingSystem":"Linux","processArchitecture":"arm64"},
 {"uid":"uid-worker","pid":303,"name":"Fixture.Worker","managedEntryPointAssemblyName":"Fixture.Worker","commandLine":"/app/Fixture.Worker","operatingSystem":"Linux","processArchitecture":"arm64"}]
EOF

# The real sidecar answers these two differently, and the difference is the bug
# this test exists for: /processes is a thin list (pid/uid/name only), while
# /process?uid= carries the command line, architecture and assembly name. An
# identity built from the list records nulls for everything identifying.
cat > "${test_root}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "${url}" in
  */info) printf '{"version":"10.0","runtimeVersion":"10.0","diagnosticPortMode":"Listen","diagnosticPortName":"/diag/monitor.sock","capabilities":[{"name":"call_stacks","enabled":true}]}' ;;
  */) printf '{"paths":{"/trace":{"get":{}},"/gcdump":{"get":{}},"/dump":{"get":{}},"/stacks":{"get":{}}}}' ;;
  */processes) cat "${PERFLAB_TEST_PROCESSES}" ;;
  */process)
    uid=""
    for arg in "$@"; do case "${arg}" in uid=*) uid="${arg#uid=}" ;; esac; done
    # PERFLAB_TEST_DETAIL_ANY simulates a monitor that answers about a DIFFERENT
    # process than the uid asked for -- a restart between the two calls. Without
    # it the fixture could only ever return the matching entry, so the guard
    # against a mismatched answer would have nothing to catch.
    if [[ "${PERFLAB_TEST_DETAIL_ANY:-0}" == "1" ]]; then
      jq -e '.[0] // empty' < "${PERFLAB_TEST_DETAIL:-${PERFLAB_TEST_PROCESSES}}" || exit 22
    else
      jq -e --arg uid "${uid}" '[.[] | select(.uid == $uid)][0] // empty' < "${PERFLAB_TEST_DETAIL:-${PERFLAB_TEST_PROCESSES}}" || exit 22
    fi
    ;;
  */stacks)    printf 'Thread: (0x1)\n  Fixture.Api!Program.Main\n' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "${test_root}/bin/curl"

cat > "${test_root}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "inspect" ]]; then
  # A real inspect answers with the image digest. PERFLAB_TEST_NO_DIGEST
  # reproduces the case where it cannot -- the container is gone, or the daemon
  # refuses -- which used to degrade to an empty digest and pass.
  [[ "${PERFLAB_TEST_NO_DIGEST:-0}" == "1" ]] && exit 1
  printf 'sha256:feedfacedeadbeef0123456789abcdef0123456789abcdef0123456789abcdef\n'
  exit 0
fi
exit 0
EOF
chmod +x "${test_root}/bin/docker"

run_capture() { # run_capture <processes-fixture> <output-dir> [detail-fixture]
  set +e
  PATH="${test_root}/bin:${PATH}" \
  PERFLAB_HARNESS_ROOT="${test_root}/harness" \
  PERFLAB_TEST_PROCESSES="$1" \
  PERFLAB_TEST_DETAIL="${3:-$1}" \
  PERFLAB_TEST_COMPOSE_PS="${PERFLAB_TEST_COMPOSE_PS:-1}" \
  PERFLAB_TEST_DETAIL_ANY="${PERFLAB_TEST_DETAIL_ANY:-0}" \
  PERFLAB_TEST_NO_DIGEST="${PERFLAB_TEST_NO_DIGEST:-0}" \
  PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true \
  PERF_SCENARIO=S07 PERF_RUN_ID=run-identity \
    bash "${adapter_dir}/capture.sh" "$2" stacks 1 api > "$2.out" 2>&1
  local rc=$?
  set -e
  return "${rc}"
}

# 1. Ambiguity fails closed.
mkdir -p "${test_root}/ambiguous"
if run_capture "${test_root}/processes-ambiguous.json" "${test_root}/ambiguous"; then
  fail "two processes matched the assembly and capture.sh chose one anyway"
fi
grep -q 'Ambiguous diagnostic target: 2 processes match' "${test_root}/ambiguous.out" \
  || fail "refusal did not say how many processes matched: $(cat "${test_root}/ambiguous.out")"
grep -q 'uid-api-a' "${test_root}/ambiguous.out" && grep -q 'uid-api-b' "${test_root}/ambiguous.out" \
  || fail "refusal must name the candidates so an operator can tell them apart"
[[ ! -e "${test_root}/ambiguous/runtime/api/stacks.txt" ]] \
  || fail "capture.sh produced an artifact for an ambiguous target"

# 2. An unambiguous target is attached AND its identity recorded. A uid alone
#    says which process dotnet-monitor picked; pid and command line say which
#    process that actually is.
mkdir -p "${test_root}/single"
run_capture "${test_root}/processes-single.json" "${test_root}/single" "${test_root}/detail-single.json" \
  || fail "a single matching process was refused: $(cat "${test_root}/single.out")"
identity="${test_root}/single/runtime/target-identity.json"
[[ -s "${identity}" ]] || fail "no target-identity.json was written"
jq -e '.uid == "uid-api-a" and .processId == 101 and .matchedProcesses == 1
       and .requestedService == "api" and .expectedAssembly == "Fixture.Api"
       and (.commandLine | contains("Fixture.Api"))
       and .managedEntryPointAssemblyName == "Fixture.Api"
       and .selection == "single-match"' "${identity}" >/dev/null \
  || fail "target-identity.json does not prove which process was attached: $(cat "${identity}")"

# 3. The identity must name the MONITOR it came from. "The only process matching
#    this assembly" is a claim about one endpoint; two labs pointed at two
#    sidecars both answer "single match" for different processes.
jq -e '.diagnosticsEndpoint == "http://monitor"' "${identity}" >/dev/null \
  || fail "target-identity.json does not record which monitor was asked"

# 4. An identity that cannot name the process is a FAILURE, not a missing file.
#    This was written with `|| true`: a failed emission left the package looking
#    complete while the one artifact identifying the attached process was gone.
cat > "${test_root}/processes-anonymous.json" <<'EOF'
[{"uid":"uid-api-a","pid":101,"name":"Fixture.Api"}]
EOF
mkdir -p "${test_root}/anonymous"
if run_capture "${test_root}/processes-anonymous.json" "${test_root}/anonymous"; then
  fail "a process with no pid or command line was accepted as a verified target"
fi
grep -q 'identity is incomplete' "${test_root}/anonymous.out" \
  || fail "the refusal did not explain that the attach cannot be verified: $(cat "${test_root}/anonymous.out")"

# 5. The detail must AGREE with the selection. Selection matched the list entry;
#    if the monitor hands back a different assembly for that uid -- a restart or
#    renumber between the two calls -- attributing the capture to the requested
#    service would be a guess.
cat > "${test_root}/detail-mismatch.json" <<'EOF'
[{"uid":"uid-api-a","pid":101,"name":"Fixture.Api","managedEntryPointAssemblyName":"Someone.Elses.Api","commandLine":"/app/Someone.Elses.Api","operatingSystem":"Linux","processArchitecture":"arm64"}]
EOF
mkdir -p "${test_root}/mismatch"
if run_capture "${test_root}/processes-single.json" "${test_root}/mismatch" "${test_root}/detail-mismatch.json"; then
  fail "a process reporting a different assembly was captured as the requested service"
fi
grep -q 'Target identity mismatch' "${test_root}/mismatch.out" \
  || fail "the refusal did not name the mismatch: $(cat "${test_root}/mismatch.out")"

# 6. The detail must describe the SAME process the selection picked. Two calls to
#    a live monitor are two moments: a restart between them can reuse a uid or
#    renumber a pid, and checking only that the detail is populated accepts a
#    different process silently.
cat > "${test_root}/detail-renumbered.json" <<'EOF'
[{"uid":"uid-api-a","pid":999,"name":"Fixture.Api","managedEntryPointAssemblyName":"Fixture.Api","commandLine":"/app/Fixture.Api","operatingSystem":"Linux","processArchitecture":"arm64"}]
EOF
mkdir -p "${test_root}/renumbered"
if PERFLAB_TEST_DETAIL_ANY=1 run_capture "${test_root}/processes-single.json" "${test_root}/renumbered" "${test_root}/detail-renumbered.json"; then
  fail "a process that was renumbered between /processes and /process was accepted"
fi
grep -q 'pid 101 in /processes and pid 999 in /process' "${test_root}/renumbered.out" \
  || fail "the refusal did not name the pid disagreement: $(cat "${test_root}/renumbered.out")"

cat > "${test_root}/detail-wrong-uid.json" <<'EOF'
[{"uid":"uid-somebody-else","pid":101,"name":"Fixture.Api","managedEntryPointAssemblyName":"Fixture.Api","commandLine":"/app/Fixture.Api","operatingSystem":"Linux","processArchitecture":"arm64"}]
EOF
mkdir -p "${test_root}/wrong-uid"
if PERFLAB_TEST_DETAIL_ANY=1 run_capture "${test_root}/processes-single.json" "${test_root}/wrong-uid" "${test_root}/detail-wrong-uid.json"; then
  fail "the monitor answered about a different uid and the capture continued"
fi
grep -q "got 'uid-somebody-else'" "${test_root}/wrong-uid.out" \
  || fail "the refusal did not name the uid disagreement: $(cat "${test_root}/wrong-uid.out")"

# 7. Container, image and a command hash. The assembly name is shared by every
#    replica of a service and cannot tell two apart; the container ID and image
#    can, and the command hash makes an argument change visible between two runs
#    that otherwise look identical.
jq -e '.container.containerId == "c0ffee123456" and .container.image == "fixture-api"
       and .container.source == "compose-ps"
       and (.container.imageDigest | test("^sha256:[0-9a-f]{64}$"))
       and (.commandLineSha256 | test("^[0-9a-f]{64}$"))' "${identity}" >/dev/null \
  || fail "identity carries no container/image/digest/command-hash: $(jq -c '{container,commandLineSha256}' "${identity}")"

# The image digest is the ONLY field that separates two replicas running
# different builds of the same service. An inspect that cannot answer used to
# degrade to an empty digest, producing an identity that looked recorded and
# identified nothing.
mkdir -p "${test_root}/no-digest"
if PERFLAB_TEST_NO_DIGEST=1 run_capture "${test_root}/processes-single.json" "${test_root}/no-digest" "${test_root}/detail-single.json"; then
  fail "a container whose image digest could not be read was accepted as identified"
fi
grep -q 'image digest is required' "${test_root}/no-digest.out" \
  || fail "the refusal did not explain why the digest matters: $(cat "${test_root}/no-digest.out")"

# 8. A target with no compose entry (attach-only, or a bare process) must record
#    not-applicable rather than fail a capture that is otherwise sound.
mkdir -p "${test_root}/no-container"
PERFLAB_TEST_COMPOSE_PS=0 run_capture "${test_root}/processes-single.json" "${test_root}/no-container" "${test_root}/detail-single.json" \
  || fail "a non-container target was refused: $(cat "${test_root}/no-container.out")"
jq -e '.container.source == "not-applicable" and (.commandLineSha256 | length) == 64' \
  "${test_root}/no-container/runtime/target-identity.json" >/dev/null \
  || fail "a non-container target did not record why container identity is absent"

echo "dotnet diagnostic target identity tests passed"
