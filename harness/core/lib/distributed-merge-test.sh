#!/usr/bin/env bash
# C-3 fixture: merge the exact fixed-bucket wire format used by authenticated
# agents. Percentiles must be recomputed from merged counts, never averaged
# from per-agent p95 values; loss stays a controller policy, not an invisible
# numerical adjustment.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
fail() { echo "distributed-merge-test: $*" >&2; exit 1; }
command -v python3 >/dev/null || fail "python3 is required"

PYTHONDONTWRITEBYTECODE=1 python3 - "${root}/harness/core/distributed/agent.py" <<'PY' || fail "distributed histogram merge regressed"
import importlib.util
import pathlib
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("perflab_distributed_agent", pathlib.Path(sys.argv[1]))
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules[spec.name] = module
spec.loader.exec_module(module)

def part(shard, counts):
    return {
        "shardId": shard,
        "requests": sum(counts),
        "failures": 0,
        "histogram": {"counts": counts, "upperBoundsMilliseconds": module.BOUNDS_MS + ["+Inf"]},
        "saturation": {"droppedIterations": 0, "generatorSaturated": False},
    }

left = [95, 5] + [0] * (len(module.BOUNDS_MS) - 1)
right = [0, 5, 95] + [0] * (len(module.BOUNDS_MS) - 2)
merged = module.merge_results([part("shard-1", left), part("shard-2", right)])
if merged["requests"] != 200 or sum(merged["histogram"]["counts"]) != 200:
    raise SystemExit("merged request/histogram count mismatch")
if merged["percentilesMilliseconds"]["p95"] != 5:
    raise SystemExit(f"merged p95={merged['percentilesMilliseconds']['p95']}, expected bound 5")
shard_average = (module.percentile(left, .95) + module.percentile(right, .95)) / 2
if merged["percentilesMilliseconds"]["p95"] == shard_average:
    raise SystemExit("merged p95 was derived by averaging shard percentiles")
fingerprint = "sha256:" + "a" * 64
if module.admit_generator_fingerprint(None, fingerprint) != fingerprint:
    raise SystemExit("valid generator fingerprint was not admitted")
try:
    module.admit_generator_fingerprint(fingerprint, "sha256:" + "b" * 64)
except RuntimeError as exc:
    if "differs" not in str(exc):
        raise
else:
    raise SystemExit("mixed generator fleet was admitted")
print("distributed histogram merge recomputes p95 from fixed buckets", merged["percentilesMilliseconds"]["p95"])
PY

run="${root}/harness/core/run/run-scenario.sh"
grep -q 'performance_distributed_selector_preflight' "${run}" || fail "run-scenario.sh does not require a declared distributed selector"
grep -q 'distributed_measure' "${run}" || fail "run-scenario.sh does not invoke the authenticated distributed controller"
grep -q 'PERFLAB_DISTRIBUTED_TOKEN' "${run}" || fail "run-scenario.sh does not require an agent token"
! grep -q 'distributed execution is not implemented' "${run}" || fail "run-scenario.sh still advertises a refusal instead of the implemented controller"

echo "distributed histogram merge never averages percentiles"
