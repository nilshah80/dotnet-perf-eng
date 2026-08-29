import http from 'k6/http';
import { Counter } from 'k6/metrics';

// scenariolab k6 workload. scenariolab's endpoints are unauthenticated and each
// scenario is a single stateless request, so this is intentionally identical to
// the shared harness default (harness/adapters/loadgen/k6/default.js). It lives
// here so the lab owns its workload and cannot be affected by another lab's
// script; a project that needs auth or datasets (e.g. the ecommerce lab) puts a
// setup() login and a SharedArray dataset in its own copy instead.
const baseUrl = __ENV.PERF_BASE_URL || 'http://127.0.0.1:8080';
const method = (__ENV.PERF_METHOD || 'GET').toUpperCase();
const path = __ENV.PERF_PATH || '/';
const body = __ENV.PERF_BODY || '';
const runId = __ENV.PERF_RUN_ID || 'k6-manual';
const extraHeaders = __ENV.PERF_HEADERS || '';

// These two counter names are the evidence contract read by k6/run.sh; keep them.
const nonSuccessResponses = new Counter('perflab_http_non_2xx_3xx');
const transportErrors = new Counter('perflab_http_transport_errors');

export const options = {
  discardResponseBodies: true,
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
  const response = http.request(
    method,
    `${baseUrl}${path}`,
    sendsBody ? body : null,
    params);

  if (response.status === 0) {
    transportErrors.add(1);
  } else if (response.status < 200 || response.status >= 400) {
    nonSuccessResponses.add(1);
  }
}
