#!/usr/bin/env bash
# Live third-lab proof for the secure edge fixture. It creates ephemeral CA,
# server, and client credentials; no private material is checked into the lab
# or written to evidence. The target itself owns the TLS/mTLS implementation.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
require() { command -v "$1" >/dev/null 2>&1 || { echo "edge-security-test: $1 is required" >&2; exit 1; }; }
require docker; require dotnet; require openssl; require curl; require jq; require awk

work="$(mktemp -d "${TMPDIR:-/tmp}/protocol-edge.XXXXXX")"
app_pid=""
cleanup() {
  if [[ -n "${app_pid}" ]]; then
    kill "${app_pid}" 2>/dev/null || true
    wait "${app_pid}" 2>/dev/null || true
  fi
  if [[ "${PERFLAB_EDGE_KEEP:-0}" == "1" ]]; then
    echo "edge-security-test: retained diagnostic files at ${work}" >&2
  else
    rm -rf "${work}"
  fi
}
trap cleanup EXIT HUP INT TERM

pick_port() {
  local candidate offset
  for offset in $(seq 0 39); do
    candidate=$((18443 + offset))
    if ! lsof -n -iTCP:"${candidate}" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  echo "edge-security-test: no free test port found" >&2
  return 1
}

https_port="$(pick_port)"
http_port="$((https_port + 100))"
grpc_port="$((https_port + 101))"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=perflab-edge-ca' -keyout "${work}/ca.key" -out "${work}/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,DNS:api.perflab.test' \
  -keyout "${work}/server.key" -out "${work}/server.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -sha256 -copy_extensions copy \
  -in "${work}/server.csr" -CA "${work}/ca.crt" -CAkey "${work}/ca.key" -CAcreateserial \
  -out "${work}/server.crt" >/dev/null 2>&1
openssl pkcs12 -export -out "${work}/server.pfx" -inkey "${work}/server.key" \
  -in "${work}/server.crt" -certfile "${work}/ca.crt" -passout pass:perflab-test >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=perflab-edge-client' \
  -addext 'extendedKeyUsage=clientAuth' -keyout "${work}/client.key" -out "${work}/client.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -sha256 -copy_extensions copy \
  -in "${work}/client.csr" -CA "${work}/ca.crt" -CAkey "${work}/ca.key" -CAcreateserial \
  -out "${work}/client.crt" >/dev/null 2>&1

app_dll="$("${root}/labs/protocol-reliability/build-target.sh" "${work}/app")"
PERFLAB_HTTP_PORT="${http_port}" \
PERFLAB_GRPC_PORT="${grpc_port}" \
PERFLAB_HTTPS_PORT="${https_port}" \
PERFLAB_TLS_CERT_PATH="${work}/server.pfx" \
PERFLAB_TLS_CERT_PASSWORD=perflab-test \
PERFLAB_TLS_REQUIRE_CLIENT_CERT=1 \
PERFLAB_TLS_CLIENT_CA_PATH="${work}/ca.crt" \
PERF_RUN_ID=edge-security-proof \
  dotnet "${app_dll}" --contentRoot "${work}/app" \
  >"${work}/app.log" 2>&1 &
app_pid="$!"

tls_curl=(curl --noproxy '*' --cacert "${work}/ca.crt" --cert "${work}/client.crt" --key "${work}/client.key" --max-time 10)
for _ in $(seq 1 30); do
  if "${tls_curl[@]}" -fsS "https://localhost:${https_port}/health/ready" >"${work}/ready.json" 2>/dev/null; then
    break
  fi
  sleep 1
done
[[ -s "${work}/ready.json" ]] || { cat "${work}/app.log" >&2; echo "edge-security-test: mTLS target did not become ready" >&2; exit 1; }

# A trusted CA alone is insufficient: the target must reject a client that
# does not present its certificate.
if curl --noproxy '*' --cacert "${work}/ca.crt" -fsS --max-time 5 \
    "https://localhost:${https_port}/health/ready" >/dev/null 2>&1; then
  echo "edge-security-test: HTTPS endpoint accepted a client without a certificate" >&2
  exit 1
fi

# The SAN-hostname route uses an explicit resolver mapping only for this local
# fixture; certificate hostname verification remains enabled and must pass.
"${tls_curl[@]}" --resolve "api.perflab.test:${https_port}:127.0.0.1" -fsS \
  "https://api.perflab.test:${https_port}/health/ready" >/dev/null

base="https://localhost:${https_port}"
login_headers="${work}/login.headers"
login="$("${tls_curl[@]}" -fsS -D "${login_headers}" -c "${work}/cookies.txt" -X POST "${base}/api/reliability/journey/login")"
grep -qi '^set-cookie:.*perflab_journey_session' "${login_headers}" \
  && grep -qi 'HttpOnly' "${login_headers}" \
  && grep -qi 'Secure' "${login_headers}" \
  && grep -Eqi 'SameSite=(Strict|strict)' "${login_headers}" \
  || { echo "edge-security-test: journey cookie lacks HttpOnly/Secure/Strict protection" >&2; exit 1; }
access="$(printf '%s' "${login}" | jq -r '.accessToken')"
refresh="$(printf '%s' "${login}" | jq -r '.refreshToken')"
csrf="$("${tls_curl[@]}" -fsS -b "${work}/cookies.txt" "${base}/api/reliability/journey/form" | jq -r '.csrfToken')"
expired_status="$("${tls_curl[@]}" -sS -o "${work}/expired.json" -w '%{http_code}' -b "${work}/cookies.txt" \
  -H "Authorization: Bearer ${access}" "${base}/api/reliability/journey/protected")"
