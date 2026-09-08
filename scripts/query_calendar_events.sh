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

attempt=1
while [ "$attempt" -le 3 ]; do
  if output="$("$SWIFT_QUERY" "$ARG" 2>&1)"; then
    if [ -n "$output" ]; then
      printf '%s\n' "$output"
      exit 0
    fi
  fi

  if printf '%s' "$output" | grep -qi "calendar access denied"; then
    /usr/bin/open -gj -a Calendar >/dev/null 2>&1 || true
  fi

  if [ "$attempt" -lt 3 ]; then
    sleep 2
  fi
  attempt=$((attempt + 1))
done

if [ -f "$APPLESCRIPT_QUERY" ]; then
  if output="$(/usr/bin/osascript "$APPLESCRIPT_QUERY" "$TARGET_DATE" 2>/dev/null)" && [ -n "$output" ]; then
    printf '%s\n' "$output"
    exit 0
  fi
fi

printf '%s\n' "$output" >&2
exit 1
