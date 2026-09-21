#!/usr/bin/env bash
# postclass_generate.sh - build source-grounded post-class materials.
# Usage: postclass_generate.sh <session_dir> <vault_path> [system student]
# Automatic callers must not treat [system student] as final identity unless
# POSTCLASS_IDENTITY_CONFIRMED=1 is explicitly set.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ "$#" -lt 2 ]; then echo "Usage: postclass_generate.sh <session_dir> <vault_path> [system student]" >&2; exit 1; fi
SESSION_DIR="$1"; VAULT_PATH="$2"; SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIPT="$SESSION_DIR/transcript.txt"; [ -f "$TRANSCRIPT" ] || { echo "no transcript: $TRANSCRIPT"; exit 1; }
RESOLVER="$SCRIPT_DIR/resolve_student_name.py"

# Final identity is transcript-aware. The watcher may have made a provisional
# match before meaningful dialogue began; that provisional identity is audit
# context only and is never enough to generate parent feedback.
MATCH_STATUS="unmatched"; SYSTEM="未匹配"; STUDENT="Session-$(basename "$SESSION_DIR")"
FINAL_MATCH=$("$SCRIPT_DIR/match_calendar_event.sh" "$SESSION_DIR" final 2>/dev/null) || FINAL_MATCH=""
if [ -n "$FINAL_MATCH" ]; then
  SYSTEM="${FINAL_MATCH%%|*}"; STUDENT="${FINAL_MATCH##*|}"; MATCH_STATUS="matched_final"
  printf '%s\n' "$FINAL_MATCH" > "$SESSION_DIR/calendar_match_final.txt"
elif [ "${POSTCLASS_IDENTITY_CONFIRMED:-0}" = "1" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ]; then
  SYSTEM="$3"; STUDENT="$4"; MATCH_STATUS="confirmed_manual"
else
  : # keep unmatched even if provisional arguments were supplied by the watcher
fi
[ -z "$STUDENT" ] && { echo "empty student name"; exit 1; }

STUDENT_CLEAN=$(printf '%s' "$STUDENT" | cut -d',' -f1 | xargs)
[ -z "$STUDENT_CLEAN" ] && STUDENT_CLEAN="$STUDENT"
if [ -x "$RESOLVER" ] && [ "$MATCH_STATUS" != "unmatched" ]; then
  STUDENT_CLEAN=$(python3 "$RESOLVER" "$VAULT_PATH" "$STUDENT_CLEAN" 2>/dev/null || printf '%s' "$STUDENT_CLEAN")
fi

