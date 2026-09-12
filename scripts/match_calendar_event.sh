#!/usr/bin/env bash
# match_calendar_event.sh - find the nearest Calendar event named "{SYSTEM} Class-{STUDENT}".
#
# Uses the same EventKit-backed query path as preclass_scan.py so prep scanning
# and post-class matching read from one data source.
#
# Output: "SYSTEM|STUDENT" on stdout.
# Exit 0 if found, 1 if not found.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

KEYWORD="${CALENDAR_KEYWORD:-Class}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUERY_SCRIPT="${CALENDAR_QUERY_SCRIPT:-$SCRIPT_DIR/query_calendar_events.sh}"
SELECTOR="$SCRIPT_DIR/select_calendar_event.py"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$SKILL_DIR/config.json"
MAX_DELTA_SECONDS="${CALENDAR_MATCH_MAX_SECONDS:-3600}"

SESSION_ARG="${1:-}"
REF_Y=""
REF_M=""
REF_D=""
REF_H=""
REF_MIN=""
REF_S=""

if [ -n "$SESSION_ARG" ] && [ -d "$SESSION_ARG" ]; then
  BASE="$(basename "$SESSION_ARG")"
  if printf '%s' "$BASE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'; then
    REF_Y="${BASE:0:4}"
    REF_M="${BASE:5:2}"
    REF_D="${BASE:8:2}"
    REF_H="${BASE:11:2}"
    REF_MIN="${BASE:13:2}"
    REF_S="${BASE:15:2}"
  fi
fi

if [ -z "$REF_Y" ]; then
  REF_Y="$(date '+%Y')"
  REF_M="$(date '+%m')"
  REF_D="$(date '+%d')"
  REF_H="$(date '+%H')"
  REF_MIN="$(date '+%M')"
  REF_S="$(date '+%S')"
fi

REF_DATE="${REF_Y}-${REF_M}-${REF_D}"
REF_ISO="${REF_DATE}T${REF_H}:${REF_MIN}:${REF_S}"

cfg() { python3 -c "import json;print(json.load(open('$CONFIG')).get('$1','$2'))" 2>/dev/null || echo "$2"; }
VAULT_PATH="$(cfg vault_path "$HOME/Obsidian Vault")"
RESOLVER="$SCRIPT_DIR/resolve_student_name.py"

pick_best_event() {
  python3 "$SELECTOR" "$KEYWORD" "$REF_ISO" "$MAX_DELTA_SECONDS"
}

pick_from_prep_notes() {
  python3 - "$VAULT_PATH" "$REF_DATE" "$REF_ISO" "$MAX_DELTA_SECONDS" <<'PY'
import re
import sys
from datetime import datetime
from pathlib import Path

vault = Path(sys.argv[1]).expanduser()
ref_date = sys.argv[2]
ref = datetime.fromisoformat(sys.argv[3]).replace(
    tzinfo=datetime.now().astimezone().tzinfo
)
max_delta = int(sys.argv[4])
prep_dir = vault / "上课记录" / "备课内容"
best = None

for path in sorted(prep_dir.glob(f"{ref_date} *.md")):
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    frontmatter = {}
    if lines[:1] == ["---"]:
        for line in lines[1:]:
            if line == "---":
                break
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            frontmatter[key.strip()] = value.strip()
    event_start = frontmatter.get("event_start")
    system = frontmatter.get("system")
    student = frontmatter.get("student")
    if not event_start or not student:
        match = re.match(rf"^{re.escape(ref_date)}\s+(.*?)\s+Class-(.+)\.md$", path.name)
        if match:
            system = system or match.group(1).strip()
            student = student or match.group(2).strip()
    if not event_start or not student:
        continue
    try:
        start = datetime.fromisoformat(event_start)
    except ValueError:
        continue
    delta = abs(int((start - ref).total_seconds()))
    if delta > max_delta:
        continue
    system = system or "未命名体系"
    if best is None or delta < best[0]:
        best = (delta, system, student)

if best is None:
    sys.exit(1)

print(f"{best[1]}|{best[2]}")
PY
}

MATCH=""
# The pre-class note stores the exact event_start captured during the daily
# scan. Prefer it when available so a temporary EventKit/launchd access issue
# cannot turn an otherwise known class into an unmatched session.
MATCH="$(pick_from_prep_notes 2>/dev/null)" || MATCH=""

if [ -z "$MATCH" ]; then
  EVENTS="$("$QUERY_SCRIPT" "$REF_DATE" 2>/dev/null)" || EVENTS=""
  if [ -n "$EVENTS" ]; then
    MATCH="$(printf '%s\n' "$EVENTS" | pick_best_event 2>/dev/null)" || MATCH=""
  fi
fi

[ -n "$MATCH" ] || exit 1
BEST_SYSTEM="${MATCH%%|*}"
BEST_STUDENT="${MATCH##*|}"

if [ -x "$RESOLVER" ]; then
  BEST_STUDENT="$(python3 "$RESOLVER" "$VAULT_PATH" "$BEST_STUDENT" 2>/dev/null || printf '%s' "$BEST_STUDENT")"
fi

printf '%s|%s\n' "$BEST_SYSTEM" "$BEST_STUDENT"
