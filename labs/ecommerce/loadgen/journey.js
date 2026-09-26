import http from 'k6/http';
import { sleep } from 'k6';
import {
  beginJourney,
  checkoutOperations,
  completeJourney,
  failJourney,
  recordAttempt,
  recordOperation,
  requirePartition,
} from '../../../harness/adapters/loadgen/k6/journey.js';
import { withPerfBaggage } from '../../../harness/adapters/loadgen/k6/baggage.js';

// Ecommerce checkout journey (login, browse, create, pay, poll, verify).
// Independently written for this lab. Auth, extraction, think time, and
// mid-step abort live here; parent/child counters live in the shared helper.
const baseUrl = (__ENV.PERF_BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const runId = __ENV.PERF_RUN_ID || 'k6-manual';
const loginUser = __ENV.PERF_LOGIN_USER || 'user1';
const loginPassword = __ENV.PERF_LOGIN_PASSWORD || 'Password123!';

export const options = {
  discardResponseBodies: false,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

function headers(token) {
  const value = {
    Accept: 'application/json',
    'Content-Type': 'application/json',
    'X-Perf-Run-Id': runId,
  };
  if (token) {
    value.Authorization = `Bearer ${token}`;
  }
  return { headers: withPerfBaggage(value, runId), tags: {} };
}

function tagged(params, op) {
  return Object.assign({}, params, { tags: { name: `op::${op}`, operation: op } });
}

export default function () {
  const startedAt = beginJourney();

  const login = recordAttempt('login', http.post(
    `${baseUrl}/api/auth/login`,
    JSON.stringify({ username: loginUser, password: loginPassword }),
    tagged(headers(''), 'login'),
  ));
  const token = login.status === 200 ? login.json('token') : '';
  if (!recordOperation('login', login, !!token)) {
    failJourney(startedAt);
    return checkoutOperations;
  }
  sleep(0.05);

  const browse = recordAttempt('browse', http.get(
    `${baseUrl}/api/products?page=1&pageSize=25`,
    tagged(headers(token), 'browse'),
  ));
  const productId = browse.status === 200 ? browse.json('items.0.id') : null;
  if (!recordOperation('browse', browse, !!productId)) {
    failJourney(startedAt);
    return checkoutOperations;
  }
  sleep(0.05);

  requirePartition('create');
  const create = recordAttempt('create', http.post(
    `${baseUrl}/api/orders`,
    JSON.stringify({
      items: [{ productId: productId, quantity: 1 }],
      clientOrderId: `${runId}-${__VU}-${__ITER}`,
    }),
    tagged(headers(token), 'create'),
  ));
  const orderId = (create.status === 201 || create.status === 200)
    ? String(create.json('id') || '')
    : '';
  if (!recordOperation('create', create, !!orderId)) {
    failJourney(startedAt);
    return checkoutOperations;
  }
  sleep(0.05);

  requirePartition('pay');
  const pay = recordAttempt('pay', http.post(
    `${baseUrl}/api/orders/${orderId}/payment`,
    JSON.stringify({ idempotencyKey: `${runId}-${__VU}-${__ITER}-${orderId}` }),
    tagged(headers(token), 'pay'),
  ));
  if (!recordOperation('pay', pay)) {
    failJourney(startedAt);
    return checkoutOperations;
  }
  sleep(0.05);

  let poll;
  let status = '';
  for (let attempt = 0; attempt < 8; attempt += 1) {
    poll = recordAttempt('poll', http.get(
      `${baseUrl}/api/orders/${orderId}`,
      tagged(headers(token), 'poll'),
    ), attempt > 0);
    if (poll.status === 200) {
      status = String(poll.json('status') || '');
      if (status === 'completed' || status === 'failed') {
        break;
      }
    }
    sleep(0.1);
  }
  if (!recordOperation('poll', poll, status === 'completed')) {
    failJourney(startedAt);
    return checkoutOperations;
  }

  const verify = recordAttempt('verify', http.get(
    `${baseUrl}/api/perf/runs/${runId}/orders/${orderId}`,
    tagged(headers(token), 'verify'),
  ));
  if (!recordOperation('verify', verify)) {
    failJourney(startedAt);
    return checkoutOperations;
  }

  completeJourney(startedAt);
  return checkoutOperations;
}
