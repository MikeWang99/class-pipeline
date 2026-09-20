#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_QUERY="$SCRIPT_DIR/query_calendar_events.swift"
APPLESCRIPT_QUERY="$SCRIPT_DIR/query_calendar_events_applescript.applescript"
ARG="${1:-1}"

if printf '%s' "$ARG" | grep -Eq '^-?[0-9]+$'; then
  if [ "$ARG" -ge 0 ]; then
    TARGET_DATE="$(/bin/date -j -v+${ARG}d '+%Y-%m-%d')"
  else
    TARGET_DATE="$(/bin/date -j -v${ARG}d '+%Y-%m-%d')"
  fi
else
  TARGET_DATE="$ARG"
fi

MAX_ATTEMPTS="${CALENDAR_QUERY_ATTEMPTS:-2}"
TIMEOUT_SECONDS="${CALENDAR_QUERY_TIMEOUT_SECONDS:-15}"

# EventKit can wait indefinitely when macOS is waiting for a permission
# decision. Bound each helper process so a failed calendar read cannot stall
# the watcher or every later post-class retry.
run_bounded() {
  /usr/bin/python3 - "$TIMEOUT_SECONDS" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
command = sys.argv[2:]
proc = subprocess.Popen(
    command,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    start_new_session=True,
)
try:
    stdout, stderr = proc.communicate(timeout=timeout)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGTERM)
    stdout, stderr = proc.communicate()
    print(f"calendar helper timed out after {timeout:g}s", file=sys.stderr)
    sys.exit(124)
sys.stdout.write(stdout)
sys.stderr.write(stderr)
sys.exit(proc.returncode)
PY
}

attempt=1
output=""
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  if output="$(run_bounded "$SWIFT_QUERY" "$ARG" 2>&1)"; then
    if [ -n "$output" ]; then
      printf '%s\n' "$output"
      exit 0
    fi
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    sleep 2
  fi
  attempt=$((attempt + 1))
done

if [ -f "$APPLESCRIPT_QUERY" ]; then
  if output="$(run_bounded /usr/bin/osascript "$APPLESCRIPT_QUERY" "$TARGET_DATE" 2>/dev/null)" && [ -n "$output" ]; then
    # Normalize AppleScript's legacy: calendar, title, start, notes
    # into the Swift v2.2 shape: title, start, end, event_id, notes.
    # This keeps preclass_scan.py and post-class matchers on one column contract.
    printf '%s\n' "$output" | /usr/bin/python3 -c '
import sys
for raw in sys.stdin:
    parts = raw.rstrip("\n").split("\t")
    if len(parts) >= 4:
        _calendar, title, start, notes = parts[0], parts[1], parts[2], "\t".join(parts[3:])
        print(f"{title}\t{start}\t\t\t{notes}")
'
    exit 0
  fi
fi

printf '%s\n' "$output" >&2
exit 1
