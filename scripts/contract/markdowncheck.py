#!/usr/bin/env python3
"""Native Markdown validator. Rejects BOM, CRLF, trailing whitespace, prose
wider than 90 rendered columns, and inconsistent table column counts. Tables,
fenced code, and URL-only lines are length exceptions. Link destinations are
not counted; the rendered label is."""
from __future__ import annotations

import re
import sys
from pathlib import Path

LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
URL_ONLY = re.compile(r"^\s*https?://\S+$")


def table_columns(line: str) -> int:
    stripped = line.strip()
    if not stripped.startswith("|"):
        return 0
    cells = [part for part in stripped.strip("|").split("|")]
    return len(cells)


def check(path: Path) -> list[str]:
    errors: list[str] = []
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        return [f"{path}: BOM"]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return [f"{path}: invalid UTF-8"]
    if "\r" in text:
        return [f"{path}: CRLF"]
    fence = False
    table_width: int | None = None
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("```"):
            fence = not fence
            table_width = None
            continue
        if line.endswith(" ") or line.endswith("\t"):
            errors.append(f"{path}: line {number}: trailing whitespace")
            continue
        if line.startswith("|"):
            width = table_columns(line)
            if table_width is None:
                table_width = width
            elif width != table_width:
                errors.append(
                    f"{path}: line {number}: table column count {width} != {table_width}"
                )
            continue
        table_width = None
        if fence or URL_ONLY.match(line):
            continue
        rendered = LINK.sub(r"\1", line)
        if len(rendered) > 90:
            errors.append(
                f"{path}: line {number}: rendered prose is {len(rendered)} columns"
            )
    return errors


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: markdowncheck.py <files...>", file=sys.stderr)
        return 2
    failed = False
    for arg in sys.argv[1:]:
        for err in check(Path(arg)):
            print(err, file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
