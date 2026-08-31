import http from 'k6/http';
import { Counter } from 'k6/metrics';
import { mixEnabled, pickRequest } from '../../../harness/adapters/loadgen/k6/mix.js';

// eCommerce k6 workload. The endpoints are JWT-protected, so this per-lab script
// authenticates ONCE in setup() and sends the bearer token on every request.
// Auth therefore lives in the lab's own workload, not in the shared harness:
// run.sh (the measurement + observations contract) and the shared default.js are
// untouched. Keeping login in setup() (not the measured loop) means a protected
// scenario measures that endpoint, not the login/KDF cost -- which is instead
// measured directly by the public login scenario (E01).
const baseUrl = __ENV.PERF_BASE_URL || 'http://127.0.0.1:8080';
const method = (__ENV.PERF_METHOD || 'GET').toUpperCase();
const path = __ENV.PERF_PATH || '/';
const body = __ENV.PERF_BODY || '';
const runId = __ENV.PERF_RUN_ID || 'k6-manual';
const loginUser = __ENV.PERF_LOGIN_USER || 'user1';
const loginPassword = __ENV.PERF_LOGIN_PASSWORD || 'Password123!';

// Same counter names the shared k6/run.sh reads for its observations -- the
// evidence contract every lab's k6 workload must honor.
const nonSuccessResponses = new Counter('perflab_http_non_2xx_3xx');
const transportErrors = new Counter('perflab_http_transport_errors');

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

// Runs once before the load. discardResponseBodies is global, so this one request
// opts back into a readable body to extract the token.
export function setup() {
  const res = http.post(
    `${baseUrl}/api/auth/login`,
    JSON.stringify({ username: loginUser, password: loginPassword }),
    { headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, responseType: 'text' });

  if (res.status !== 200) {
    throw new Error(`login failed in setup(): status ${res.status} body ${res.body}`);
  }
  const token = res.json('token');
  if (!token) {
    throw new Error('login response contained no token');
  }
  return { token };
}

export default function (data) {
  // One request from the PERF_* contract, unless PERF_MIX blends several
  // endpoints (weighted). The bearer token below applies to every mix request.
  let m = method, p = path, b = body;
  if (mixEnabled) { const r = pickRequest(); m = r.method; p = r.path; b = r.body; }
  const sendsBody = m === 'POST' || m === 'PUT' || m === 'PATCH';
  const params = {
    headers: {
      Accept: 'application/json',
      'X-Perf-Run-Id': runId,
      Authorization: `Bearer ${data.token}`,
    },
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

  if (response.status === 0) {
    transportErrors.add(1);
  } else if (response.status < 200 || response.status >= 400) {
    nonSuccessResponses.add(1);
  }
}