PROFILE=""; PROFILE_DIR="$VAULT_PATH/上课记录/学生档案"
if [ "$MATCH_STATUS" != "unmatched" ] && [ -d "$PROFILE_DIR" ]; then
  for f in "$PROFILE_DIR"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md); base_lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]'); clean_lower=$(printf '%s' "$STUDENT_CLEAN" | tr '[:upper:]' '[:lower:]')
    case "$clean_lower" in *"$base_lower"*|"$base_lower"*) STUDENT_CLEAN="$base"; PROFILE="$f"; break ;; esac
  done
  if [ -z "$PROFILE" ]; then
    for f in "$PROFILE_DIR"/*.md; do
      [ -f "$f" ] || continue
      base=$(basename "$f" .md); prefix=$(printf '%s' "$STUDENT_CLEAN" | cut -c1-4)
      case "$base" in "$prefix"*) STUDENT_CLEAN="$base"; PROFILE="$f"; break ;; esac
    done
  fi
fi
STUDENT="$STUDENT_CLEAN"

session_base="$(basename "$SESSION_DIR")"
if printf '%s' "$session_base" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'; then DATE="${session_base%%_*}"; else DATE="$(date '+%Y-%m-%d')"; fi

PROFILE_TEXT=""; [ -n "$PROFILE" ] && PROFILE_TEXT=$(cat "$PROFILE")
PREV_FILE=""; PREV_FEEDBACK=""; PREV_TRANSCRIPT=""; CURRENT_PREP=""
if [ "$MATCH_STATUS" != "unmatched" ]; then
  PREV_FILE=$(find "$VAULT_PATH/上课记录/课后反馈" -maxdepth 1 -type f -name "*-${STUDENT}-feedback.md" ! -name "${DATE}-${STUDENT}-feedback.md" -print 2>/dev/null | LC_ALL=C sort -r | head -1)
  [ -n "$PREV_FILE" ] && PREV_FEEDBACK=$(cat "$PREV_FILE")
  PREV_TRANSCRIPT=$(find "$VAULT_PATH/上课记录/课堂文字稿" -maxdepth 1 -type f -name "* Class-${STUDENT}.md" ! -name "${DATE} * Class-${STUDENT}.md" -print 2>/dev/null | LC_ALL=C sort -r | head -1)
  CURRENT_PREP=$(find "$VAULT_PATH/上课记录/备课内容" -maxdepth 1 -type f -name "${DATE} * Class-${STUDENT}.md" -print 2>/dev/null | LC_ALL=C sort | head -1)
fi

MATERIAL_DIR="$VAULT_PATH/上课记录/课后反馈草稿"; mkdir -p "$MATERIAL_DIR"
OUTFILE="$MATERIAL_DIR/${DATE}-${STUDENT}-feedback-materials.md"
if [ "$MATCH_STATUS" = "matched_final" ] || [ "$MATCH_STATUS" = "confirmed_manual" ]; then
  TARGET_TRANSCRIPT_ARCHIVE="$VAULT_PATH/上课记录/课堂文字稿/${DATE} ${SYSTEM} Class-${STUDENT}.md"; MATERIAL_STATUS="待AI生成"
else
  TARGET_TRANSCRIPT_ARCHIVE="$VAULT_PATH/上课记录/课堂文字稿/${DATE} 未匹配 Class-Session-${session_base}.md"; MATERIAL_STATUS="待AI识别学生"
fi
ACTUAL_TRANSCRIPT_ARCHIVE=$(grep -lF "transcript_source: $TRANSCRIPT" "$VAULT_PATH/上课记录/课堂文字稿"/*.md 2>/dev/null | head -1 || true)
TRANSCRIPT_SNIPPET=$( { sed -n '1,100p' "$TRANSCRIPT"; printf '\n…（中段省略；正式生成必须读取完整 raw transcript）…\n'; tail -n 60 "$TRANSCRIPT"; } )

meaningful_line_count=$(sed -E 's/^\[[^]]+\][[:space:]]*//' "$TRANSCRIPT" | grep -Eiv '^,?[[:space:]]*\(?doorbell rings\)?$|^,?[[:space:]]*\(?door opens\)?$|^\(?speaking in foreign language\)?$|^\(?multiple voices\)?$|^\[[[:space:]]*No Audible Dialogue[[:space:]]*\]$|^,$' | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
TRANSCRIPT_QUALITY="usable"
if [ "${meaningful_line_count:-0}" -lt 3 ]; then TRANSCRIPT_QUALITY="unusable_for_lesson_feedback"; MATERIAL_STATUS="待人工确认录音"; fi
if [ -f "$SESSION_DIR/recording_incomplete" ]; then TRANSCRIPT_QUALITY="recording_incomplete"; MATERIAL_STATUS="待人工确认录音"; fi
if [ "$TRANSCRIPT_QUALITY" = "usable" ] && [ "$(python3 "$SCRIPT_DIR/check_transcript_quality.py" "$TRANSCRIPT" 2>/dev/null || true)" = "unusable" ]; then TRANSCRIPT_QUALITY="unusable_for_lesson_feedback"; MATERIAL_STATUS="待人工确认录音"; fi

AUDIO_CAPTURE_STATUS="unknown"; AUDIO_CAPTURE_ACTION="unknown"
if [ -s "$SESSION_DIR/audio_health.json" ]; then
  AUDIO_CAPTURE_STATUS=$(python3 -c "import json; d=json.load(open('$SESSION_DIR/audio_health.json')); print(d.get('status','unknown'))" 2>/dev/null || echo unknown)
  AUDIO_CAPTURE_ACTION=$(python3 -c "import json; d=json.load(open('$SESSION_DIR/audio_health.json')); print(d.get('action','unknown'))" 2>/dev/null || echo unknown)
