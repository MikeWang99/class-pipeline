#!/bin/bash
# Trigger one Codex run when a post-class material file becomes available.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$SKILL_DIR/config.json"
CODEX_BIN="${CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex}"

cfg() {
  python3 -c "import json;print(json.load(open('$CONFIG')).get('$1','$2'))" 2>/dev/null || echo "$2"
}

RECORD_DIR="$(cfg recordings_dir "$HOME/physics-class-pipeline-data")"
LOG="$RECORD_DIR/logs/codex-postclass.log"
mkdir -p "$RECORD_DIR/logs"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

cleanup_recording() {
  local session_dir="$1" file bytes failed=0 deleted_file marker_tmp
  local files=("$session_dir/audio.wav" "$session_dir/system_audio.caf" "$session_dir/microphone_audio.caf")
  marker_tmp="$session_dir/.audio_deleted.txt.tmp"
  : > "$marker_tmp"
  printf 'deleted_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" >> "$marker_tmp"
  printf 'reason: formal feedback and profile update completed\n' >> "$marker_tmp"
  for file in "${files[@]}"; do
    [ -e "$file" ] || continue
    bytes=$(stat -f%z "$file" 2>/dev/null || echo 0)
    if rm -f "$file"; then
      printf 'deleted_file: %s\n' "$file" >> "$marker_tmp"
      printf 'bytes: %s\n' "$bytes" >> "$marker_tmp"
      log "deleted recording source after AI completion (session=$session_dir, file=$file, bytes=$bytes)"
    else
      failed=1
      log "WARNING: failed to delete recording source after AI completion (session=$session_dir, file=$file)"
    fi
  done
  if [ "$failed" -eq 0 ]; then
    mv -f "$marker_tmp" "$session_dir/audio_deleted.txt"
    return 0
  fi
  rm -f "$marker_tmp"
  return 1
}

worker() {
  local session_dir="$1" material_file="$2"
  local lock_file="$session_dir/.ai_trigger.pid"
  local prompt rc
  # EXIT traps run after this function returns, so a function-local variable is
  # unset under `set -u`. Capture the path when installing the trap.
  trap "unlink '$lock_file' 2>/dev/null || true" EXIT

  if [ -s "$session_dir/ai_completed.txt" ]; then
    cleanup_recording "$session_dir" || true
    log "AI trigger skipped; session already complete: $session_dir"
    return 0
  fi
  if [ ! -x "$CODEX_BIN" ]; then
    log "AI trigger failed; Codex CLI not found: $CODEX_BIN"
    return 1
  fi

  prompt="Use the physics-class-pipeline Skill for exactly one post-class task. Fully read $SKILL_DIR/SKILL.md and $SKILL_DIR/docs/feedback-spec.md. Session: $session_dir. Material: $material_file. Read the complete transcript, complete student profile, and most recent formal feedback. If the material is unmatched, retry $SKILL_DIR/scripts/match_calendar_event.sh using the session start time; never guess a student. Once identified, correct the transcript front matter and filename, rebuild the material with postclass_generate.sh, then generate the formal feedback under the Vault lesson feedback directory, update the student profile ledger, set the material status to 已完成, and write $session_dir/ai_completed.txt. The feedback must use the exact four headings 「1. 本节课内容」「2. 本节课进步」「3. 孩子当前待加强方向」「4. 后续计划」. Section 4 must contain the two subheadings 「课后练习安排」 and 「下节课安排」; include homework only when explicitly present in the source, and never invent it. Transcription is local-only and is not used for feedback generation. Do not edit pipeline source code, configuration, or unrelated files. If the session is already complete, make no changes."

  log "AI trigger started: session=$session_dir material=$material_file"
  "$CODEX_BIN" exec --ignore-user-config --ephemeral \
    --dangerously-bypass-approvals-and-sandbox \
    -C "$SKILL_DIR" "$prompt"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$session_dir/ai_completed.txt" ]; then
    # The marker is written by the AI, but the cleanup gate must independently
    # verify the two user-facing artifacts before removing the source audio.
    local feedback_file material_status
    material_status=$(sed -n 's/^status: //p' "$material_file" | head -1)
    feedback_file=$(sed -n 's/^formal_feedback: //p' "$material_file" | head -1)
    # `formal_feedback` is optional material metadata. The completion marker
    # is authoritative because the AI writes it after saving the feedback.
    if [ -z "$feedback_file" ]; then
      feedback_file=$(sed -n 's/^formal_feedback: //p' "$session_dir/ai_completed.txt" | head -1)
    fi
    if [ -z "$feedback_file" ]; then
      feedback_file=$(sed -n 's/^feedback: //p' "$session_dir/ai_completed.txt" | head -1)
    fi
    if [ "$material_status" != "已完成" ] || [ -z "$feedback_file" ] || [ ! -s "$feedback_file" ]; then
      log "AI marker rejected; feedback/profile completion evidence is incomplete (session=$session_dir material=$material_file)"
      return 1
    fi
    # Keep all source channels available while identity, transcript quality,
    # or AI generation is pending. Delete them only after the formal feedback
    # and profile update have been committed successfully.
    cleanup_recording "$session_dir" || true
    log "AI trigger completed: $session_dir"
    osascript \
      -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' \
      -e 'end run' "Physics Class Pipeline" "正式课后反馈已生成" >/dev/null 2>&1 || true
    return 0
  fi

  log "AI trigger incomplete: session=$session_dir codex_rc=$rc; daily fallback will retry"
  return 1
}

if [ "${1:-}" = "--worker" ]; then
  [ "$#" -eq 3 ] || exit 2
  worker "$2" "$3"
  exit $?
fi

if [ "$#" -ne 2 ]; then
  echo "Usage: trigger_postclass_ai.sh <session_dir> <material_file>" >&2
  exit 2
fi

SESSION_DIR="$1"
MATERIAL_FILE="$2"
LOCK_FILE="$SESSION_DIR/.ai_trigger.pid"

[ -d "$SESSION_DIR" ] || { log "AI trigger rejected; no session: $SESSION_DIR"; exit 1; }
[ -f "$MATERIAL_FILE" ] || { log "AI trigger rejected; no material: $MATERIAL_FILE"; exit 1; }
[ -s "$SESSION_DIR/ai_completed.txt" ] && {
  cleanup_recording "$SESSION_DIR" || true
  log "AI trigger skipped; already complete: $SESSION_DIR"
  exit 0
}

if [ -f "$LOCK_FILE" ]; then
  existing_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    log "AI trigger skipped; worker already running: session=$SESSION_DIR pid=$existing_pid"
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi

if [ "${TRIGGER_POSTCLASS_AI_DRY_RUN:-0}" = "1" ]; then
  printf 'would trigger Codex: session=%s material=%s\n' "$SESSION_DIR" "$MATERIAL_FILE"
  exit 0
fi

nohup "$0" --worker "$SESSION_DIR" "$MATERIAL_FILE" >> "$LOG" 2>&1 </dev/null &
worker_pid=$!
printf '%s\n' "$worker_pid" > "$LOCK_FILE"
log "AI worker launched: session=$SESSION_DIR pid=$worker_pid"
