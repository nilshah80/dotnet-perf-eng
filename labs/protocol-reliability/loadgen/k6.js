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
  check(response, {
    'expected reliability status': value =>
      (value.status >= 200 && value.status < 400) || value.status === 429 || value.status === 503,
    'instance correlation present': value => Boolean(value.headers['X-Instance-Id']),
  });
}
