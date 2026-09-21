// P13 is a real multi-origin journey. The manifest's closed allowedOrigins
// list is injected as PERF_ALLOWED_ORIGINS by both product compilers. Every
// request below is constructed through allowedRoute; a supplied secondary
// origin outside that list throws during k6 initialization, before any VU can
// emit traffic.
import http from 'k6/http';
import { expectedStatuses, setResponseCallback } from 'k6/http';
import { Counter } from 'k6/metrics';
import {
  beginJourney,
  completeJourney,
  failJourney,
  recordAttempt,
  recordOperation,
} from '../../../harness/adapters/loadgen/k6/journey.js';

const primaryRequests = new Counter('multi_origin_primary_requests');
const secondaryRequests = new Counter('multi_origin_secondary_requests');
const runId = __ENV.PERF_RUN_ID || 'k6-multi-origin-journey';

setResponseCallback(expectedStatuses({ min: 200, max: 399 }));

export const options = {
  discardResponseBodies: false,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

function canonicalOrigin(value, name) {
  if (typeof value !== 'string') {
    throw new Error(`${name} must be an HTTP(S) origin`);
  }
  const match = /^(https?):\/\/([^\/?#@\s]+)\/?$/i.exec(value.trim());
  if (!match) {
    throw new Error(`${name} must be a credential-free HTTP(S) origin without a path`);
  }
  return `${match[1].toLowerCase()}://${match[2].toLowerCase()}`;
}

function parseAllowedOrigins() {
  if (!__ENV.PERF_ALLOWED_ORIGINS) {
    throw new Error('P13 requires manifest-derived PERF_ALLOWED_ORIGINS');
  }
  let raw;
  try {
    raw = JSON.parse(__ENV.PERF_ALLOWED_ORIGINS);
  } catch (_) {
    throw new Error('PERF_ALLOWED_ORIGINS must be a JSON origin array');
  }
  if (!Array.isArray(raw) || raw.length < 2) {
    throw new Error('P13 requires at least two manifest-derived allowed origins');
  }
  const origins = {};
  raw.forEach(value => {
    const origin = canonicalOrigin(value, 'allowed origin');
    if (origins[origin]) {
      throw new Error(`PERF_ALLOWED_ORIGINS repeats ${origin}`);
    }
    origins[origin] = true;
  });
  return origins;
}

function allowedRoute(origins, origin, path) {
  const canonical = canonicalOrigin(origin, 'journey target');
  if (!origins[canonical]) {
    throw new Error(`journey target ${canonical} is not in PERF_ALLOWED_ORIGINS`);
  }
  if (typeof path !== 'string' || !/^\/[A-Za-z0-9._~!$&'()*+,;=:@%/?=-]*$/.test(path)) {
    throw new Error('journey route must be an absolute bounded path');
  }
  return `${canonical}${path}`;
}

const allowedOrigins = parseAllowedOrigins();
const primaryOrigin = canonicalOrigin(__ENV.PERF_BASE_URL || '', 'PERF_BASE_URL');
const secondaryOrigin = canonicalOrigin(__ENV.PERF_SECONDARY_BASE_URL || '', 'PERF_SECONDARY_BASE_URL');
const primaryStatusURL = allowedRoute(allowedOrigins, primaryOrigin, '/api/reliability/status');
const secondaryChurnURL = allowedRoute(allowedOrigins, secondaryOrigin,
  '/api/reliability/connection-churn?queueMs=2&serverMs=2');

function request(operation, url) {
  const response = http.get(url, {
    headers: { 'X-Perf-Run-Id': runId },
    tags: { name: `operation::${operation}` },
  });
  recordAttempt(operation, response, false, value => value.status === 200);
  return response;
}

export default function () {
  const started = beginJourney();
  const primary = request('primary-status', primaryStatusURL);
  primaryRequests.add(1);
  if (!recordOperation('primary-status', primary, Boolean(primary.headers['X-Instance-Id']), value => value.status === 200)) {
    failJourney(started);
    return;
  }

  const secondary = request('secondary-connection-churn', secondaryChurnURL);
  secondaryRequests.add(1);
  if (!recordOperation('secondary-connection-churn', secondary,
    secondary.headers['X-Perf-Server-Queue-Ms'] === '2' && Boolean(secondary.headers['X-Perf-Server-Work-Ms']),
    value => value.status === 200)) {
    failJourney(started);
    return;
  }
  completeJourney(started);
}
