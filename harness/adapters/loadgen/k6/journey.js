// Shared native k6 journey helper. Labs own the HTTP steps; this helper owns
// the parent/child, wire-attempt, retry, error-classification, and duration
// evidence needed to reconcile one complete user journey per iteration.
import { Counter, Trend } from 'k6/metrics';
import { check, fail } from 'k6';

export const checkoutOperations = ['login', 'browse', 'create', 'pay', 'poll', 'verify'];

const journeyStarts = new Counter('journey_starts');
const journeyCompleted = new Counter('journey_completed');
const journeyFailed = new Counter('journey_failed');
const journeyAborted = new Counter('journey_aborted');
const journeyChildOps = new Counter('journey_child_ops');
const journeyWireRequests = new Counter('journey_wire_requests');
const journeyRequestFailures = new Counter('journey_request_failures');
const journeyStatusErrors = new Counter('journey_status_errors');
const journeyTransportErrors = new Counter('journey_transport_errors');
const journeyRetries = new Counter('journey_retries');
const journeyRedirects = new Counter('journey_redirects');
const operationLatency = new Trend('journey_operation_latency');
const wireLatency = new Trend('journey_wire_latency');
const journeyDuration = new Trend('journey_duration');

function parentTags() {
  return { label: 'journey::checkout', role: 'parent' };
}

function childTags(name) {
  return { label: `op::${name}`, role: 'child', op: name };
}

function recordDuration(startedAt) {
  if (Number.isFinite(startedAt)) {
    journeyDuration.add(Math.max(0, Date.now() - startedAt), parentTags());
  }
}

export function beginJourney() {
  journeyStarts.add(1, parentTags());
  return Date.now();
}

export function recordAttempt(name, response, retry = false) {
  const tags = childTags(name);
  journeyWireRequests.add(1, tags);
  wireLatency.add(response.timings.duration, tags);
  if (retry) {
    journeyRetries.add(1, tags);
  }
  if (response.error_code || response.status === 0) {
    journeyTransportErrors.add(1, tags);
    journeyRequestFailures.add(1, tags);
  } else if (response.status < 200 || response.status >= 400) {
    journeyStatusErrors.add(1, tags);
    journeyRequestFailures.add(1, tags);
  }
  if (response.status >= 300 && response.status < 400) {
    journeyRedirects.add(1, tags);
  }
  return response;
}

export function recordOperation(name, response, valid = true) {
  const tags = childTags(name);
  journeyChildOps.add(1, tags);
  operationLatency.add(response.timings.duration, tags);
  return check(response, {
    [`op ${name} success`]: (r) => r.status >= 200 && r.status < 400 && !!valid,
  }, tags);
}

export function completeJourney(startedAt) {
  journeyCompleted.add(1, parentTags());
  recordDuration(startedAt);
}

export function failJourney(startedAt) {
  journeyFailed.add(1, parentTags());
  recordDuration(startedAt);
}

export function abortJourney(startedAt) {
  journeyAborted.add(1, parentTags());
  recordDuration(startedAt);
}

export function requirePartition(op) {
  if (op !== 'create' && op !== 'pay') {
    return;
  }
  const ready = (__ENV.PERF_PARTITION_READY || '') === '1';
  const runId = __ENV.PERF_RUN_ID || '';
  const ack = __ENV.PERF_WRITE_ACK || '';
  const budget = Number(__ENV.PERF_WRITE_BUDGET || '0');
  if (!ready || !runId) {
    fail(`journey operation ${op} requires managed-reference run-partition seed/reset before traffic`);
  }
  if (ack !== 'managed-reference' && ack !== 'i-understand-data-mutation') {
    fail(`journey operation ${op} requires write acknowledgement before traffic`);
  }
  if (!(budget > 0)) {
    fail(`journey operation ${op} requires a positive write budget before traffic`);
  }
}

export function parentChildNote() {
  return {
    parent: 'journey_starts / journey_completed / journey_failed / journey_aborted tagged journey::checkout',
    child: 'journey_child_ops tagged op::login, op::browse, op::create, op::pay, op::poll, op::verify',
    wire: 'journey_wire_requests and journey_retries reconcile request amplification',
  };
}
