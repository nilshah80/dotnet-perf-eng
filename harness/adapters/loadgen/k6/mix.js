// Weighted request-mix helper, shared by the default k6 workload and every
// lab's k6.js. When PERF_MIX is set (a JSON array of {method,path,body,weight})
// each iteration picks a weighted-random request from the blend -- realistic
// mixed traffic (e.g. 70% list / 20% search / 10% checkout) that a single-
// endpoint scenario cannot express -- and it composes with any load profile.
// When PERF_MIX is unset, mixEnabled is false and the caller uses its single
// PERF_* request, so unauthenticated and authenticated labs are unaffected.
const raw = __ENV.PERF_MIX || '';
let entries = null;
let cumulative = [];
let total = 0;

if (raw) {
  entries = JSON.parse(raw);
  if (!Array.isArray(entries) || entries.length === 0) {
    throw new Error('PERF_MIX must be a non-empty JSON array of {method,path,body,weight}');
  }
  for (const e of entries) {
    total += (typeof e.weight === 'number' && e.weight > 0) ? e.weight : 1;
    cumulative.push(total);
  }
}

export const mixEnabled = entries !== null;

// Returns { method, path, body } for one weighted-random request in the blend.
export function pickRequest() {
  const x = Math.random() * total;
  let i = 0;
  while (i < cumulative.length - 1 && x > cumulative[i]) i++;
  const e = entries[i];
  return {
    method: (e.method || 'GET').toUpperCase(),
    path: e.path || '/',
    body: e.body || '',
  };
}
