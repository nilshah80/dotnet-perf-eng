import { Counter } from 'k6/metrics';

// Weighted mix helper. PERF_MIX is a JSON array of request members
// {method,path,body,weight} or journey members {selector,weight}.
const raw = __ENV.PERF_MIX || '';
let entries = null;
let cumulative = [];
let total = 0;
const selectionSeed = __ENV.PERF_MIX_SEED || '';
const selectionCounter = new Counter('mix_selections');

if (raw) {
  entries = JSON.parse(raw);
  if (!Array.isArray(entries) || entries.length === 0) {
    throw new Error('PERF_MIX must be a non-empty JSON array of mix members');
  }
  if (!selectionSeed) {
    throw new Error('PERF_MIX_SEED is required for reproducible mix selection');
  }
  for (const e of entries) {
    if (typeof e.weight !== 'number' || !Number.isFinite(e.weight) || e.weight <= 0) {
      throw new Error('every mix member requires a finite positive weight');
    }
    total += e.weight;
    cumulative.push(total);
  }
}

export const mixEnabled = entries !== null;

export function pickMember() {
  const shard = __ENV.PERF_SHARD_ID || 'shard-1';
  const x = unitInterval(`${selectionSeed}:${shard}:${__VU}:${__ITER}`) * total;
  let i = 0;
  while (i < cumulative.length - 1 && x > cumulative[i]) i++;
  const e = entries[i];
  const selector = e.selector || '';
  const kind = selector ? 'journey' : 'request';
  const member = selector || e.name || e.path || `member-${i + 1}`;
  selectionCounter.add(1, { member, kind });
  return {
    kind,
    selector: selector,
    method: (e.method || 'GET').toUpperCase(),
    path: e.path || '/',
    body: e.body || '',
  };
}

function unitInterval(value) {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i += 1) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  // FNV-1a alone leaves the high bits correlated for keys that differ only in
  // their trailing VU/iteration digits; the murmur3 finalizer spreads them.
  hash ^= hash >>> 16;
  hash = Math.imul(hash, 0x85ebca6b);
  hash ^= hash >>> 13;
  hash = Math.imul(hash, 0xc2b2ae35);
  hash ^= hash >>> 16;
  return (hash >>> 0) / 4294967296;
}

export function pickRequest() {
  const member = pickMember();
  if (member.kind === 'journey') {
    throw new Error('journey mix members require a journey mix entrypoint');
  }
  return { method: member.method, path: member.path, body: member.body };
}
