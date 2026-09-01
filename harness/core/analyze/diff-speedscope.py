#!/usr/bin/env python3
"""Differential CPU profile between two Speedscope JSON files.

Computes self-time per frame (function) in each profile, normalises to a percent
of total (so profiles of different lengths are comparable), and reports the frames
whose share of CPU grew the most (regressions) and shrank the most (improvements).
This is the "which method got hotter" answer a CPU regression needs -- the step
that is otherwise a manual eyeball of two flamegraphs.

Two invocations:
  diff-speedscope.py <baseline.speedscope.json> <candidate.speedscope.json> [--top N]
  diff-speedscope.py --stdin [--top N]     # reads {"baseline":<doc>,"candidate":<doc>}
                                           # from stdin (how diff-profile.sh runs it
                                           # inside a python container, no host Python)

Handles both Speedscope profile encodings dotnet-trace can emit: "evented"
(open/close events -> self-time = time the frame sits on top of the stack) and
"sampled" (per-sample stacks + weights -> self-time = weight on the leaf frame).
"""
import json
import sys
from collections import defaultdict


def self_times(doc):
    """Return (dict frame_name -> self weight, total weight) for a Speedscope doc."""
    frames = [fr.get("name", "?") for fr in doc.get("shared", {}).get("frames", [])]
    self_w = defaultdict(float)
    total = 0.0
    for prof in doc.get("profiles", []):
        ptype = prof.get("type")
        if ptype == "evented":
            stack = []
            last = prof.get("startValue", 0)
            for ev in prof.get("events", []):
                at = ev.get("at", last)
                if stack:
                    self_w[stack[-1]] += max(0.0, at - last)
                last = at
                if ev.get("type") == "O":
                    stack.append(ev.get("frame"))
                elif ev.get("type") == "C" and stack:
                    stack.pop()
            total += max(0.0, prof.get("endValue", last) - prof.get("startValue", 0))
        elif ptype == "sampled":
            samples = prof.get("samples", [])
            weights = prof.get("weights", [1] * len(samples))
            for stk, w in zip(samples, weights):
                if stk:
                    self_w[stk[-1]] += w
                total += w
    named = defaultdict(float)
    for idx, w in self_w.items():
        name = frames[idx] if isinstance(idx, int) and 0 <= idx < len(frames) else str(idx)
        named[name] += w
    return named, (total or sum(named.values()) or 1.0)


def pct(d, total):
    return {k: 100.0 * v / total for k, v in d.items()}


def report(base_doc, cand_doc, top, b_label, c_label):
    b_self, b_tot = self_times(base_doc)
    c_self, c_tot = self_times(cand_doc)
    b_pct, c_pct = pct(b_self, b_tot), pct(c_self, c_tot)
    rows = []
    for fr in set(b_pct) | set(c_pct):
        bp, cp = b_pct.get(fr, 0.0), c_pct.get(fr, 0.0)
        rows.append((cp - bp, bp, cp, fr))
    rows.sort(reverse=True)

    def fmt(rs):
        for delta, bp, cp, fr in rs:
            print(f"  {delta:+7.2f}%   {bp:6.2f}% -> {cp:6.2f}%   {fr[:96]}")

    print("# Differential CPU profile (self-time % of total)")
    print(f"#   baseline : {b_label}")
    print(f"#   candidate: {c_label}\n")
    print(f"Top {top} HOTTER in candidate (regressions):")
    fmt(rows[:top])
    print(f"\nTop {top} COLDER in candidate (improvements):")
    fmt(list(reversed(rows[-top:])))


def main():
    argv = sys.argv[1:]
    top = 15
    if "--top" in argv:
        try:
            top = int(argv[argv.index("--top") + 1])
        except (ValueError, IndexError):
            pass
    files = [a for a in argv if not a.startswith("--")]
    if "--stdin" in argv:
        env = json.load(sys.stdin)
        report(env["baseline"], env["candidate"], top, "baseline", "candidate")
        return 0
    if len(files) != 2:
        print("usage: diff-speedscope.py <baseline.json> <candidate.json> [--top N]  |  --stdin [--top N]", file=sys.stderr)
        return 2
    with open(files[0], encoding="utf-8") as f:
        base_doc = json.load(f)
    with open(files[1], encoding="utf-8") as f:
        cand_doc = json.load(f)
    report(base_doc, cand_doc, top, files[0], files[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
