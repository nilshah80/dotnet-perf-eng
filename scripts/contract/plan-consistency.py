#!/usr/bin/env python3
"""Validate the plan against itself.

Two failures this catches, both of which shipped:

  * The acceptance-map summary is prose beside a table. Claiming "14 of 35"
    against 39 Gate A rows is a summary that disagrees with the thing it
    summarises -- the same defect as a green test that proves nothing.
  * The defect table (23.2.1) and the implementation-order table (23.5) each
    carry a status per item, and they disagreed: D-P0-1 Complete in one and
    Partial in the other. A reader cannot tell which is true, so neither is.

Run from the repository root.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

PLAN = Path("docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md")


def section(text: str, start: str, end: str) -> str:
    return text[text.index(start):text.index(end)]


def main() -> int:
    text = PLAN.read_text(encoding="utf-8")
    problems: list[str] = []

    # --- the acceptance map's own arithmetic --------------------------------
    acceptance = section(text, "### 23.2.2", "### 23.3")
    rows = [line for line in acceptance.splitlines() if re.match(r"^\| \d+ \|", line)]
    gate_a = [r for r in rows if r.split("|")[3].strip() == "A"]
    unmapped = [r for r in gate_a if "Unmapped" in r.split("|")[4]]
    mapped = len(gate_a) - len(unmapped)

    # "28 of 39 Gate A" and "all 39 Gate A" are both natural ways to state the
    # result; accept either rather than forcing the prose into one shape.
    claims = re.findall(r"(\d+) of (\d+) Gate A", text)
    claims += [(str(len(gate_a)), total) for total in re.findall(r"all (\d+) Gate A", text)]
    if not claims:
        problems.append("no 'N of M Gate A' or 'all N Gate A' claim found; the map has no stated result")
    for claimed_mapped, claimed_total in claims:
        if int(claimed_total) != len(gate_a):
            problems.append(
                f"claim says {claimed_total} Gate A cases, the table has {len(gate_a)}")
        if re.search(r"all \d+ Gate A", text) and unmapped:
            problems.append(
                f"the text claims all Gate A cases are mapped, but {len(unmapped)} are Unmapped")
        if int(claimed_mapped) not in (mapped, len(unmapped)):
            problems.append(
                f"claim says {claimed_mapped}, table has {mapped} mapped / {len(unmapped)} unmapped")

    # --- statuses must agree across the two tables ---------------------------
    defect_status: dict[str, str] = {}
    for line in section(text, "### 23.2.1", "### 23.2.2").splitlines():
        cells = [c.strip() for c in line.split("|")]
        if len(cells) > 3 and re.match(r"^(D-P0-\d+|C-\d+)$", cells[1]):
            defect_status[cells[1]] = cells[2].replace("*", "").strip()

    for line in section(text, "### 23.5", "### 23.6").splitlines():
        cells = [c.strip() for c in line.split("|")]
        if len(cells) < 6 or not cells[1].isdigit():
            continue
        step_status = cells[5]
        for item in (i.strip() for i in cells[3].split(",")):
            if item not in defect_status:
                continue
            defect = defect_status[item]
            # "Done" in the order table must not contradict 23.2.1. A step
            # covering several items is Done only if none of them is behind.
            if defect == "Complete" and step_status not in ("Done",):
                problems.append(f"{item} is Complete in 23.2.1 but step {cells[1]} says {step_status}")
            if defect in ("Partial", "Open") and step_status == "Done":
                problems.append(f"{item} is {defect} in 23.2.1 but step {cells[1]} says Done")

    # --- every mapped command must exist AND run in a contract suite ---------
    # Counting cells that do not say "Unmapped" measures the prose, not the
    # evidence. A mapping to a file that does not exist, or to a test nothing
    # executes, is indistinguishable from no mapping at all -- which is the
    # failure this whole section exists to prevent.
    native_check = Path("scripts/contract/check.sh").read_text(encoding="utf-8")
    perflab_root = Path("../perflab")
    perflab_checks = ""
    for relative in ("scripts/check.sh", "scripts/contract/check.sh"):
        candidate = perflab_root / relative
        if candidate.exists():
            perflab_checks += candidate.read_text(encoding="utf-8")

    for row in gate_a:
        case = row.split("|")[1].strip()
        cell = row.split("|")[4]
        if "Unmapped" in cell:
            continue
        for command in re.findall(r"`([^`]+)`", cell):
            command = command.strip()
            # A `go test ./pkg/ -run X` command: check the package path exists
            # and that some contract suite runs the package.
            if command.startswith("go test"):
                package = re.search(r"\./(\S+)", command)
                if package and not (perflab_root / package.group(1)).exists():
                    problems.append(f"case {case}: maps to a package that does not exist: {command}")
                elif "go test ./..." not in perflab_checks:
                    problems.append(f"case {case}: maps a go test, but no PerfLab check runs the suite")
                continue
            # Anything else is a script path, possibly with arguments. The path
            # is what must exist; the arguments are how it is invoked.
            script = command.split()[0]
            native_path, perflab_path = Path(script), perflab_root / script
            if native_path.exists():
                if script not in native_check:
                    problems.append(
                        f"case {case}: maps {script}, which exists but is not run by scripts/contract/check.sh")
            elif perflab_path.exists():
                if script not in perflab_checks:
                    problems.append(
                        f"case {case}: maps {script}, which exists but is not run by any PerfLab check")
            else:
                problems.append(f"case {case}: maps {script}, which does not exist in either repository")

    if problems:
        for problem in problems:
            print(f"plan-consistency: {problem}", file=sys.stderr)
        return 1
    print(f"plan self-consistent ({mapped} of {len(gate_a)} Gate A cases mapped, "
          f"every mapped command exists and runs, statuses agree)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
