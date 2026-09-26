#!/usr/bin/env python3
"""On-CPU profiles from Speedscope JSON: one profile's hottest methods, or the
difference between two.

A differential run computes self-time per frame (function) in each profile,
normalises to a percent of on-CPU time (so profiles of different lengths are
comparable), and reports the frames whose share grew the most (regressions) and
shrank the most (improvements) -- the "which method got hotter" answer a CPU
regression needs. A report run ranks one profile's methods by self and
inclusive on-CPU time.

Invocations:
  diff-speedscope.py <baseline.speedscope.json> <candidate.speedscope.json> [--top N]
  diff-speedscope.py --stdin [--top N]     # reads {"baseline":<doc>,"candidate":<doc>}
  diff-speedscope.py --report <profile.speedscope.json> [--top N]

Handles both Speedscope profile encodings dotnet-trace can emit: "evented"
(open/close events -> self-time = time the frame sits on top of the stack) and
"sampled" (per-sample stacks + weights -> self-time = weight on the leaf frame).

dotnet-trace ends every stack in a pseudo-frame: CPU_TIME when the thread ran
managed code, whose time belongs to the frame beneath it, and UNMANAGED_CODE_TIME
(or BLOCKED_TIME, ...) otherwise -- including idle threads parked in native
waits, which are not CPU at all. Ranking the leaf as-is read S05 as 87%
UNMANAGED_CODE_TIME, 13% CPU_TIME and 0% for every method.
"""
import json
import re
import sys
from collections import defaultdict

PSEUDO = re.compile(r"^[A-Z][A-Z_]*_TIME$")
# dotnet-trace's grouping roots: process, activity and thread frames.
CONTAINER = re.compile(r"^(Process\d+ |Thread \(|Threads$|\(Non-Activities\)$|Activity )")


def weights(doc):
    """Return (self, inclusive, on_cpu_total, thread_total) weights per frame name."""
    names = [fr.get("name", "?") for fr in doc.get("shared", {}).get("frames", [])]
    by_stack = defaultdict(float)
    thread_total = 0.0

    def account(stack, weight):
        nonlocal thread_total
        if not stack or weight <= 0:
            return
        thread_total += weight
        leaf = names[stack[-1]] if 0 <= stack[-1] < len(names) else str(stack[-1])
        if PSEUDO.match(leaf):
            if leaf != "CPU_TIME" or len(stack) < 2:
                return
            stack = stack[:-1]
        by_stack[tuple(stack)] += weight

    for prof in doc.get("profiles", []):
        if prof.get("type") == "evented":
            stack = []
            last = prof.get("startValue", 0)
            for ev in prof.get("events", []):
                at = ev.get("at", last)
                account(stack, at - last)
                last = at
                if ev.get("type") == "O":
                    stack.append(ev.get("frame"))
                elif ev.get("type") == "C" and stack:
                    stack.pop()
        elif prof.get("type") == "sampled":
            samples = prof.get("samples", [])
            for stack, weight in zip(samples, prof.get("weights", [1] * len(samples))):
                account(list(stack), weight)

    def name(index):
        return names[index] if isinstance(index, int) and 0 <= index < len(names) else str(index)

    self_w, incl_w = defaultdict(float), defaultdict(float)
    for stack, weight in by_stack.items():
        self_w[name(stack[-1])] += weight
        for frame in {name(index) for index in stack}:
            incl_w[frame] += weight
    on_cpu = sum(by_stack.values())
    return self_w, incl_w, (on_cpu or 1.0), thread_total


def pct(d, total):
    return {k: 100.0 * v / total for k, v in d.items()}


def top_report(doc, top, label):
    self_w, incl_w, on_cpu, thread_total = weights(doc)
    print("# On-CPU profile (dotnet-trace CPU_TIME attributed to the frame beneath it)")
    print(f"#   source: {label}")
    share = 100.0 * on_cpu / thread_total if thread_total else 0.0
    print(f"#   on-CPU weight {on_cpu:.1f} of {thread_total:.1f} total thread time ({share:.1f}%)\n")
    for title, table in (("self", self_w), ("inclusive", incl_w)):
        print(f"Top {top} by {title} on-CPU time:")
        rows = sorted(((w, n) for n, w in table.items() if not CONTAINER.match(n)), reverse=True)[:top]
        if not rows:
            print("  (none)")
        for weight, frame in rows:
            print(f"  {100.0 * weight / on_cpu:6.2f}%   {frame[:110]}")
        print()


def report(base_doc, cand_doc, top, b_label, c_label):
    b_self, _, b_tot, _ = weights(base_doc)
    c_self, _, c_tot, _ = weights(cand_doc)
    b_pct, c_pct = pct(b_self, b_tot), pct(c_self, c_tot)
    rows = []
    for fr in set(b_pct) | set(c_pct):
        bp, cp = b_pct.get(fr, 0.0), c_pct.get(fr, 0.0)
        rows.append((cp - bp, bp, cp, fr))
    rows.sort(reverse=True)
    # Partition by direction so a frame never appears in BOTH lists (it would when
    # there are fewer than 2*top frames and the slices overlap).
    hotter = [r for r in rows if r[0] > 1e-9][:top]
    colder = sorted((r for r in rows if r[0] < -1e-9))[:top]  # most negative first

    def fmt(rs):
        if not rs:
            print("  (none)")
        for delta, bp, cp, fr in rs:
            print(f"  {delta:+7.2f}%   {bp:6.2f}% -> {cp:6.2f}%   {fr[:96]}")

    print("# Differential CPU profile (self-time % of on-CPU time)")
    print(f"#   baseline : {b_label}")
    print(f"#   candidate: {c_label}\n")
    print(f"Top {top} HOTTER in candidate (regressions):")
    fmt(hotter)
    print(f"\nTop {top} COLDER in candidate (improvements):")
    fmt(colder)


def main():
    argv = sys.argv[1:]
    top = 15
    files = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--top":
            # consume the numeric value so it is NOT mistaken for a positional file arg
            try:
                top = int(argv[i + 1])
            except (ValueError, IndexError):
                pass
            i += 2
            continue
        if a in ("--stdin", "--report"):
            i += 1
            continue
        if a.startswith("--"):
            i += 1
            continue
        files.append(a)
        i += 1
    if "--stdin" in argv:
        env = json.load(sys.stdin)
        report(env["baseline"], env["candidate"], top, "baseline", "candidate")
        return 0
    if "--report" in argv and len(files) == 1:
        with open(files[0], encoding="utf-8") as f:
            top_report(json.load(f), top, files[0])
        return 0
    if len(files) != 2:
        print("usage: diff-speedscope.py <baseline.json> <candidate.json> [--top N]  |  --stdin [--top N]  |  --report <profile.json> [--top N]", file=sys.stderr)
        return 2
    with open(files[0], encoding="utf-8") as f:
        base_doc = json.load(f)
    with open(files[1], encoding="utf-8") as f:
        cand_doc = json.load(f)
    report(base_doc, cand_doc, top, files[0], files[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
