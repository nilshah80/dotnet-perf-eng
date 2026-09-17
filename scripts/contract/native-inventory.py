#!/usr/bin/env python3
"""Generate or verify the native shell environment compatibility inventory."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


ENVIRONMENT_NAME = re.compile(r"\b(?:PERFLAB|PERF)_[A-Z][A-Z0-9_]*[A-Z0-9]\b")
TEXT_SUFFIXES = {
    ".cs",
    ".jmx",
    ".js",
    ".json",
    ".lua",
    ".ps1",
    ".sh",
    ".yaml",
    ".yml",
}


def source_files(root: Path):
    for relative in ("harness", "labs", "source/dotnet"):
        for path in (root / relative).rglob("*"):
            if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
                continue
            parts = path.relative_to(root).parts
            if "vendor" in parts or "testdata" in parts or "inventories" in parts:
                continue
            if path.name.endswith("-test.sh"):
                continue
            yield path


def discovered_names(root: Path) -> list[str]:
    names: set[str] = set()
    for path in source_files(root):
        names.update(ENVIRONMENT_NAME.findall(path.read_text(encoding="utf-8")))
    return sorted(name for name in names if not name.startswith("PERFLAB_TEST_"))


def encoded_inventory(root: Path) -> bytes:
    path = root / "harness/inventories/compatibility-inventory.json"
    inventory = json.loads(path.read_text(encoding="utf-8"))
    inventory["environmentNames"] = discovered_names(root)
    return (json.dumps(inventory, indent=2, ensure_ascii=False) + "\n").encode()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("root", nargs="?", default=".")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    path = root / "harness/inventories/compatibility-inventory.json"
    expected = encoded_inventory(root)
    if args.check:
        if path.read_bytes() != expected:
            raise SystemExit(f"{path.relative_to(root)} is dirty")
        print(f"native interface inventory ok ({len(discovered_names(root))} environment names)")
        return 0
    path.write_bytes(expected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