[[ "${expired_status}" == "401" ]] || { echo "edge-security-test: expired token was not refused" >&2; exit 1; }
rotated="$("${tls_curl[@]}" -fsS -b "${work}/cookies.txt" -H 'Content-Type: application/json' \
  -X POST --data "{\"refreshToken\":\"${refresh}\"}" "${base}/api/reliability/journey/refresh")"
new_access="$(printf '%s' "${rotated}" | jq -r '.accessToken')"
new_csrf="$(printf '%s' "${rotated}" | jq -r '.csrfToken')"
forged_status="$("${tls_curl[@]}" -sS -o "${work}/forged.json" -w '%{http_code}' -b "${work}/cookies.txt" \
  -H "Authorization: Bearer ${new_access}" -H 'X-Perf-CSRF: forged' -X POST "${base}/api/reliability/journey/submit")"
[[ "${forged_status}" == "403" ]] || { echo "edge-security-test: forged CSRF token was not refused" >&2; exit 1; }
submit_status="$("${tls_curl[@]}" -sS -o "${work}/submit.json" -w '%{http_code}' -b "${work}/cookies.txt" \
  -H "Authorization: Bearer ${new_access}" -H "X-Perf-CSRF: ${new_csrf}" -X POST "${base}/api/reliability/journey/submit")"
[[ "${submit_status}" == "201" ]] || { echo "edge-security-test: protected mutation did not complete" >&2; exit 1; }

# One fresh connection gives each curl timing field a separate value. Curl's
# name lookup, TCP connect, TLS application-connect, and first-byte timings are
# combined with target-reported application queue/work values; no percentile or
# opaque total is mislabeled as one of these components.
timing_headers="${work}/timing.headers"
timing="$("${tls_curl[@]}" -sS -D "${timing_headers}" -o "${work}/timing.json" \
  -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer}' \
  "${base}/api/reliability/connection-churn?queueMs=20&serverMs=15")"
read -r lookup connect appconnect firstbyte <<< "${timing}"
queue="$(awk 'tolower($1) == "x-perf-server-queue-ms:" {gsub("\r", ""); print $2}' "${timing_headers}")"
server="$(awk 'tolower($1) == "x-perf-server-work-ms:" {gsub("\r", ""); print $2}' "${timing_headers}")"
awk -v dns="${lookup}" -v tcp="${connect}" -v tls="${appconnect}" -v first="${firstbyte}" -v queue="${queue}" -v server="${server}" '
  BEGIN { exit !(dns >= 0 && tcp >= dns && tls >= tcp && first >= tls && queue == 20 && server > 0) }
' || { echo "edge-security-test: timing decomposition is not monotonic or target queue/work headers are absent" >&2; exit 1; }
jq -n --argjson dnsMs "$(awk -v n="${lookup}" 'BEGIN { printf "%.3f", n * 1000 }')" \
  --argjson connectMs "$(awk -v c="${connect}" -v d="${lookup}" 'BEGIN { printf "%.3f", (c-d) * 1000 }')" \
  --argjson tlsMs "$(awk -v t="${appconnect}" -v c="${connect}" 'BEGIN { printf "%.3f", (t-c) * 1000 }')" \
  --argjson firstByteMs "$(awk -v f="${firstbyte}" -v t="${appconnect}" 'BEGIN { printf "%.3f", (f-t) * 1000 }')" \
  --argjson queueMs "${queue}" --argjson serverMs "${server}" \
  '{dnsMs:$dnsMs,connectMs:$connectMs,tlsMs:$tlsMs,networkWaitToFirstByteMs:$firstByteMs,applicationQueueMs:$queueMs,serverWorkMs:$serverMs}'

# Two separately serialized, bounded tenant lanes make the fixture's
# noisy-neighbor report meaningful: heavy noisy work is in flight while the
# protected lane makes progress, and each lane publishes its own conservative
# p95 SLO result. Unknown tenant names are rejected by the target before they
# become unbounded metric labels.
tenant_pids=()
for _ in $(seq 1 12); do
  "${tls_curl[@]}" -fsS "${base}/api/reliability/tenant/noisy?workUnits=8000" >/dev/null &
  tenant_pids+=("$!")
done
sleep 0.05
for _ in $(seq 1 4); do
  "${tls_curl[@]}" -fsS "${base}/api/reliability/tenant/protected?workUnits=10" >/dev/null &
  tenant_pids+=("$!")
done
for tenant_pid in "${tenant_pids[@]}"; do
  wait "${tenant_pid}"
done
tenant_slos="$("${tls_curl[@]}" -fsS "${base}/api/reliability/tenant-slos")"
printf '%s' "${tenant_slos}" | jq -e '
  .protectedObservedDuringNoisyLoad == true and
  .tenants.noisy.observed == true and .tenants.protected.observed == true and
  .tenants.noisy.withinSlo == true and .tenants.protected.withinSlo == true and
  (.tenants | keys | sort == ["noisy", "protected"])
' >/dev/null || { echo "edge-security-test: tenant fairness/SLO report is incomplete or failed: ${tenant_slos}" >&2; exit 1; }
if "${tls_curl[@]}" -fsS "${base}/api/reliability/tenant/unbounded-customer" >/dev/null 2>&1; then
  echo "edge-security-test: target accepted an unbounded tenant label" >&2
  exit 1
fi

echo "edge security passed: real target mTLS, TLS hostname verification, Secure cookie refresh/CSRF journey, DNS/TLS/connect/queue/server timing decomposition, and bounded tenant fairness/SLOs"
