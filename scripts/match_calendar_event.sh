#!/usr/bin/env bash
# Resolve one recorded session to a calendar class.
#
# Identity is deliberately NOT finalized before a transcript exists. Opening a
# meeting window near a scheduled class is not proof that class actually happened.
# After transcription, select_calendar_event.py compares the meaningful transcript
# interval with calendar event intervals. Ambiguous sessions remain unmatched and
# are queued for AI/human reconciliation instead of updating the wrong student.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

KEYWORD="${CALENDAR_KEYWORD:-Class}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUERY_SCRIPT="${CALENDAR_QUERY_SCRIPT:-$SCRIPT_DIR/query_calendar_events.sh}"
SELECTOR="$SCRIPT_DIR/select_calendar_event.py"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$SKILL_DIR/config.json"
MAX_DELTA_SECONDS="${CALENDAR_MATCH_MAX_SECONDS:-5400}"
AMBIGUITY_MARGIN_SECONDS="${CALENDAR_MATCH_AMBIGUITY_SECONDS:-300}"

SESSION_ARG="${1:-}"
[ -n "$SESSION_ARG" ] && [ -d "$SESSION_ARG" ] || exit 1
BASE="$(basename "$SESSION_ARG")"
if ! printf '%s' "$BASE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'; then
  exit 1
fi
REF_DATE="${BASE%%_*}"

cfg() { python3 -c "import json;print(json.load(open('$CONFIG')).get('$1','$2'))" 2>/dev/null || echo "$2"; }
VAULT_PATH="$(cfg vault_path "$HOME/Obsidian Vault")"
RESOLVER="$SCRIPT_DIR/resolve_student_name.py"
SNAPSHOT="$SESSION_ARG/calendar_events.tsv"

# Capture a raw calendar snapshot whenever possible, but do not bind identity yet.
# Once a transcript exists, refresh the snapshot one more time so calendar edits made
# during the lesson can be reflected. If the refresh fails, keep the earlier snapshot.
if [ ! -s "$SNAPSHOT" ] || [ -s "$SESSION_ARG/transcript.txt" ]; then
  EVENTS="$("$QUERY_SCRIPT" "$REF_DATE" 2>/dev/null)" || EVENTS=""
  [ -n "$EVENTS" ] && printf '%s\n' "$EVENTS" > "$SNAPSHOT"
fi

# Pre-transcript calls come from meeting_watcher during recording. They are allowed
# to snapshot metadata only; they must never create a final student match.
[ -s "$SESSION_ARG/transcript.txt" ] || {
  [ -s "$SNAPSHOT" ] && python3 "$SELECTOR" "$KEYWORD" "$SESSION_ARG" "$MAX_DELTA_SECONDS" "$AMBIGUITY_MARGIN_SECONDS" < "$SNAPSHOT" >/dev/null 2>&1 || true
  exit 1
}

run_selector() {
  python3 "$SELECTOR" "$KEYWORD" "$SESSION_ARG" "$MAX_DELTA_SECONDS" "$AMBIGUITY_MARGIN_SECONDS"
}

MATCH=""
RC=1
if [ -s "$SNAPSHOT" ]; then
  MATCH="$(run_selector < "$SNAPSHOT" 2>/dev/null)" && RC=0 || RC=$?
  if [ "$RC" -eq 3 ]; then
    exit 1
  fi
fi

# If live/snapshotted calendar data is unavailable, reconstruct candidate rows from
# pre-class notes. New notes include event_end; legacy notes with only event_start
# remain usable as a conservative nearest-start fallback.
if [ -z "$MATCH" ]; then
  PREP_ROWS="$(python3 - "$VAULT_PATH" "$REF_DATE" <<'PY'
import re, sys
from pathlib import Path
vault=Path(sys.argv[1]).expanduser(); day=sys.argv[2]
prep=vault/'上课记录'/'备课内容'
for path in sorted(prep.glob(f'{day} *.md')):
    text=path.read_text(encoding='utf-8',errors='replace')
    fm={}
    lines=text.splitlines()
    if lines[:1]==['---']:
        for line in lines[1:]:
            if line=='---': break
            if ':' in line:
                k,v=line.split(':',1); fm[k.strip()]=v.strip()
    start=fm.get('event_start'); end=fm.get('event_end','')
    system=fm.get('system'); student=fm.get('student')
    if not system or not student:
        m=re.match(r'^\d{4}-\d{2}-\d{2}\s+(.*?)\s+Class-(.+)\.md$',path.name,re.I)
        if m:
            system=system or m.group(1).strip(); student=student or m.group(2).strip()
    if start and system and student:
        title=f'{system} Class-{student}'
        if end:
            print(f'{title}\t{start}\t{end}\tprep-note')
        else:
            print(f'{title}\t{start}\tprep-note')
PY
)"
  if [ -n "$PREP_ROWS" ]; then
    MATCH="$(printf '%s\n' "$PREP_ROWS" | run_selector 2>/dev/null)" && RC=0 || RC=$?
    [ "$RC" -eq 3 ] && exit 1
  fi
fi

[ -n "$MATCH" ] || exit 1
BEST_SYSTEM="${MATCH%%|*}"
BEST_STUDENT="${MATCH##*|}"
if [ -x "$RESOLVER" ]; then
  BEST_STUDENT="$(python3 "$RESOLVER" "$VAULT_PATH" "$BEST_STUDENT" 2>/dev/null || printf '%s' "$BEST_STUDENT")"
fi
printf '%s|%s\n' "$BEST_SYSTEM" "$BEST_STUDENT"
