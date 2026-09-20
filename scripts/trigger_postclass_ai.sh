#!/bin/bash
# Trigger one Codex run when post-class material is ready.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SKILL_DIR="$(dirname "$SCRIPT_DIR")"; CONFIG="$SKILL_DIR/config.json"
CODEX_BIN="${CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex}"
cfg(){ python3 -c "import json;print(json.load(open('$CONFIG')).get('$1','$2'))" 2>/dev/null || echo "$2"; }
RECORD_DIR="$(cfg recordings_dir "$HOME/physics-class-pipeline-data")"; VAULT_PATH="$(cfg vault_path "$HOME/Obsidian Vault")"
LOG="$RECORD_DIR/logs/codex-postclass.log"; mkdir -p "$RECORD_DIR/logs"
log(){ printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
marker_path(){ local marker="$1" key="$2"; sed -n "s/^${key}: //p" "$marker" 2>/dev/null | head -1; }
material_field(){ local file="$1" key="$2"; sed -n "s/^${key}: //p" "$file" 2>/dev/null | head -1; }
hash_file(){ [ -s "$1" ] && shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || true; }

has_complete_outputs(){
  local session_dir="$1"
  local marker="$session_dir/ai_completed.txt" feedback profile review context
  [ -s "$marker" ] || return 1
  feedback=$(marker_path "$marker" formal_feedback); [ -z "$feedback" ] && feedback=$(marker_path "$marker" feedback)
  profile=$(marker_path "$marker" student_profile)
  review=$(marker_path "$marker" teacher_review); [ -z "$review" ] && review=$(marker_path "$marker" teaching_review)
  context=$(marker_path "$marker" postclass_context); [ -z "$context" ] && context="$session_dir/postclass-context.json"
  [ -s "$feedback" ] && [ -s "$profile" ] && [ -s "$review" ] && [ -s "$context" ] || return 1
  python3 "$SCRIPT_DIR/validate_postclass_context.py" "$context" >/dev/null 2>&1 || return 1
  python3 "$SCRIPT_DIR/validate_feedback_output.py" "$feedback" >/dev/null 2>&1 || return 1
  return 0
}

prepare_material_identity(){
  local session_dir="$1" material_file="$2" status calendar_status match system student rebuilt
  PREPARED_MATERIAL="$material_file"
  status=$(material_field "$material_file" status); calendar_status=$(material_field "$material_file" calendar_match_status)
  if [ "$status" = "待人工确认录音" ]; then log "AI trigger withheld; transcript/audio quality requires human confirmation (session=$session_dir)"; return 3; fi
  if [ "$status" != "待AI识别学生" ] && { [ "$calendar_status" = "matched_final" ] || [ "$calendar_status" = "confirmed_manual" ]; }; then return 0; fi

  match=$("$SCRIPT_DIR/match_calendar_event.sh" "$session_dir" final 2>/dev/null) || match=""
  case "$match" in
    *'|'*)
      system="${match%%|*}"; student="${match##*|}"
      printf '%s\n' "$match" > "$session_dir/calendar_match_final.txt"
      rebuilt=$(POSTCLASS_IDENTITY_CONFIRMED=1 bash "$SCRIPT_DIR/postclass_generate.sh" "$session_dir" "$VAULT_PATH" "$system" "$student" 2>>"$LOG") || {
        log "AI trigger withheld; final matched material rebuild failed (session=$session_dir)"; return 1; }
      PREPARED_MATERIAL="$rebuilt"; log "final transcript-aware identity resolved before AI: $match (session=$session_dir)"; return 0 ;;
    *) log "AI trigger withheld; final calendar identity unresolved or ambiguous (session=$session_dir)"; return 2 ;;
  esac
}

