// perflab-baggage-v1 (D-P1-8): the W3C baggage each request carries so the
// application stamps the request's run and phase on its spans, logs and request
// metrics. run.sh exports PERF_PHASE (warmup, measure or diagnostic). A value
// the application would reject is not sent, so the header never carries more
// than the two bounded members.
const RUN_ID = /^[A-Za-z0-9._:-]{1,128}$/;
const PHASES = ['warmup', 'measure', 'diagnostic'];

export function perfBaggage(runId, phase = __ENV.PERF_PHASE || '') {
  const members = [];
  if (RUN_ID.test(runId || '')) members.push(`perf.run.id=${runId}`);
  if (PHASES.includes(phase)) members.push(`perf.phase=${phase}`);
  return members.join(',');
}

// Adds the baggage header to a headers object and returns it.
export function withPerfBaggage(headers, runId) {
  const value = perfBaggage(runId);
  if (value) headers.baggage = value;
  return headers;
}
