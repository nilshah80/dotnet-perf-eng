import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { expectedStatuses, setResponseCallback } from 'k6/http';

const baseUrl = __ENV.PERF_BASE_URL || 'http://127.0.0.1:18080';
const method = (__ENV.PERF_METHOD || 'GET').toUpperCase();
const path = __ENV.PERF_PATH || '/api/reliability/status';
const body = __ENV.PERF_BODY || '';
const runId = __ENV.PERF_RUN_ID || 'k6-manual';
const expectedBackpressure = new Counter('reliability_expected_backpressure');
const transportErrors = new Counter('reliability_transport_errors');
const unexpectedStatusErrors = new Counter('reliability_unexpected_status_errors');

setResponseCallback(expectedStatuses({ min: 200, max: 399 }, 429, 503));

export const options = {
  discardResponseBodies: false,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const response = http.request(method, `${baseUrl}${path}`, body || null, {
    headers: { 'X-Perf-Run-Id': runId },
    tags: { name: `operation::${__ENV.PERF_SCENARIO || 'P00'}` },
  });
  if (response.status === 429 || response.status === 503) {
    expectedBackpressure.add(1);
  }
  // A completed 429/503 is application backpressure, not a transport fault.
  // k6 may attach an error_code to non-2xx responses, so status 0 is the only
  // reliable transport-error discriminator here.
  if (response.status === 0) {
    transportErrors.add(1);
  } else if (!(response.status >= 200 && response.status < 400) && response.status !== 429 && response.status !== 503) {
    unexpectedStatusErrors.add(1);
  }
  check(response, {
    'expected reliability status': value =>
      (value.status >= 200 && value.status < 400) || value.status === 429 || value.status === 503,
    'instance correlation present': value => Boolean(value.headers['X-Instance-Id']),
  });
}
