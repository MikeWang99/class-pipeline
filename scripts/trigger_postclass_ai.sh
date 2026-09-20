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
VAULT_PATH="$(cfg vault_path "$HOME/Obsidian Vault")"
LOG="$RECORD_DIR/logs/codex-postclass.log"
mkdir -p "$RECORD_DIR/logs"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

has_teacher_review() {
  local session_dir="$1" review_file
  [ -s "$session_dir/ai_completed.txt" ] || return 1
  review_file=$(sed -n 's/^teacher_review: //p' "$session_dir/ai_completed.txt" | head -1)
  [ -z "$review_file" ] && review_file=$(sed -n 's/^teaching_review: //p' "$session_dir/ai_completed.txt" | head -1)
  [ -n "$review_file" ] && [ -s "$review_file" ]
}

prepare_material_identity() {
  local session_dir="$1" material_file="$2" status calendar_status match system student rebuilt
  PREPARED_MATERIAL="$material_file"
  status=$(sed -n 's/^status: //p' "$material_file" | head -1)
  calendar_status=$(sed -n 's/^calendar_match_status: //p' "$material_file" | head -1)

  if [ "$status" = "待人工确认录音" ]; then
    log "AI trigger withheld; transcript/audio quality requires human confirmation (session=$session_dir)"
    return 3
  fi
  if [ "$status" != "待AI识别学生" ] && [ "$calendar_status" != "unmatched" ]; then
    return 0
  fi

  match=$("$SCRIPT_DIR/match_calendar_event.sh" "$session_dir" 2>/dev/null) || match=""
  case "$match" in
    *'|'*)
      system="${match%%|*}"
      student="${match##*|}"
      printf '%s\n' "$match" > "$session_dir/calendar_match.txt"
      rebuilt=$(bash "$SCRIPT_DIR/postclass_generate.sh" "$session_dir" "$VAULT_PATH" "$system" "$student" 2>> "$LOG") || {
        log "AI trigger withheld; matched material rebuild failed (session=$session_dir)"
        return 1
      }
      PREPARED_MATERIAL="$rebuilt"
      log "AI trigger identity resolved before Codex launch: $match (session=$session_dir)"
      return 0
      ;;
    *)
      log "AI trigger withheld; calendar identity is unresolved or ambiguous (session=$session_dir)"
      return 2
      ;;
  esac
}

