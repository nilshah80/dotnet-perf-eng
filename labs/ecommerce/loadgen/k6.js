import http from 'k6/http';
import { Counter, Trend } from 'k6/metrics';
import { mixEnabled, pickRequest } from '../../../harness/adapters/loadgen/k6/mix.js';
import { withPerfBaggage } from '../../../harness/adapters/loadgen/k6/baggage.js';

// eCommerce k6 workload. The endpoints are JWT-protected; the harness logs in
// once before traffic (the lab's PERFLAB_LOGIN_PATH) and hands the bearer token
// to every generator in PERF_HEADERS, so k6, wrk and JMeter authenticate the same
// way and a protected scenario measures its endpoint, not the login/KDF cost --
// which the public login scenario (E01) measures directly.
const baseUrl = __ENV.PERF_BASE_URL || 'http://127.0.0.1:8080';
const method = (__ENV.PERF_METHOD || 'GET').toUpperCase();
const path = __ENV.PERF_PATH || '/';
const body = __ENV.PERF_BODY || '';
const runId = __ENV.PERF_RUN_ID || 'k6-manual';
let extraHeaders = {};
try {
  extraHeaders = JSON.parse(__ENV.PERF_HEADERS || '{}');
} catch (e) {
  throw new Error(`PERF_HEADERS must be a JSON object of header name/value pairs: ${e}`);
}

// Same counter names the shared k6/run.sh reads for its observations -- the
// evidence contract every lab's k6 workload must honor.
const nonSuccessResponses = new Counter('perflab_http_non_2xx_3xx');
const transportErrors = new Counter('perflab_http_transport_errors');
const primaryRequests = new Counter('perflab_primary_requests');
const primaryRequestLatency = new Trend('perflab_primary_request_latency');

// Per-VU monotonic counter used to expand the literal token __PERF_SEQ__ in a
// request body into a value that changes on every iteration. A scenario whose
// body repeats identical values (e.g. a PATCH that always sets the same price
// and stock) is silently no-op'd by EF Core change tracking after the first
// request, so it measures a SELECT + empty SaveChanges instead of the write
// path it claims to. Bodies that never contain the token are sent unchanged.
let iterationSeq = 0;

export const options = {
  discardResponseBodies: true,
  noConnectionReuse: false,
  noVUConnectionReuse: false,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(99)'],
};

export default function () {
  // One request from the PERF_* contract, unless PERF_MIX blends several
  // endpoints (weighted). The harness-minted bearer token applies to every one.
  let m = method, p = path, b = body;
  if (mixEnabled) { const r = pickRequest(); m = r.method; p = r.path; b = r.body; }
  const sendsBody = m === 'POST' || m === 'PUT' || m === 'PATCH';
  const params = {
    headers: withPerfBaggage(Object.assign({
      Accept: 'application/json',
      'X-Perf-Run-Id': runId,
    }, extraHeaders), runId),
  };
  if (sendsBody) {
    params.headers['Content-Type'] = 'application/json';
  }

  let requestBody = null;
  if (sendsBody) {
    requestBody = b;
    if (requestBody.indexOf('__PERF_SEQ__') !== -1) {
      iterationSeq += 1;
      // VU-scoped so concurrent VUs never collide, monotonic so this VU's
      // successive writes to the same row always differ (defeating the no-op).
      const seq = __VU * 1000000 + iterationSeq;
      requestBody = requestBody.split('__PERF_SEQ__').join(String(seq));
    }
  }

  const response = http.request(
    m,
    `${baseUrl}${p}`,
    requestBody,
    params);

  primaryRequests.add(1);
  primaryRequestLatency.add(response.timings.duration);

  if (response.status === 0) {
    transportErrors.add(1);
  } else if (response.status < 200 || response.status >= 400) {
    nonSuccessResponses.add(1);
  }
}