fi
case "$AUDIO_CAPTURE_STATUS" in
  system_audio_missing|microphone_audio_missing) TRANSCRIPT_QUALITY="audio_capture_degraded_${AUDIO_CAPTURE_STATUS}"; MATERIAL_STATUS="待人工确认录音" ;;
  no_capturable_audio) TRANSCRIPT_QUALITY="audio_capture_failed"; MATERIAL_STATUS="待人工确认录音" ;;
esac

cat > "$OUTFILE" <<EOF
---
date: $DATE
student: $STUDENT
system: $SYSTEM
status: $MATERIAL_STATUS
calendar_match_status: $MATCH_STATUS
transcript_quality: $TRANSCRIPT_QUALITY
audio_capture_status: $AUDIO_CAPTURE_STATUS
audio_capture_action: $AUDIO_CAPTURE_ACTION
source_transcript: $TRANSCRIPT
source_transcript_raw: $TRANSCRIPT
source_transcript_archive_actual: ${ACTUAL_TRANSCRIPT_ARCHIVE:-（无）}
target_transcript_archive: $TARGET_TRANSCRIPT_ARCHIVE
source_profile: ${PROFILE:-（未匹配到学生档案）}
source_previous_feedback: ${PREV_FILE:-（无）}
source_previous_transcript: ${PREV_TRANSCRIPT:-（无）}
source_current_prep: ${CURRENT_PREP:-（无）}
postclass_context: $SESSION_DIR/postclass-context.json
teacher_review_dir: $VAULT_PATH/上课记录/教学优化
generated_by: material-pipeline-only
---

# ${DATE} ${STUDENT} 课后反馈素材

## AI 生成要求
- 正式反馈前必须完整读取 source_transcript_raw、当前完整学生档案、最近一次正式反馈；存在 source_previous_transcript / source_current_prep 时也要读取
- 第一产物不是反馈正文，而是依据 docs/postclass-context-spec.md 生成 $SESSION_DIR/postclass-context.json，并通过 scripts/validate_postclass_context.py
- 「孩子当前待加强方向」只允许写 postclass-context.json 中 include_in_parent_feedback=true 且有本节课 evidence 的问题；历史问题本节未观察到时留在档案继续跟踪，不要机械重复进家长反馈
- 当前学生档案用于 longitudinal context，但本节课完整文字稿是本节进步/问题判断的最高优先级证据
- feedback 完成后同步更新学生档案，记录本次进度、问题状态变化、下一课承接
- 如果 status 为“待AI识别学生”，先做 transcript-aware final calendar match；身份不唯一时保留队列，绝不能猜学生
- 如果 status 为“待人工确认录音”，不得生成正式家长反馈、不得更新学生问题台账、不得删除原始音频
- 反馈遵循 docs/feedback-spec.md；段落和 bullet 最末尾不要加中文句号或英文句点，句内标点正常使用
- 家长反馈与档案更新后继续按 docs/teacher-review-spec.md 生成教师复盘
- 只有 context、正式反馈、学生档案更新、教师复盘全部通过验证后，才改为“已完成”并写 ai_completed.txt

## 当前学生档案（完整）
${PROFILE_TEXT:-（未匹配到学生档案）}

## 上一次正式课后反馈（完整）
${PREV_FEEDBACK:-（无历史记录）}

## 课堂文字稿摘录（仅供快速浏览；正式分析必须读取完整 source_transcript_raw）
${TRANSCRIPT_SNIPPET}

## 转写质量检查
$(if [ "$TRANSCRIPT_QUALITY" = "usable" ]; then echo "转写包含可用于课堂分析的有效内容，且双路采集完整"; elif printf '%s' "$TRANSCRIPT_QUALITY" | grep -q '^audio_capture_degraded_'; then echo "文字稿可用于人工恢复，但录音只捕获到一路音频（${AUDIO_CAPTURE_STATUS}）；暂不生成正式反馈或更新学生档案"; else echo "自动转写或录音完整性不足，暂不生成正式反馈；请先确认录音输入链路"; fi)

## 1. 本节课内容
> 待 AI 根据 postclass-context.json 补全

## 2. 本节课进步
> 待 AI 根据 postclass-context.json 补全

## 3. 当前待解决问题
> 只能来自本节课 evidence-backed issue assessment

## 4. 下一步计划
> 结合当前进度、本节实际完成内容与 issue assessment 生成
EOF

echo "$OUTFILE"
