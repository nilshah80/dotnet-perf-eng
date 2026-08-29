import http from 'k6/http';
import { Counter } from 'k6/metrics';

// This script is the k6 counterpart of scripts/wrk/scenario.lua and reads the
// same environment contract so both load generators drive an identical
// workload. wrk remains the default generator; k6 is opt-in through
// PERFLAB_LOAD_GENERATOR=k6.
const baseUrl = __ENV.PERF_BASE_URL || 'http://127.0.0.1:8080';
const method = (__ENV.PERF_METHOD || 'GET').toUpperCase();
const path = __ENV.PERF_PATH || '/';
const body = __ENV.PERF_BODY || '';
const runId = __ENV.PERF_RUN_ID || 'k6-manual';

// wrk reported "Non-2xx or 3xx responses" and "Socket errors" as two separate
// figures. k6 folds both into the built-in http_req_failed rate, which would
// blur an application error response together with a transport failure. The
// pool-capacity and upstream-latency scenarios are diagnosed precisely on that
// distinction, so the lab counts the two outcomes independently here and
// capture-evidence.sh reads these counters instead of http_req_failed.
const nonSuccessResponses = new Counter('perflab_http_non_2xx_3xx');
const transportErrors = new Counter('perflab_http_transport_errors');

export const options = {
  // Response bodies are never asserted by the lab, and discarding them keeps
  // client-side cost low. The API container is capped at 1 CPU, so client
  // overhead competes with the process under measurement.
  discardResponseBodies: true,
  // Pinned rather than inherited: one reused connection per VU is what makes
  // `--vus N` comparable to wrk's `-cN`, and several scenarios are diagnosed
  // from server-side connection and socket counts.
  noConnectionReuse: false,
  noVUConnectionReuse: false,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(99)'],
};

const params = {
  headers: {
    Accept: 'application/json',
    'X-Perf-Run-Id': runId,
  },
};

if (method === 'POST') {
  params.headers['Content-Type'] = 'application/json';
}

export default function () {
  const response = http.request(
    method,
    `${baseUrl}${path}`,
    method === 'POST' ? body : null,
    params);

  if (response.status === 0) {
    // No HTTP status was received: connection refused, timeout, or reset.
    transportErrors.add(1);
  } else if (response.status < 200 || response.status >= 400) {
    nonSuccessResponses.add(1);
  }
}
