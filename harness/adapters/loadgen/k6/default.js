import http from 'k6/http';
import { Counter } from 'k6/metrics';
import { mixEnabled, pickRequest } from './mix.js';

// Shared DEFAULT k6 workload: one stateless request per iteration, driven
// entirely by the PERF_* env contract. It is the k6 counterpart of the shared
// wrk default.lua so both generators drive an identical workload, and it is the
// fallback a lab gets when it ships no <lab>/loadgen/k6.js of its own. A project
// that needs auth, request chaining, or per-request datasets provides its own
// per-lab k6.js (with a setup() login, a SharedArray dataset, etc.) instead of
// editing this file -- see harness/core/lib/common.sh:loadgen_script.
const baseUrl = __ENV.PERF_BASE_URL || 'http://127.0.0.1:8080';
const method = (__ENV.PERF_METHOD || 'GET').toUpperCase();
const path = __ENV.PERF_PATH || '/';
const body = __ENV.PERF_BODY || '';
const runId = __ENV.PERF_RUN_ID || 'k6-manual';
// Optional generic extra headers as a JSON object, e.g. a pre-minted bearer
// token: PERF_HEADERS='{"Authorization":"Bearer ..."}'. Inert when unset, so
// this default stays byte-for-byte behavior-identical for unauthenticated labs.
const extraHeaders = __ENV.PERF_HEADERS || '';

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

if (method === 'POST' || method === 'PUT' || method === 'PATCH') {
  params.headers['Content-Type'] = 'application/json';
}

if (extraHeaders) {
  try {
    Object.assign(params.headers, JSON.parse(extraHeaders));
  } catch (e) {
    throw new Error(`PERF_HEADERS must be a JSON object of header name/value pairs: ${e}`);
  }
}

const sendsBody = method === 'POST' || method === 'PUT' || method === 'PATCH';

export default function () {
  // One request from the PERF_* contract, unless PERF_MIX blends several
  // endpoints (weighted). The blend can mix GET and body-carrying methods, so
  // Content-Type is decided per request rather than once at module load.
  let m = method, p = path, b = body;
  if (mixEnabled) { const r = pickRequest(); m = r.method; p = r.path; b = r.body; }
  const sends = m === 'POST' || m === 'PUT' || m === 'PATCH';
  const rp = sends
    ? { headers: Object.assign({}, params.headers, { 'Content-Type': 'application/json' }) }
    : params;

  const response = http.request(m, `${baseUrl}${p}`, sends ? b : null, rp);

  if (response.status === 0) {
    // No HTTP status was received: connection refused, timeout, or reset.
    transportErrors.add(1);
  } else if (response.status < 200 || response.status >= 400) {
    nonSuccessResponses.add(1);
  }
}
