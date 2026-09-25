# shellcheck shell=bash
# reset_inherited_sigint "$@": run the calling test script once more with SIGINT
# at its default disposition; in that re-executed copy the call returns at once.
#
# The signal tests prove Ctrl-C handling, so SIGINT has to reach what they start.
# A non-interactive shell that starts a test as a background job hands it SIGINT
# already ignored. Bash cannot undo that, nothing the test starts can trap it,
# and the INT cases then fail for a reason unrelated to the code under test.
# Bash 3.2 cannot reliably report an inherited ignore, so the reset always runs,
# once per script.
#
# Python does the reset, since the contract checks already need it. It restores
# SIGPIPE and SIGXFSZ as well, because Python ignores those for itself and an
# exec would hand the ignore on to the test. Windows has no exec: os.execv
# starts the new process and exits this one with 0 at once, detaching the test,
# so there Python waits for the test and returns its status instead. A native
# Python starting MSYS bash also clears the inherited ignore.

# shellcheck source=python.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/python.sh"

reset_inherited_sigint() {
  [[ "${SIGINT_RESET_SCRIPT:-}" != "$0" ]] || return 0
  local python
  python="$(perflab_python)" || { echo "a working Python 3 interpreter is required to reset SIGINT for $0" >&2; exit 1; }
  export SIGINT_RESET_SCRIPT="$0"
  exec "${python}" -c '
import os, signal, sys
for name in ("SIGINT", "SIGPIPE", "SIGXFSZ"):
    if hasattr(signal, name):
        signal.signal(getattr(signal, name), signal.SIG_DFL)
if os.name == "nt":
    import subprocess
    program = sys.argv[1]
    if not program.lower().endswith(".exe") and os.path.isfile(program + ".exe"):
        program += ".exe"
    sys.exit(subprocess.call([program] + sys.argv[2:]))
os.execv(sys.argv[1], sys.argv[1:])
' "${BASH}" "$0" "$@"
}
