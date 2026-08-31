#!/usr/bin/env bash
# dotnet runtime adapter -- version probe. stdout is appended to
# source/tool-versions.txt by capture-evidence.sh.
dotnet --info 2>&1 || true