cleanup_recording(){
  local session_dir="$1" file bytes failed=0 marker_tmp
  local files=("$session_dir/audio.wav" "$session_dir/system_audio.caf" "$session_dir/microphone_audio.caf")
  marker_tmp="$session_dir/.audio_deleted.txt.tmp"; : > "$marker_tmp"
  printf 'deleted_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" >> "$marker_tmp"
  printf 'reason: context, formal feedback, profile update, and teacher review validated\n' >> "$marker_tmp"
  for file in "${files[@]}"; do
    [ -e "$file" ] || continue; bytes=$(stat -f%z "$file" 2>/dev/null || echo 0)
    if rm -f "$file"; then printf 'deleted_file: %s\nbytes: %s\n' "$file" "$bytes" >> "$marker_tmp"; log "deleted source after validated completion (session=$session_dir file=$file)"; else failed=1; fi
  done
  if [ "$failed" -eq 0 ]; then mv -f "$marker_tmp" "$session_dir/audio_deleted.txt"; return 0; fi
  rm -f "$marker_tmp"; return 1
}

worker(){
  local session_dir="$1" material_file="$2"
  local lock_file="$session_dir/.ai_trigger.pid" prompt rc
  local profile_before_path profile_before_hash profile_after_path profile_after_hash expected_student
  trap "unlink '$lock_file' 2>/dev/null || true" EXIT
  prepare_material_identity "$session_dir" "$material_file"; case "$?" in 0) material_file="$PREPARED_MATERIAL" ;; 2|3) return 0 ;; *) return 1 ;; esac

  if has_complete_outputs "$session_dir"; then cleanup_recording "$session_dir" || true; log "AI trigger skipped; session already fully validated: $session_dir"; return 0; fi
  if [ ! -x "$CODEX_BIN" ]; then log "AI trigger failed; Codex CLI not found: $CODEX_BIN"; return 1; fi

  expected_student=$(material_field "$material_file" student)
  profile_before_path=$(material_field "$material_file" source_profile)
  case "$profile_before_path" in ""|（*) profile_before_path="" ;; esac
  profile_before_hash=""; [ -n "$profile_before_path" ] && profile_before_hash=$(hash_file "$profile_before_path")

  prompt="Use the physics-class-pipeline Skill for exactly one post-class task. Fully read $SKILL_DIR/SKILL.md, $SKILL_DIR/docs/postclass-context-spec.md, $SKILL_DIR/docs/feedback-spec.md, and $SKILL_DIR/docs/teacher-review-spec.md. Session: $session_dir. Material: $material_file. Identity must be the transcript-aware final identity in the material; never reuse a provisional calendar match as proof. FIRST read the complete raw transcript, complete current student profile, most recent formal feedback, previous transcript and current prep when those source paths exist. Before writing parent feedback, create $session_dir/postclass-context.json exactly according to docs/postclass-context-spec.md and run $SKILL_DIR/scripts/validate_postclass_context.py on it with expected student $expected_student. The context must explicitly capture current progress, previous lesson carry-over, this lesson's actual content, evidence-backed successes/difficulties, issue status changes, and a concrete next-lesson plan. CURRENT LESSON EVIDENCE outranks historical profile wording. A historical issue with no evidence in this lesson stays in the profile but must not be repeated in 「3. 孩子当前待加强方向」. Only issues marked include_in_parent_feedback=true with this_lesson_evidence may appear there. THEN (1) generate formal parent feedback with exact headings 「1. 本节课内容」「2. 本节课进步」「3. 孩子当前待加强方向」「4. 后续计划」; Section 4 must contain 课后练习安排： and 下节课安排：; do not invent homework; remove the final Chinese/English period from each paragraph or bullet while keeping normal punctuation inside the paragraph; (2) update the student profile ledger using this lesson context, including current progress, issue status changes and next-lesson carry-over; (3) generate the teacher review and update 教学优化总览.md. If the transcript archive was created under a provisional wrong student, rename/correct its front matter to target_transcript_archive from the material. Run scripts/validate_feedback_output.py on the formal feedback. Write $session_dir/ai_completed.txt only after all outputs exist, with four paths: formal_feedback, student_profile, teacher_review, postclass_context. Set material status to 已完成 only after all four are complete. Do not edit pipeline source code or configuration."

  log "AI trigger started: session=$session_dir material=$material_file"
  "$CODEX_BIN" exec --ignore-user-config --ephemeral --dangerously-bypass-approvals-and-sandbox -C "$SKILL_DIR" "$prompt"; rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$session_dir/ai_completed.txt" ]; then
    local marker="$session_dir/ai_completed.txt" feedback_file teacher_review_file context_file material_status
    material_status=$(material_field "$material_file" status)
    feedback_file=$(marker_path "$marker" formal_feedback); [ -z "$feedback_file" ] && feedback_file=$(marker_path "$marker" feedback)
    profile_after_path=$(marker_path "$marker" student_profile)
    teacher_review_file=$(marker_path "$marker" teacher_review); [ -z "$teacher_review_file" ] && teacher_review_file=$(marker_path "$marker" teaching_review)
    context_file=$(marker_path "$marker" postclass_context); [ -z "$context_file" ] && context_file="$session_dir/postclass-context.json"
    if [ "$material_status" != "已完成" ] || [ ! -s "$feedback_file" ] || [ ! -s "$profile_after_path" ] || [ ! -s "$teacher_review_file" ] || [ ! -s "$context_file" ]; then
      log "AI marker rejected; one or more required artifacts are missing (session=$session_dir)"; return 1
    fi
    python3 "$SCRIPT_DIR/validate_postclass_context.py" "$context_file" --expected-student "$expected_student" >>"$LOG" 2>&1 || { log "AI context rejected (session=$session_dir)"; return 1; }
    python3 "$SCRIPT_DIR/validate_feedback_output.py" "$feedback_file" >>"$LOG" 2>&1 || { log "formal feedback style/structure rejected (session=$session_dir)"; return 1; }
    profile_after_hash=$(hash_file "$profile_after_path")
    if [ -n "$profile_before_path" ] && [ "$profile_after_path" = "$profile_before_path" ] && [ -n "$profile_before_hash" ] && [ "$profile_after_hash" = "$profile_before_hash" ]; then
      log "AI marker rejected; student profile was not actually updated (session=$session_dir profile=$profile_after_path)"; return 1
    fi
    cleanup_recording "$session_dir" || true
    log "AI trigger completed: $session_dir (context + parent feedback + profile update + teacher review)"
    osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' -e 'end run' "Physics Class Pipeline" "课后反馈、学生档案和教学优化已生成" >/dev/null 2>&1 || true
    return 0
  fi
  log "AI trigger incomplete: session=$session_dir codex_rc=$rc; fallback will retry"; return 1
}

