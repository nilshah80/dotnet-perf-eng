// P12 is an executable security journey, not a feature declaration. One
// iteration must retain the cookie issued at login, observe that its first
// bearer is expired, rotate the refresh token, reject a forged CSRF mutation,
// and then complete exactly one CSRF-protected mutation.
import http from 'k6/http';
import { expectedStatuses, setResponseCallback } from 'k6/http';
import {
  beginJourney,
  completeJourney,
  failJourney,
  recordAttempt,
  recordOperation,
  requirePartition,
} from '../../../harness/adapters/loadgen/k6/journey.js';

const baseUrl = (__ENV.PERF_BASE_URL || __ENV.BASE_URL || 'http://127.0.0.1:18080').replace(/\/$/, '');
const runId = __ENV.PERF_RUN_ID || 'k6-security-journey';

// 401 and 403 occur intentionally at verified security boundaries. The
// per-operation predicates below distinguish them from an unexpected failure.
setResponseCallback(expectedStatuses({ min: 200, max: 399 }, 401, 403));

export const options = {
  discardResponseBodies: false,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

function request(operation, method, path, body, headers, expected) {
  const response = http.request(method, `${baseUrl}${path}`, body, {
    headers: {
      'Content-Type': 'application/json',
      'X-Perf-Run-Id': runId,
      ...headers,
    },
    tags: { name: `operation::${operation}` },
  });
  recordAttempt(operation, response, false, expected);
  return response;
}

function json(response) {
  try {
    return response.json();
  } catch (_) {
    return {};
  }
}

function expected(status) {
  return response => response.status === status;
}

export default function () {
  requirePartition('create');
  const started = beginJourney();

  const login = request('login', 'POST', '/api/reliability/journey/login', null, {}, expected(201));
  const loginPayload = json(login);
  if (!recordOperation('login', login, Boolean(loginPayload.accessToken && loginPayload.refreshToken), expected(201))) {
    failJourney(started);
    return;
  }

  const form = request('form', 'GET', '/api/reliability/journey/form', null, {}, expected(200));
  const formPayload = json(form);
  if (!recordOperation('form', form, Boolean(formPayload.csrfToken), expected(200))) {
    failJourney(started);
    return;
  }

  // This 401 proves the initially issued access credential cannot bypass the
  // refresh transition. It is a successful child operation when it has the
  // documented response body.
  const expired = request('expired-access', 'GET', '/api/reliability/journey/protected', null,
    { Authorization: `Bearer ${loginPayload.accessToken || ''}` }, expected(401));
  const expiredPayload = json(expired);
  if (!recordOperation('expired-access', expired, expiredPayload.error === 'access-token-expired', expected(401))) {
    failJourney(started);
    return;
  }

  const refresh = request('refresh', 'POST', '/api/reliability/journey/refresh',
    JSON.stringify({ refreshToken: loginPayload.refreshToken }), {}, expected(200));
  const refreshPayload = json(refresh);
  if (!recordOperation('refresh', refresh,
    Boolean(refreshPayload.accessToken && refreshPayload.refreshToken && refreshPayload.csrfToken), expected(200))) {
    failJourney(started);
    return;
  }

  // A forged CSRF header must be rejected before it can create a submission.
  const csrfRejected = request('csrf-rejected', 'POST', '/api/reliability/journey/submit', null, {
    Authorization: `Bearer ${refreshPayload.accessToken || ''}`,
    'X-Perf-CSRF': 'forged-csrf-token',
  }, expected(403));
  const csrfPayload = json(csrfRejected);
  if (!recordOperation('csrf-rejected', csrfRejected, csrfPayload.error === 'csrf-rejected', expected(403))) {
    failJourney(started);
    return;
  }

  const submit = request('submit', 'POST', '/api/reliability/journey/submit', null, {
    Authorization: `Bearer ${refreshPayload.accessToken || ''}`,
    'X-Perf-CSRF': refreshPayload.csrfToken || '',
  }, expected(201));
  const submitPayload = json(submit);
  if (!recordOperation('submit', submit, Number(submitPayload.submission) >= 1, expected(201))) {
    failJourney(started);
    return;
  }

  // Refresh rotation is only real if the original credential is refused.
  const replay = request('refresh-replay-rejected', 'POST', '/api/reliability/journey/refresh',
    JSON.stringify({ refreshToken: loginPayload.refreshToken }), {}, expected(401));
  const replayPayload = json(replay);
  if (!recordOperation('refresh-replay-rejected', replay, replayPayload.error === 'refresh-rejected', expected(401))) {
    failJourney(started);
    return;
  }

  completeJourney(started);
}
