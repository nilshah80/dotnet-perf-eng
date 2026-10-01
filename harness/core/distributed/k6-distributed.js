// The sole workload an authenticated native distributed agent may execute.
// It intentionally has no caller-supplied JavaScript, methods, headers, or
// paths: the agent supplies a target origin and a generated partition only.
// That closed surface prevents a distributed-load capability from becoming a
// generic remote command facility.
import http from 'k6/http';
import { sleep } from 'k6';
import { Counter } from 'k6/metrics';

const origin = (__ENV.PERFLAB_DISTRIBUTED_TARGET_ORIGIN || '').replace(/\/$/, '');
const runId = __ENV.PERFLAB_DISTRIBUTED_RUN_ID || '';
const shardId = __ENV.PERFLAB_DISTRIBUTED_SHARD_ID || '';
const partition = __ENV.PERFLAB_DISTRIBUTED_PARTITION || '';
const bounds = [1, 2, 5, 10, 20, 50, 100, 250, 500, 1000, 2500, 5000];

if (!/^https?:\/\/[^/?#]+$/i.test(origin) || !/^[A-Za-z0-9._-]{1,128}$/.test(runId) ||
    !/^[A-Za-z0-9._-]{1,128}$/.test(shardId) || !/^[A-Za-z0-9._-]{1,128}$/.test(partition)) {
  throw new Error('distributed agent requires a canonical target origin and bounded run/shard/partition ids');
}

const requests = new Counter('perflab_distributed_requests');
const failures = new Counter('perflab_distributed_failures');
const buckets = bounds.map((_, index) => new Counter(`perflab_distributed_latency_bucket_${index}`));
const overflow = new Counter('perflab_distributed_latency_bucket_overflow');

export const options = { discardResponseBodies: true };

// perflab-baggage-v1 (D-P1-8), inlined: this workload is a single closed file.
// A shard always runs the measured phase.
const perfBaggage = /^[A-Za-z0-9._:-]{1,128}$/.test(runId || '')
  ? { baggage: `perf.run.id=${runId},perf.phase=measure` }
  : {};

export default function () {
  const path = `/api/reliability/distributed/${encodeURIComponent(partition)}/${encodeURIComponent(shardId)}/${__VU}/${__ITER}`;
  const response = http.get(`${origin}${path}`, {
    headers: {
      'X-Perf-Run-Id': runId,
      'X-Perf-Data-Partition': partition,
      ...perfBaggage,
    },
    tags: { name: 'operation::distributed-request' },
  });
  requests.add(1);
  const valid = response.status >= 200 && response.status < 300 &&
    response.headers['X-Perf-Data-Partition'] === partition;
  if (!valid) {
    failures.add(1);
  }
  const elapsed = Math.max(0, response.timings.duration);
  const index = bounds.findIndex(bound => elapsed <= bound);
  if (index < 0) {
    overflow.add(1);
  } else {
    buckets[index].add(1);
  }
  // Keep the reference proof well below an accidental local stress test while
  // retaining real concurrent segment traffic. Production rate shaping belongs
  // to a future explicitly declared distributed profile.
  sleep(0.005);
}