cleanup_recording() {
  local session_dir="$1" file bytes failed=0 deleted_file marker_tmp
  local files=("$session_dir/audio.wav" "$session_dir/system_audio.caf" "$session_dir/microphone_audio.caf")
  marker_tmp="$session_dir/.audio_deleted.txt.tmp"
  : > "$marker_tmp"
  printf 'deleted_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" >> "$marker_tmp"
  printf 'reason: formal feedback, profile update, and teacher review completed\n' >> "$marker_tmp"
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

  prepare_material_identity "$session_dir" "$material_file"
  case "$?" in
    0) material_file="$PREPARED_MATERIAL" ;;
    2|3) return 0 ;;
    *) return 1 ;;
  esac

  if has_teacher_review "$session_dir"; then
    cleanup_recording "$session_dir" || true
    log "AI trigger skipped; session already complete including teacher review: $session_dir"
    return 0
  fi
  if [ -s "$session_dir/ai_completed.txt" ]; then
    log "AI trigger resuming; completion marker exists but teacher review is missing: $session_dir"
  fi
  if [ ! -x "$CODEX_BIN" ]; then
    log "AI trigger failed; Codex CLI not found: $CODEX_BIN"
    return 1
  fi

  prompt="Use the physics-class-pipeline Skill for exactly one post-class task. Fully read $SKILL_DIR/SKILL.md, $SKILL_DIR/docs/feedback-spec.md, and $SKILL_DIR/docs/teacher-review-spec.md. Session: $session_dir. Material: $material_file. Read the complete transcript, complete student profile, and most recent formal feedback. If the material is unmatched, retry $SKILL_DIR/scripts/match_calendar_event.sh using the session start time; never guess a student. If ai_completed.txt already contains valid formal_feedback and student_profile paths but lacks a valid teacher_review path, treat the parent feedback and profile as already complete and generate only the missing teacher review; do not rewrite the completed parent feedback or profile. Otherwise, once identified, correct the transcript front matter and filename, rebuild the material with postclass_generate.sh, then complete these steps in order: (1) generate the formal parent feedback under the Vault lesson feedback directory using the exact four headings 「1. 本节课内容」「2. 本节课进步」「3. 孩子当前待加强方向」「4. 后续计划」; Section 4 must contain 「课后练习安排」 and 「下节课安排」, and homework must never be invented; (2) update the student profile ledger; (3) only after those two are complete, generate the teacher-facing teaching optimization review required by docs/teacher-review-spec.md at $VAULT_PATH/上课记录/教学优化/ and update $VAULT_PATH/上课记录/教学优化/教学优化总览.md. The teacher review must analyze this lesson's teaching expression, repeated filler language, concept completeness, skipped reasoning, pacing, questioning, and actionable improvements only when supported by the transcript; do not turn transcription errors into teacher criticism. Write the teacher review path as teacher_review: ... in $session_dir/ai_completed.txt, set the material status to 已完成, and write the completion marker only after all three outputs are verified. Transcription is local-only and is not used for feedback generation. Do not edit pipeline source code, configuration, or unrelated files. If the session is already complete but teacher_review is missing, generate only the missing teacher review and then update the marker; otherwise make no changes."

  log "AI trigger started: session=$session_dir material=$material_file"
  "$CODEX_BIN" exec --ignore-user-config --ephemeral \
    --dangerously-bypass-approvals-and-sandbox \
    -C "$SKILL_DIR" "$prompt"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$session_dir/ai_completed.txt" ]; then
    # The marker is written by the AI, but the cleanup gate must independently
    # verify the two user-facing artifacts before removing the source audio.
    local feedback_file teacher_review_file material_status
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
    teacher_review_file=$(sed -n 's/^teacher_review: //p' "$session_dir/ai_completed.txt" | head -1)
    if [ -z "$teacher_review_file" ]; then
      teacher_review_file=$(sed -n 's/^teaching_review: //p' "$session_dir/ai_completed.txt" | head -1)
    fi
    if [ "$material_status" != "已完成" ] || [ -z "$feedback_file" ] || [ ! -s "$feedback_file" ] || [ -z "$teacher_review_file" ] || [ ! -s "$teacher_review_file" ]; then
      log "AI marker rejected; parent feedback/profile/teacher review completion evidence is incomplete (session=$session_dir material=$material_file)"
      return 1
    fi
    # Keep all source channels available while identity, transcript quality,
    # or AI generation is pending. Delete them only after the formal feedback
    # and profile update have been committed successfully.
    cleanup_recording "$session_dir" || true
    log "AI trigger completed: $session_dir (parent feedback + profile + teacher review)"
    osascript \
      -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' \
      -e 'end run' "Physics Class Pipeline" "课后反馈和教学优化已生成" >/dev/null 2>&1 || true
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
has_teacher_review "$SESSION_DIR" && {
  cleanup_recording "$SESSION_DIR" || true
  log "AI trigger skipped; already complete including teacher review: $SESSION_DIR"
  exit 0
}
if [ -s "$SESSION_DIR/ai_completed.txt" ]; then
  log "AI trigger resuming; completion marker exists but teacher review is missing: $SESSION_DIR"
fi

prepare_material_identity "$SESSION_DIR" "$MATERIAL_FILE"
case "$?" in
  0) MATERIAL_FILE="$PREPARED_MATERIAL" ;;
  2|3) exit 0 ;;
  *) exit 1 ;;
esac

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
