#!/usr/bin/env python3
"""Closed, authenticated distributed k6 agent protocol (perflab-distributed/v1).

The server intentionally supports a single immutable request workload.  It
never accepts shell fragments, arbitrary JavaScript, arbitrary file paths, or
arbitrary HTTP methods.  A controller must authenticate, register within a
clock bound, acquire a one-use lease, then submit a shard that is constrained
to an agent-configured target origin.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

PROTOCOL = "perflab-distributed/v1"
TOKEN_HANDLE = "secret://PERFLAB_DISTRIBUTED_TOKEN"
MAX_BODY_BYTES = 64 * 1024
MAX_OUTPUT_BYTES = 64 * 1024
MAX_DURATION_SECONDS = 900
MAX_CONNECTIONS = 4096
TOKEN = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
GENERATOR_FINGERPRINT = re.compile(r"^sha256:[a-f0-9]{64}$")
BOUNDS_MS = [1, 2, 5, 10, 20, 50, 100, 250, 500, 1000, 2500, 5000]


class ProtocolError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def now_ms() -> int:
    return time.time_ns() // 1_000_000


def canonical_origin(value: str) -> str:
    parsed = urllib.parse.urlsplit(value.strip())
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("origin must be an absolute http(s) origin")
    if parsed.username or parsed.password or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("origin must not contain credentials, path, query, or fragment")
    host = parsed.hostname.lower()
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    port = parsed.port
    default = 80 if parsed.scheme == "http" else 443
    suffix = "" if port is None or port == default else f":{port}"
    return f"{parsed.scheme}://{host}{suffix}"


def loopback_origin(value: str) -> bool:
    try:
        host = urllib.parse.urlsplit(value).hostname
    except ValueError:
        return False
    return host in ("127.0.0.1", "::1", "localhost")


def bounded_identifier(name: str, value: Any) -> str:
    text = str(value or "")
    if not TOKEN.fullmatch(text):
        raise ProtocolError(400, f"{name} must be a bounded identifier")
    return text


def k6_generator_fingerprint() -> str:
    """Return a bounded identity for the actual k6 binary an agent will run.

    The controller needs this before it can call a multi-agent result
    comparable.  Retain only a digest: command output can vary by platform and
    is not useful evidence in its raw form, while a digest lets the controller
    reject a mixed k6 fleet and binds each result to the registered binary.
    """
    try:
        completed = subprocess.run(
            ["k6", "version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=15, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValueError(f"cannot identify the k6 generator: {exc}") from exc
    raw = completed.stdout + completed.stderr
    if completed.returncode != 0 or len(raw) > 4096:
        raise ValueError("cannot identify the bounded k6 generator version")
    normalized = " ".join(raw.decode("utf-8", errors="replace").split())
    if not normalized:
        raise ValueError("k6 version output is empty")
    return "sha256:" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def admit_generator_fingerprint(expected: str | None, candidate: Any) -> str:
    """Admit one fleet-wide k6 identity or refuse a mixed agent fleet."""
    if not isinstance(candidate, str) or not GENERATOR_FINGERPRINT.fullmatch(candidate):
        raise RuntimeError("agent registration omits a valid k6 generator fingerprint")
    if expected is not None and candidate != expected:
        raise RuntimeError("agent k6 generator fingerprint differs from the registered fleet")
    return candidate


def read_json(request: BaseHTTPRequestHandler) -> dict[str, Any]:
    raw_length = request.headers.get("Content-Length", "")
    try:
        length = int(raw_length)
    except ValueError as exc:
        raise ProtocolError(400, "Content-Length is required") from exc
    if length < 1 or length > MAX_BODY_BYTES:
        raise ProtocolError(413, "request body exceeds the distributed protocol limit")
    raw = request.rfile.read(length)
    if len(raw) != length:
        raise ProtocolError(400, "incomplete request body")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProtocolError(400, "request body must be JSON") from exc
    if not isinstance(value, dict):
        raise ProtocolError(400, "request body must be a JSON object")
    if value.get("protocol") != PROTOCOL:
        raise ProtocolError(400, f"protocol must be {PROTOCOL}")
    return value


def percentile(counts: list[int], fraction: float) -> int:
    total = sum(counts)
    if total <= 0:
        return 0
    rank = max(1, math.ceil(total * fraction))
    observed = 0
    for index, count in enumerate(counts):
        observed += count
        if observed >= rank:
            return BOUNDS_MS[index] if index < len(BOUNDS_MS) else BOUNDS_MS[-1]
    return BOUNDS_MS[-1]


def metric_count(metrics: dict[str, Any], name: str) -> int:
    metric = metrics.get(name)
    if not isinstance(metric, dict):
        return 0
    # k6 0.x emitted metric values under `values`; k6 2.x emits the same
    # counter fields directly. The closed histogram contract accepts either
    # schema but never derives samples from percentile summaries.
    values = metric.get("values") if isinstance(metric.get("values"), dict) else metric
    value = values.get("count", 0)
    if not isinstance(value, (int, float)) or value < 0:
        raise ValueError(f"summary metric {name} count is invalid")
    return int(value)


def load_result(summary_path: Path, *, agent_id: str, generator_fingerprint: str, request: dict[str, Any], started_at: int, ended_at: int) -> dict[str, Any]:
    try:
        raw = summary_path.read_bytes()
        if len(raw) > MAX_BODY_BYTES:
            raise ValueError("k6 summary exceeds the distributed protocol limit")
        summary = json.loads(raw)
        metrics = summary.get("metrics")
        if not isinstance(metrics, dict):
            raise ValueError("k6 summary has no metrics object")
        requests = metric_count(metrics, "perflab_distributed_requests")
        failures = metric_count(metrics, "perflab_distributed_failures")
        counts = [metric_count(metrics, f"perflab_distributed_latency_bucket_{index}") for index in range(len(BOUNDS_MS))]
        counts.append(metric_count(metrics, "perflab_distributed_latency_bucket_overflow"))
        dropped = metric_count(metrics, "dropped_iterations")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise ProtocolError(502, f"cannot parse bounded k6 shard result: {exc}") from exc
    if requests < 1 or sum(counts) != requests or failures > requests:
        raise ProtocolError(502, "k6 shard summary violates the fixed histogram contract "
                            f"(requests={requests}, histogramCount={sum(counts)}, failures={failures})")
    return {
        "protocol": PROTOCOL,
        "agentId": agent_id,
        "generatorFingerprint": generator_fingerprint,
        "runId": request["runId"],
        "shardId": request["shardId"],
        "dataPartition": request["dataPartition"],
        "executionSegment": request["executionSegment"],
        "startedAtUnixMilliseconds": started_at,
        "endedAtUnixMilliseconds": ended_at,
        "requests": requests,
        "failures": failures,
        "histogram": {"upperBoundsMilliseconds": BOUNDS_MS + ["+Inf"], "counts": counts},
        "saturation": {"droppedIterations": dropped, "generatorSaturated": dropped > 0},
    }


@dataclass
class Lease:
    registration_id: str
    run_id: str
    shard_id: str
    expires_at_ms: int
    consumed: bool = False


class AgentState:
    def __init__(self, *, agent_id: str, token: str, allow_origins: set[str], root: Path):
        self.agent_id = bounded_identifier("agent id", agent_id)
        if not token:
            raise ValueError("distributed agent token environment variable is empty")
        self.token = token
        self.allow_origins = allow_origins
        self.script = root / "harness" / "core" / "distributed" / "k6-distributed.js"
        if not self.script.is_file():
            raise ValueError(f"distributed k6 script is missing: {self.script}")
        self.generator_fingerprint = k6_generator_fingerprint()
        self.registrations: dict[str, tuple[str, str]] = {}
        self.leases: dict[str, Lease] = {}
        self.lease_by_shard: set[tuple[str, str]] = set()
        self.lock = threading.Lock()

    def authorized(self, supplied: str | None) -> bool:
        return bool(supplied) and hmac.compare_digest(supplied, f"Bearer {self.token}")

    def registration(self, payload: dict[str, Any]) -> dict[str, Any]:
        controller_id = bounded_identifier("controllerId", payload.get("controllerId"))
        run_id = bounded_identifier("runId", payload.get("runId"))
        controller_at = payload.get("controllerUnixMilliseconds")
        if not isinstance(controller_at, int) or controller_at <= 0:
            raise ProtocolError(400, "controllerUnixMilliseconds is required")
        registration_id = secrets.token_urlsafe(24)
        with self.lock:
            self.registrations[registration_id] = (controller_id, run_id)
        return {
            "protocol": PROTOCOL,
            "agentId": self.agent_id,
            "registrationId": registration_id,
            "agentUnixMilliseconds": now_ms(),
            "clockSkewMilliseconds": now_ms() - controller_at,
            "capabilities": ["k6-request-v1", "fixed-histogram-v1", "execution-segments-v1"],
            "generatorFingerprint": self.generator_fingerprint,
        }

    def lease(self, payload: dict[str, Any]) -> dict[str, Any]:
        registration_id = str(payload.get("registrationId") or "")
        run_id = bounded_identifier("runId", payload.get("runId"))
        shard_id = bounded_identifier("shardId", payload.get("shardId"))
        expires_at = payload.get("expiresAtUnixMilliseconds")
        if not isinstance(expires_at, int) or expires_at <= now_ms() or expires_at > now_ms() + 3_600_000:
            raise ProtocolError(400, "lease expiry must be within the next hour")
        with self.lock:
            registered = self.registrations.get(registration_id)
            if registered is None or registered[1] != run_id:
                raise ProtocolError(403, "lease requires an authenticated registration for this run")
            key = (run_id, shard_id)
            if key in self.lease_by_shard:
                raise ProtocolError(409, "a lease already exists for this run and shard")
            lease_id = secrets.token_urlsafe(24)
            self.leases[lease_id] = Lease(registration_id, run_id, shard_id, expires_at)
            self.lease_by_shard.add(key)
        return {"protocol": PROTOCOL, "agentId": self.agent_id, "leaseId": lease_id, "expiresAtUnixMilliseconds": expires_at}

    def execute(self, payload: dict[str, Any]) -> dict[str, Any]:
        lease_id = str(payload.get("leaseId") or "")
        run_id = bounded_identifier("runId", payload.get("runId"))
        shard_id = bounded_identifier("shardId", payload.get("shardId"))
        partition = bounded_identifier("dataPartition", payload.get("dataPartition"))
        try:
            target_origin = canonical_origin(str(payload.get("targetOrigin") or ""))
        except ValueError as exc:
            raise ProtocolError(400, str(exc)) from exc
        if target_origin not in self.allow_origins:
            raise ProtocolError(403, "target origin is not allowlisted for this agent")
        duration = payload.get("durationSeconds")
        connections = payload.get("connections")
        total_connections = payload.get("totalConnections")
        segment = str(payload.get("executionSegment") or "")
        sequence = str(payload.get("executionSegmentSequence") or "")
        if not isinstance(duration, int) or not 1 <= duration <= MAX_DURATION_SECONDS:
            raise ProtocolError(400, "durationSeconds is outside the distributed agent limit")
        if not isinstance(connections, int) or not 1 <= connections <= MAX_CONNECTIONS:
            raise ProtocolError(400, "connections is outside the distributed agent limit")
        if not isinstance(total_connections, int) or not connections <= total_connections <= MAX_CONNECTIONS:
            raise ProtocolError(400, "totalConnections is outside the distributed agent limit")
        if not re.fullmatch(r"(?:0|1|[1-9][0-9]*/[1-9][0-9]*):(?:1|[1-9][0-9]*/[1-9][0-9]*)", segment):
            raise ProtocolError(400, "executionSegment is invalid")
        if not re.fullmatch(r"0(?:,[1-9][0-9]*/[1-9][0-9]*)+,1", sequence):
            raise ProtocolError(400, "executionSegmentSequence is invalid")
        with self.lock:
            lease = self.leases.get(lease_id)
            if lease is None or lease.consumed or lease.expires_at_ms <= now_ms() or lease.run_id != run_id or lease.shard_id != shard_id:
                raise ProtocolError(403, "execution requires one valid, unconsumed shard lease")
            lease.consumed = True
        started = now_ms()
        with tempfile.TemporaryDirectory(prefix="perflab-distributed-") as temp_dir:
            summary = Path(temp_dir) / "summary.json"
            command = [
                "k6", "run", "--execution-segment", segment,
                "--execution-segment-sequence", sequence,
                # k6 partitions a global executor. Every agent therefore
                # receives the same global VU total plus a disjoint segment;
                # using the already-divided shard count here would round an
                # upper segment down to zero VUs and silently lose traffic.
                "--vus", str(total_connections), "--duration", f"{duration}s",
                "--quiet", "--no-color", "--summary-export", str(summary), str(self.script),
            ]
            environment = {
                "PATH": os.environ.get("PATH", ""),
                "HOME": os.environ.get("HOME", ""),
                "TMPDIR": os.environ.get("TMPDIR", ""),
                "PERFLAB_DISTRIBUTED_TARGET_ORIGIN": target_origin,
                "PERFLAB_DISTRIBUTED_RUN_ID": run_id,
                "PERFLAB_DISTRIBUTED_SHARD_ID": shard_id,
                "PERFLAB_DISTRIBUTED_PARTITION": partition,
            }
            try:
                completed = subprocess.run(
                    # The JSON summary is the only retained output. Discard
                    # textual output at the child boundary so target-derived
                    # text cannot become an unbounded agent-memory or evidence
                    # channel.
                    command, cwd=temp_dir, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=duration + 60, check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise ProtocolError(502, f"distributed k6 process did not complete: {exc}") from exc
            if completed.returncode != 0:
                # Do not return generator stdout/stderr: it may include target data.
                raise ProtocolError(502, f"distributed k6 shard exited with status {completed.returncode}")
            result = load_result(summary, agent_id=self.agent_id, generator_fingerprint=self.generator_fingerprint,
                                 request=payload, started_at=started, ended_at=now_ms())
        return result


class AgentHandler(BaseHTTPRequestHandler):
    server: "AgentServer"
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: Any) -> None:
        # Do not log request paths or Authorization headers into evidence/logs.
        return

    def respond(self, status: int, payload: dict[str, Any]) -> None:
        raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def require_auth(self) -> None:
        if not self.server.state.authorized(self.headers.get("Authorization")):
            raise ProtocolError(401, "distributed agent authentication failed")

    def do_GET(self) -> None:  # noqa: N802
        try:
            if self.path != "/v1/info":
                raise ProtocolError(404, "unknown distributed agent endpoint")
            self.require_auth()
            self.respond(200, {"protocol": PROTOCOL, "agentId": self.server.state.agent_id,
                                "agentUnixMilliseconds": now_ms(),
                                "capabilities": ["k6-request-v1", "fixed-histogram-v1", "execution-segments-v1"],
                                "generatorFingerprint": self.server.state.generator_fingerprint})
        except ProtocolError as exc:
            self.respond(exc.status, {"protocol": PROTOCOL, "error": str(exc)})

    def do_POST(self) -> None:  # noqa: N802
        try:
            self.require_auth()
            payload = read_json(self)
            if self.path == "/v1/registrations":
                result = self.server.state.registration(payload)
            elif self.path == "/v1/leases":
                result = self.server.state.lease(payload)
            elif self.path == "/v1/executions":
                result = self.server.state.execute(payload)
            else:
                raise ProtocolError(404, "unknown distributed agent endpoint")
            self.respond(200, result)
        except ProtocolError as exc:
            self.respond(exc.status, {"protocol": PROTOCOL, "error": str(exc)})


class AgentServer(ThreadingHTTPServer):
    def __init__(self, address: tuple[str, int], state: AgentState):
        super().__init__(address, AgentHandler)
        self.state = state


def request_json(url: str, token: str, payload: dict[str, Any] | None = None, timeout: float = 20.0) -> dict[str, Any]:
    method = "GET" if payload is None else "POST"
    data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token}", "Accept": "application/json",
        **({"Content-Type": "application/json"} if data is not None else {}),
    })
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(MAX_BODY_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raw = exc.read(MAX_BODY_BYTES + 1)
        try:
            detail = json.loads(raw).get("error", "agent returned an HTTP error")
        except (ValueError, AttributeError):
            detail = "agent returned an HTTP error"
        raise RuntimeError(f"{url}: HTTP {exc.code}: {detail}") from exc
    except OSError as exc:
        raise RuntimeError(f"{url}: {exc}") from exc
    if len(raw) > MAX_BODY_BYTES:
        raise RuntimeError(f"{url}: response exceeds protocol limit")
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{url}: response is not JSON") from exc
    if not isinstance(decoded, dict) or decoded.get("protocol") != PROTOCOL:
        raise RuntimeError(f"{url}: response does not speak {PROTOCOL}")
    return decoded


def safe_agent_url(value: str, allow_insecure_local: bool) -> str:
    parsed = urllib.parse.urlsplit(value.strip())
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("agent URL must be a canonical http(s) origin")
    origin = canonical_origin(value)
    if parsed.scheme != "https" and not (allow_insecure_local and loopback_origin(origin)):
        raise ValueError("non-loopback distributed agents require HTTPS; set PERFLAB_DISTRIBUTED_ALLOW_INSECURE_LOCAL=1 only for a loopback fixture")
    return origin


def shard_connections(total: int, shards: int) -> list[int]:
    if total < shards:
        raise ValueError("distributed connections must be at least the shard count")
    base, extra = divmod(total, shards)
    return [base + (1 if index < extra else 0) for index in range(shards)]


def segment(index: int, shards: int) -> str:
    left = "0" if index == 0 else f"{index}/{shards}"
    right = "1" if index + 1 == shards else f"{index + 1}/{shards}"
    return f"{left}:{right}"


def merge_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    counts = [0] * (len(BOUNDS_MS) + 1)
    requests = failures = dropped = 0
    shard_saturation: dict[str, bool] = {}
    for result in results:
        histogram = result.get("histogram")
        current = histogram.get("counts") if isinstance(histogram, dict) else None
        if not isinstance(current, list) or len(current) != len(counts) or any(not isinstance(item, int) or item < 0 for item in current):
            raise ValueError("agent result does not contain the fixed mergeable histogram")
        for index, item in enumerate(current):
            counts[index] += item
        result_requests = result.get("requests")
        result_failures = result.get("failures")
        if not isinstance(result_requests, int) or not isinstance(result_failures, int) or result_requests < 1 or result_failures < 0 or result_failures > result_requests:
            raise ValueError("agent result request counters are invalid")
        requests += result_requests
        failures += result_failures
        saturation = result.get("saturation")
        is_saturated = bool(isinstance(saturation, dict) and saturation.get("generatorSaturated"))
        shard_saturation[str(result.get("shardId", "unknown"))] = is_saturated
        dropped += int(saturation.get("droppedIterations", 0)) if isinstance(saturation, dict) else 0
    if sum(counts) != requests:
        raise ValueError("merged histogram count does not match merged request count")
    return {
        "requests": requests,
        "failures": failures,
        "histogram": {"upperBoundsMilliseconds": BOUNDS_MS + ["+Inf"], "counts": counts},
        "percentilesMilliseconds": {"p50": percentile(counts, .50), "p90": percentile(counts, .90), "p95": percentile(counts, .95), "p99": percentile(counts, .99)},
        "saturation": {"droppedIterations": dropped, "byShard": shard_saturation},
    }


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def controller(args: argparse.Namespace) -> int:
    token = os.environ.get(args.token_env, "")
    if not token:
        raise ValueError(f"{args.token_env} must contain the distributed agent token")
    run_id = bounded_identifier("run id", args.run_id)
    if len(run_id) > 120:
        raise ValueError("distributed run id must leave room for a bounded per-shard partition")
    target = canonical_origin(args.target_origin)
    agent_urls = [safe_agent_url(part, args.allow_insecure_local) for part in args.agents.split(",") if part.strip()]
    if args.shards < 2 or args.shards != len(agent_urls):
        raise ValueError("shards must be at least two and equal the number of declared agent URLs")
    if args.duration_seconds < 1 or args.duration_seconds > MAX_DURATION_SECONDS:
        raise ValueError("duration-seconds is outside the distributed agent limit")
    allocations = shard_connections(args.connections, args.shards)
    controller_id = bounded_identifier("controller id", args.controller_id)
    output = Path(args.artifact_dir) / "benchmark" / "distributed-aggregate.json"
    plan_path = Path(args.artifact_dir) / "benchmark" / "distributed-plan.json"
    sequence = ",".join(["0"] + [f"{index}/{args.shards}" for index in range(1, args.shards)] + ["1"])
    shards = [{
        "id": f"shard-{index + 1}", "agentURL": agent_urls[index], "connections": allocations[index],
        "executionSegment": segment(index, args.shards),
        "dataPartition": f"d-{run_id}-s{index + 1}",
    } for index in range(args.shards)]
    plan = {"protocol": PROTOCOL, "runId": run_id, "controllerId": controller_id,
            "tokenReference": TOKEN_HANDLE, "targetOrigin": target, "executionSegmentSequence": sequence,
            "partialAllowed": args.allow_partial, "shards": shards}
    write_json(plan_path, plan)
    registrations: list[dict[str, Any] | None] = [None] * args.shards
    losses: list[dict[str, str]] = []
    generator_fingerprint: str | None = None
    for index, item in enumerate(shards):
        start = now_ms()
        try:
            response = request_json(item["agentURL"] + "/v1/registrations", token, {
                "protocol": PROTOCOL, "controllerId": controller_id, "runId": run_id,
                "controllerUnixMilliseconds": start,
            })
            end = now_ms()
            agent_id = bounded_identifier("agentId", response.get("agentId"))
            agent_time = response.get("agentUnixMilliseconds")
            if not isinstance(agent_time, int) or abs(agent_time - ((start + end) // 2)) > args.max_clock_skew_ms:
                raise RuntimeError("agent clock exceeds the configured skew bound")
            if "k6-request-v1" not in response.get("capabilities", []):
                raise RuntimeError("agent does not advertise the required k6 request capability")
            fingerprint = admit_generator_fingerprint(generator_fingerprint, response.get("generatorFingerprint"))
            generator_fingerprint = fingerprint
            registrations[index] = {"agentId": agent_id, "registrationId": response.get("registrationId"),
                                    "generatorFingerprint": fingerprint}
        except (RuntimeError, ProtocolError) as exc:
            losses.append({"shardId": item["id"], "agentURL": item["agentURL"], "stage": "registration", "reason": str(exc)})
    if losses and not args.allow_partial:
        write_json(output, {"protocol": PROTOCOL, "runId": run_id, "status": "failed-closed", "tokenReference": TOKEN_HANDLE,
                            "lostAgents": losses, "reason": "one or more agents failed registration; no partial merge was permitted"})
        raise RuntimeError("distributed execution failed closed because one or more agents could not register")
    if generator_fingerprint is None:
        write_json(output, {"protocol": PROTOCOL, "runId": run_id, "status": "failed", "tokenReference": TOKEN_HANDLE,
                            "lostAgents": losses, "reason": "no agent supplied a valid k6 generator fingerprint"})
        raise RuntimeError("no registered distributed agent supplied a valid k6 generator fingerprint")
    # The pre-registration plan records requested intent even when the fleet
    # fails closed. After a fleet is admitted it must also bind the actual k6
    # identity every completed shard will be checked against.
    plan["generatorFingerprint"] = generator_fingerprint
    write_json(plan_path, plan)
    leases: list[str | None] = [None] * args.shards
    for index, item in enumerate(shards):
        registration = registrations[index]
        if registration is None:
            continue
        try:
            response = request_json(item["agentURL"] + "/v1/leases", token, {
                "protocol": PROTOCOL, "registrationId": registration["registrationId"], "runId": run_id,
                "shardId": item["id"], "expiresAtUnixMilliseconds": now_ms() + (args.duration_seconds + 90) * 1000,
            })
            lease_id = response.get("leaseId")
            if not isinstance(lease_id, str) or not lease_id:
                raise RuntimeError("agent omitted lease id")
            leases[index] = lease_id
        except RuntimeError as exc:
            losses.append({"shardId": item["id"], "agentURL": item["agentURL"], "stage": "lease", "reason": str(exc)})
    if losses and not args.allow_partial:
        write_json(output, {"protocol": PROTOCOL, "runId": run_id, "status": "failed-closed", "tokenReference": TOKEN_HANDLE,
                            "lostAgents": losses, "reason": "one or more agents failed lease acquisition; no partial merge was permitted"})
        raise RuntimeError("distributed execution failed closed because one or more agents could not acquire a lease")

    def execute_one(index: int) -> tuple[int, dict[str, Any] | None, dict[str, str] | None]:
        item = shards[index]
        if leases[index] is None:
            return index, None, None
        try:
            response = request_json(item["agentURL"] + "/v1/executions", token, {
                "protocol": PROTOCOL, "leaseId": leases[index], "runId": run_id, "shardId": item["id"],
                "targetOrigin": target, "durationSeconds": args.duration_seconds, "connections": item["connections"],
                "totalConnections": args.connections,
                "executionSegment": item["executionSegment"], "executionSegmentSequence": sequence,
                "dataPartition": item["dataPartition"],
            }, timeout=args.duration_seconds + 75)
            if response.get("dataPartition") != item["dataPartition"] or response.get("executionSegment") != item["executionSegment"]:
                raise RuntimeError("agent response does not bind the planned partition and execution segment")
            if response.get("generatorFingerprint") != registrations[index]["generatorFingerprint"]:
                raise RuntimeError("agent execution generator fingerprint differs from its registered identity")
            return index, response, None
        except RuntimeError as exc:
            return index, None, {"shardId": item["id"], "agentURL": item["agentURL"], "stage": "execution", "reason": str(exc)}

    successful: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.shards) as executor:
        futures = [executor.submit(execute_one, index) for index in range(args.shards) if leases[index] is not None]
        for future in concurrent.futures.as_completed(futures):
            _index, result, loss = future.result()
            if result is not None:
                successful.append(result)
            if loss is not None:
                losses.append(loss)
    if losses and not args.allow_partial:
        write_json(output, {"protocol": PROTOCOL, "runId": run_id, "status": "failed-closed", "tokenReference": TOKEN_HANDLE,
                            "lostAgents": losses, "completedShards": [item["shardId"] for item in successful],
                            "reason": "one or more agents were lost; no partial merge was permitted"})
        raise RuntimeError("distributed execution failed closed because one or more agents were lost")
    if not successful:
        write_json(output, {"protocol": PROTOCOL, "runId": run_id, "status": "failed", "tokenReference": TOKEN_HANDLE,
                            "lostAgents": losses, "reason": "no distributed shard completed"})
        raise RuntimeError("no distributed shard completed")
    aggregate = merge_results(successful)
    document = {"protocol": PROTOCOL, "runId": run_id, "status": "partial" if losses else "complete",
                "tokenReference": TOKEN_HANDLE, "partialAllowed": args.allow_partial, "partialLoss": bool(losses),
                "generatorFingerprint": generator_fingerprint, "lostAgents": losses,
                "agentResults": sorted(successful, key=lambda item: item["shardId"]), "aggregate": aggregate}
    write_json(output, document)
    observations = [
        {"name": "http.requests.total", "value": aggregate["requests"], "unit": "request", "source": "benchmark/distributed-aggregate.json"},
        {"name": "http.responses.non_2xx_3xx", "value": aggregate["failures"], "unit": "response", "source": "benchmark/distributed-aggregate.json"},
        {"name": "http.error_rate", "value": aggregate["failures"] / max(1, aggregate["requests"]), "unit": "ratio", "source": "benchmark/distributed-aggregate.json"},
    ] + [{"name": f"http.latency.{name}", "value": value, "unit": "ms", "source": "benchmark/distributed-aggregate.json"}
         for name, value in aggregate["percentilesMilliseconds"].items()]
    write_json(Path(args.artifact_dir) / "benchmark" / "observations.json", observations)
    print(json.dumps({"status": document["status"], "requests": aggregate["requests"], "lostAgents": len(losses)}))
    return 0


def agent(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    origins = {canonical_origin(value) for value in args.allow_origin}
    if not origins:
        raise ValueError("at least one --allow-origin is required")
    token = os.environ.get(args.token_env, "")
    state = AgentState(agent_id=args.agent_id, token=token, allow_origins=origins, root=root)
    host, port_text = args.listen.rsplit(":", 1)
    port = int(port_text)
    if host not in ("127.0.0.1", "::1", "localhost") and not (args.tls_cert and args.tls_key):
        raise ValueError("a non-loopback agent listener requires --tls-cert and --tls-key")
    server = AgentServer((host, port), state)
    if args.tls_cert or args.tls_key:
        if not (args.tls_cert and args.tls_key):
            raise ValueError("--tls-cert and --tls-key must be supplied together")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    scheme = "https" if args.tls_cert else "http"
    print(f"distributed-agent-ready protocol={PROTOCOL} agentId={state.agent_id} listen={scheme}://{args.listen}", flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="authenticated perflab distributed k6 agent/controller")
    commands = parser.add_subparsers(dest="command", required=True)
    agent_parser = commands.add_parser("agent")
    agent_parser.add_argument("--root", required=True)
    agent_parser.add_argument("--listen", required=True)
    agent_parser.add_argument("--agent-id", required=True)
    agent_parser.add_argument("--allow-origin", action="append", default=[])
    agent_parser.add_argument("--token-env", default="PERFLAB_DISTRIBUTED_TOKEN")
    agent_parser.add_argument("--tls-cert")
    agent_parser.add_argument("--tls-key")
    controller_parser = commands.add_parser("controller")
    controller_parser.add_argument("--agents", required=True)
    controller_parser.add_argument("--shards", required=True, type=int)
    controller_parser.add_argument("--target-origin", required=True)
    controller_parser.add_argument("--duration-seconds", required=True, type=int)
    controller_parser.add_argument("--connections", required=True, type=int)
    controller_parser.add_argument("--run-id", required=True)
    controller_parser.add_argument("--artifact-dir", required=True)
    controller_parser.add_argument("--controller-id", default="native-controller")
    controller_parser.add_argument("--max-clock-skew-ms", type=int, default=5_000)
    controller_parser.add_argument("--allow-partial", action="store_true")
    controller_parser.add_argument("--allow-insecure-local", action="store_true")
    controller_parser.add_argument("--token-env", default="PERFLAB_DISTRIBUTED_TOKEN")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        return agent(args) if args.command == "agent" else controller(args)
    except (ValueError, ProtocolError, RuntimeError) as exc:
        print(f"distributed-{args.command}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
