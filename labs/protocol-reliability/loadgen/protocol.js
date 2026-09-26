import http from 'k6/http';
import { expectedStatuses, setResponseCallback } from 'k6/http';
import grpc from 'k6/net/grpc';
import ws from 'k6/ws';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { withPerfBaggage } from '../../../harness/adapters/loadgen/k6/baggage.js';
const actualStatusErrors = new Counter('perflab_http_non_2xx_3xx');
const actualTransportErrors = new Counter('perflab_http_transport_errors');
function recordHttpOutcome(response) {
  actualStatusErrors.add(response.status !== 0 && (response.status < 200 || response.status >= 400) ? 1 : 0);
  actualTransportErrors.add(response.status === 0 ? 1 : 0);
}


const baseUrl = __ENV.PERF_BASE_URL || 'http://127.0.0.1:18080';
const websocketUrl = baseUrl.replace(/^http/, 'ws');
const grpcTarget = __ENV.PERF_GRPC_TARGET || '127.0.0.1:18081';
const scenario = __ENV.PERF_SCENARIO || 'P01';
const runId = __ENV.PERF_RUN_ID || 'k6-manual';
const protocolFailures = new Counter('protocol_failures');
let reportedHandshakeFailure = false;
const client = new grpc.Client();
client.load(['.'], 'reliability.proto');
setResponseCallback(expectedStatuses({ min: 200, max: 399 }, 429, 503));

export const options = {
  discardResponseBodies: false,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
  thresholds: { protocol_failures: ['count==0'] },
};

function grpcPing() {
  client.connect(grpcTarget, { plaintext: true });
  const response = client.invoke('reliability.v1.Reliability/Ping', {
    runId,
    tenant: 'default',
    workUnits: 10,
  });
  const ok = check(response, {
    'gRPC status OK': value => value && value.status === grpc.StatusOK,
    'gRPC instance returned': value => value && value.message && Boolean(value.message.instanceId),
  });
  if (!ok) protocolFailures.add(1);
  client.close();
}

function rawWebSocket() {
  const response = ws.connect(`${websocketUrl}/ws`, {}, socket => {
    socket.on('open', () => socket.send(`${runId}|${__VU}|${__ITER}`));
    socket.on('message', message => {
      const ok = check(message, { 'WebSocket echo correlated': value => value.includes(runId) });
      if (!ok) protocolFailures.add(1);
      socket.close();
    });
    socket.setTimeout(() => socket.close(), 2000);
  });
  if (!response || response.status !== 101) {
    protocolFailures.add(1);
    // Bound diagnostic logging to one failure per VU; the full count remains
    // in protocol_failures even when handshake failures dominate a run.
    if (!reportedHandshakeFailure) {
      reportedHandshakeFailure = true;
      console.warn(JSON.stringify({event: 'websocket-handshake-failed', status: response && response.status, errorCode: response && response.error_code, error: response && response.error}));
    }
  }
}

function signalR() {
  const negotiate = http.post(`${baseUrl}/signalr/negotiate?negotiateVersion=1`, null);
  const token = negotiate.json('connectionToken');
  if (!token) {
    protocolFailures.add(1);
    return;
  }
  let completed = false;
  ws.connect(`${websocketUrl}/signalr?id=${encodeURIComponent(token)}`, {}, socket => {
    socket.on('open', () => socket.send('{"protocol":"json","version":1}\u001e'));
    let invoked = false;
    socket.on('message', message => {
      if (!invoked && message === '{}\u001e') {
        invoked = true;
        socket.send(`${JSON.stringify({
          type: 1,
          invocationId: `${__VU}-${__ITER}`,
          target: 'Echo',
          arguments: [runId, 'default', 'hello'],
        })}\u001e`);
        return;
      }
      const ok = check(message, {
        'SignalR completion correlated': value =>
          value.includes('invocationId') && value.includes(runId) && value.endsWith('\u001e'),
      });
      completed = ok;
      if (!ok) protocolFailures.add(1);
      socket.close();
    });
    socket.setTimeout(() => socket.close(), 3000);
  });
  if (!completed) protocolFailures.add(1);
}

function messaging() {
  const response = http.post(`${baseUrl}/api/reliability/messages?tenant=protocol`, null, {
    headers: withPerfBaggage({ 'X-Perf-Run-Id': runId }, runId),
  });
  recordHttpOutcome(response);
  const ok = check(response, {
    'message accepted or backpressured': value => value.status === 202 || value.status === 429,
  });
  if (!ok) protocolFailures.add(1);
}

export default function () {
  if (scenario === 'P01') grpcPing();
  else if (scenario === 'P02') rawWebSocket();
  else if (scenario === 'P03') signalR();
  else if (scenario === 'P04') messaging();
  else throw new Error(`unsupported protocol scenario ${scenario}`);
}
