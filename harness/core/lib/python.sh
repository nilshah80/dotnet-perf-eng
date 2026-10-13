# shellcheck shell=sh
# perflab_python: print the host Python 3 that actually runs, or fail.
#
# Windows ships a python3.exe App Execution Alias that is not an interpreter: it
# prints a Microsoft Store advert and exits 49, so `command -v python3` succeeds
# while every call fails. Probe for a candidate that executes and is Python 3
# (a bare `python` can still be Python 2 on older hosts).
#
# POSIX sh on purpose: sourced by common.sh, by the sh contract scripts, and by
# standalone tests that must not source common.sh (it requires a selected lab).
perflab_python() {
  for _perflab_python_candidate in python3 python; do
    if command -v "$_perflab_python_candidate" >/dev/null 2>&1 &&
      "$_perflab_python_candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3,) else 1)' >/dev/null 2>&1; then
      printf '%s\n' "$_perflab_python_candidate"
      return 0
    fi
  done
  return 1
}