if [ "${1:-}" = "--worker" ]; then [ "$#" -eq 3 ] || exit 2; worker "$2" "$3"; exit $?; fi
if [ "$#" -ne 2 ]; then echo "Usage: trigger_postclass_ai.sh <session_dir> <material_file>" >&2; exit 2; fi
SESSION_DIR="$1"; MATERIAL_FILE="$2"; LOCK_FILE="$SESSION_DIR/.ai_trigger.pid"
[ -d "$SESSION_DIR" ] || { log "AI trigger rejected; no session: $SESSION_DIR"; exit 1; }
[ -f "$MATERIAL_FILE" ] || { log "AI trigger rejected; no material: $MATERIAL_FILE"; exit 1; }
if has_complete_outputs "$SESSION_DIR"; then cleanup_recording "$SESSION_DIR" || true; log "AI trigger skipped; already fully validated: $SESSION_DIR"; exit 0; fi
prepare_material_identity "$SESSION_DIR" "$MATERIAL_FILE"; case "$?" in 0) MATERIAL_FILE="$PREPARED_MATERIAL" ;; 2|3) exit 0 ;; *) exit 1 ;; esac
if [ -f "$LOCK_FILE" ]; then existing_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"; if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then log "AI trigger skipped; worker already running: session=$SESSION_DIR pid=$existing_pid"; exit 0; fi; rm -f "$LOCK_FILE"; fi
if [ "${TRIGGER_POSTCLASS_AI_DRY_RUN:-0}" = "1" ]; then printf 'would trigger Codex: session=%s material=%s\n' "$SESSION_DIR" "$MATERIAL_FILE"; exit 0; fi
nohup "$0" --worker "$SESSION_DIR" "$MATERIAL_FILE" >> "$LOG" 2>&1 </dev/null &
worker_pid=$!; printf '%s\n' "$worker_pid" > "$LOCK_FILE"; log "AI worker launched: session=$SESSION_DIR pid=$worker_pid"
