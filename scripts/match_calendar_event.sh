#!/usr/bin/env bash
# match_calendar_event.sh - safely match a session to one class event.
#
# Modes:
#   auto        transcript exists -> final, otherwise provisional
#   provisional before transcript: refuses to lock when multiple packed lessons are nearby
#   final       after transcript: uses the first meaningful transcript timestamp
#
# Output: SYSTEM|STUDENT
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

KEYWORD="${CALENDAR_KEYWORD:-Class}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUERY_SCRIPT="${CALENDAR_QUERY_SCRIPT:-$SCRIPT_DIR/query_calendar_events.sh}"
SELECTOR="$SCRIPT_DIR/select_calendar_event.py"
REFERENCE_DERIVER="$SCRIPT_DIR/derive_lesson_reference.py"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$SKILL_DIR/config.json"
PROVISIONAL_MAX_SECONDS="${CALENDAR_PROVISIONAL_MAX_SECONDS:-7200}"
FINAL_MAX_SECONDS="${CALENDAR_FINAL_MAX_SECONDS:-2700}"
FINAL_MIN_MARGIN_SECONDS="${CALENDAR_MATCH_MIN_MARGIN_SECONDS:-600}"

SESSION_ARG="${1:-}"
MODE="${2:-auto}"
if [ "$MODE" = "auto" ]; then
  if [ -n "$SESSION_ARG" ] && [ -s "$SESSION_ARG/transcript.txt" ]; then MODE="final"; else MODE="provisional"; fi
fi
case "$MODE" in provisional|final) ;; *) echo "invalid mode: $MODE" >&2; exit 2 ;; esac

REF_Y=""; REF_M=""; REF_D=""; REF_H=""; REF_MIN=""; REF_S=""
if [ -n "$SESSION_ARG" ] && [ -d "$SESSION_ARG" ]; then
  BASE="$(basename "$SESSION_ARG")"
  if printf '%s' "$BASE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'; then
    REF_Y="${BASE:0:4}"; REF_M="${BASE:5:2}"; REF_D="${BASE:8:2}"
    REF_H="${BASE:11:2}"; REF_MIN="${BASE:13:2}"; REF_S="${BASE:15:2}"
  fi
fi
if [ -z "$REF_Y" ]; then
  REF_Y="$(date '+%Y')"; REF_M="$(date '+%m')"; REF_D="$(date '+%d')"
  REF_H="$(date '+%H')"; REF_MIN="$(date '+%M')"; REF_S="$(date '+%S')"
fi
REF_DATE="${REF_Y}-${REF_M}-${REF_D}"
REF_ISO="${REF_DATE}T${REF_H}:${REF_MIN}:${REF_S}"
MAX_SECONDS="$PROVISIONAL_MAX_SECONDS"
if [ "$MODE" = "final" ]; then
  MAX_SECONDS="$FINAL_MAX_SECONDS"
  if [ -x "$REFERENCE_DERIVER" ] && [ -d "$SESSION_ARG" ]; then
    DERIVED="$(python3 "$REFERENCE_DERIVER" "$SESSION_ARG" 2>/dev/null || true)"
    [ -n "$DERIVED" ] && REF_ISO="$DERIVED"
  fi
fi

cfg() { python3 -c "import json;print(json.load(open('$CONFIG')).get('$1','$2'))" 2>/dev/null || echo "$2"; }
VAULT_PATH="$(cfg vault_path "$HOME/Obsidian Vault")"
RESOLVER="$SCRIPT_DIR/resolve_student_name.py"

pick_best_event() {
  python3 "$SELECTOR" "$KEYWORD" "$REF_ISO" "$MAX_SECONDS" "$MODE"
}

pick_from_prep_notes() {
  python3 - "$VAULT_PATH" "$REF_DATE" "$REF_ISO" "$MAX_SECONDS" "$FINAL_MIN_MARGIN_SECONDS" "$MODE" <<'PY'
import re, sys
from datetime import datetime
from pathlib import Path
vault=Path(sys.argv[1]).expanduser(); ref_date=sys.argv[2]
ref=datetime.fromisoformat(sys.argv[3]); max_delta=int(sys.argv[4]); min_margin=int(sys.argv[5]); mode=sys.argv[6]
if ref.tzinfo is None: ref=ref.replace(tzinfo=datetime.now().astimezone().tzinfo)
prep_dir=vault/"上课记录"/"备课内容"; candidates={}
for path in sorted(prep_dir.glob(f"{ref_date} *.md")):
    text=path.read_text(encoding="utf-8",errors="replace"); lines=text.splitlines(); fm={}
    if lines[:1]==["---"]:
        for line in lines[1:]:
            if line=="---": break
            if ":" in line:
                k,v=line.split(":",1); fm[k.strip()]=v.strip()
    event_start=fm.get("event_start"); system=fm.get("system"); student=fm.get("student")
    if not event_start or not student:
        m=re.match(rf"^{re.escape(ref_date)}\s+(.*?)\s+Class-(.+)\.md$",path.name)
        if m: system=system or m.group(1).strip(); student=student or m.group(2).strip()
    if not event_start or not student: continue
    try: start=datetime.fromisoformat(event_start)
    except ValueError: continue
    if start.tzinfo is None: start=start.replace(tzinfo=ref.tzinfo)
    delta=abs(int((start-ref).total_seconds()))
    if delta>max_delta: continue
    system=system or "未命名体系"; key=(system,student)
    if key not in candidates or delta<candidates[key][0]: candidates[key]=(delta,system,student)
ordered=sorted(candidates.values(),key=lambda x:x[0])
if not ordered: sys.exit(1)
if mode=="provisional" and len(ordered)>1: sys.exit(2)
if mode=="final" and len(ordered)>1 and ordered[1][0]-ordered[0][0]<min_margin: sys.exit(2)
print(f"{ordered[0][1]}|{ordered[0][2]}")
PY
}

MATCH=""
# Calendar is preferred. Prep notes remain a fallback when EventKit is briefly unavailable.
EVENTS="$("$QUERY_SCRIPT" "$REF_DATE" 2>/dev/null)" || EVENTS=""
if [ -n "$EVENTS" ]; then
  MATCH="$(printf '%s\n' "$EVENTS" | pick_best_event 2>/dev/null)" || MATCH=""
fi
if [ -z "$MATCH" ]; then MATCH="$(pick_from_prep_notes 2>/dev/null)" || MATCH=""; fi
[ -n "$MATCH" ] || exit 1
BEST_SYSTEM="${MATCH%%|*}"; BEST_STUDENT="${MATCH##*|}"
if [ -x "$RESOLVER" ]; then BEST_STUDENT="$(python3 "$RESOLVER" "$VAULT_PATH" "$BEST_STUDENT" 2>/dev/null || printf '%s' "$BEST_STUDENT")"; fi
printf '%s|%s\n' "$BEST_SYSTEM" "$BEST_STUDENT"
