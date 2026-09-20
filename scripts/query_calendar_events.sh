#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_QUERY="$SCRIPT_DIR/query_calendar_events.swift"
APPLESCRIPT_QUERY="$SCRIPT_DIR/query_calendar_events_applescript.applescript"
ARG="${1:-1}"

if printf '%s' "$ARG" | grep -Eq '^-?[0-9]+$'; then
  if [ "$ARG" -ge 0 ]; then TARGET_DATE="$(/bin/date -j -v+${ARG}d '+%Y-%m-%d')"; else TARGET_DATE="$(/bin/date -j -v${ARG}d '+%Y-%m-%d')"; fi
else
  TARGET_DATE="$ARG"
fi
MAX_ATTEMPTS="${CALENDAR_QUERY_ATTEMPTS:-2}"
TIMEOUT_SECONDS="${CALENDAR_QUERY_TIMEOUT_SECONDS:-15}"

run_bounded() {
  /usr/bin/python3 - "$TIMEOUT_SECONDS" "$@" <<'PY'
import os, signal, subprocess, sys
timeout=float(sys.argv[1]); command=sys.argv[2:]
proc=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
try: stdout,stderr=proc.communicate(timeout=timeout)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid,signal.SIGTERM); stdout,stderr=proc.communicate(); print(f'calendar helper timed out after {timeout:g}s',file=sys.stderr); sys.exit(124)
sys.stdout.write(stdout); sys.stderr.write(stderr); sys.exit(proc.returncode)
PY
}

# Normalize every backend to: title<TAB>start<TAB>end<TAB>notes.
normalize_output() {
  /usr/bin/python3 -c '
import sys
from datetime import datetime

def is_dt(x):
    try: datetime.fromisoformat(x); return True
    except Exception: return False
for raw in sys.stdin:
    p=raw.rstrip("\n").split("\t")
    if len(p)<2: continue
    if len(p)>=3 and is_dt(p[1]):
        title,start=p[0].strip(),p[1].strip(); idx=2
    elif len(p)>=3 and is_dt(p[2]):
        title,start=p[1].strip(),p[2].strip(); idx=3
    else: continue
    end=""
    if len(p)>idx and is_dt(p[idx].strip()): end=p[idx].strip(); idx+=1
    notes=" ".join(x.strip() for x in p[idx:] if x.strip())
    print(f"{title}\t{start}\t{end}\t{notes}")
'
}

attempt=1; output=""
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  if output="$(run_bounded "$SWIFT_QUERY" "$ARG" 2>&1)"; then
    if [ -n "$output" ]; then printf '%s\n' "$output" | normalize_output; exit 0; fi
  fi
  [ "$attempt" -lt "$MAX_ATTEMPTS" ] && sleep 2
  attempt=$((attempt+1))
done

if [ -f "$APPLESCRIPT_QUERY" ]; then
  if output="$(run_bounded /usr/bin/osascript "$APPLESCRIPT_QUERY" "$TARGET_DATE" 2>/dev/null)" && [ -n "$output" ]; then
    printf '%s\n' "$output" | normalize_output; exit 0
  fi
fi
printf '%s\n' "$output" >&2; exit 1
