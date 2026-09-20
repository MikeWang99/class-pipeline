#!/usr/bin/env bash
# postclass_generate.sh - build a post-class feedback draft after transcription
# Usage: postclass_generate.sh <session_dir> <vault_path>
# Exit 0: materials queued, 1: error
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ "$#" -lt 2 ]; then
  echo "Usage: postclass_generate.sh <session_dir> <vault_path> [system student]" >&2
  exit 1
fi

SESSION_DIR="$1"
VAULT_PATH="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIPT="$SESSION_DIR/transcript.txt"
[ -f "$TRANSCRIPT" ] || { echo "no transcript: $TRANSCRIPT"; exit 1; }
RESOLVER="$SCRIPT_DIR/resolve_student_name.py"

# Match student from the watcher-provided calendar event when available. Falling
# back keeps the script usable when run by hand.
MATCH_STATUS="matched"
if [ -n "${3:-}" ] && [ -n "${4:-}" ]; then
  SYSTEM="$3"
  STUDENT="$4"
else
  MATCH=$("$SCRIPT_DIR/match_calendar_event.sh" "$SESSION_DIR" 2>/dev/null) || MATCH=""
  if [ -n "$MATCH" ]; then
    SYSTEM="${MATCH%%|*}"
    STUDENT="${MATCH##*|}"
  else
    MATCH_STATUS="unmatched"
    SYSTEM="未匹配"
    STUDENT="Session-$(basename "$SESSION_DIR")"
  fi
fi
[ -z "$STUDENT" ] && { echo "empty student name"; exit 1; }

# 日历标题可能被污染（含无关文字），只取第一段并去掉首尾空白
STUDENT_CLEAN=$(printf '%s' "$STUDENT" | cut -d',' -f1 | xargs)
[ -z "$STUDENT_CLEAN" ] && STUDENT_CLEAN="$STUDENT"
if [ -x "$RESOLVER" ]; then
  STUDENT_CLEAN=$(python3 "$RESOLVER" "$VAULT_PATH" "$STUDENT_CLEAN" 2>/dev/null || printf '%s' "$STUDENT_CLEAN")
fi

# 在 Vault 学生档案里模糊匹配真实学生名（档案是台账，优先）
PROFILE=""
PROFILE_DIR="$VAULT_PATH/上课记录/学生档案"
if [ -d "$PROFILE_DIR" ]; then
  for f in "$PROFILE_DIR"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    base_lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
    clean_lower=$(printf '%s' "$STUDENT_CLEAN" | tr '[:upper:]' '[:lower:]')
    case "$clean_lower" in
      *"$base_lower"*|"$base_lower"*) STUDENT_CLEAN="$base"; PROFILE="$f"; break ;;
    esac
  done
  # 前缀匹配兜底：Julien -> Julian
  if [ -z "$PROFILE" ]; then
    for f in "$PROFILE_DIR"/*.md; do
      [ -f "$f" ] || continue
      base=$(basename "$f" .md)
      prefix=$(printf '%s' "$STUDENT_CLEAN" | cut -c1-4)
      case "$base" in
        "$prefix"*) STUDENT_CLEAN="$base"; PROFILE="$f"; break ;;
      esac
    done
  fi
fi
STUDENT="$STUDENT_CLEAN"

session_base="$(basename "$SESSION_DIR")"
if printf '%s' "$session_base" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'; then
  DATE="${session_base%%_*}"
else
  DATE="$(date '+%Y-%m-%d')"
fi

# 读取学生档案与最近一次反馈。正式 AI 阶段会通过 feedback_context.json
# 再读取完整来源；这里也不再截断档案，避免重要进度/问题落在 120 行之后。
PROFILE_TEXT=""
[ -n "$PROFILE" ] && PROFILE_TEXT=$(cat "$PROFILE")
PREV_FEEDBACK=""
PREV_FILE=$(find "$VAULT_PATH/上课记录/课后反馈" -maxdepth 1 -type f \
  -name "*-${STUDENT}-feedback.md" ! -name "${DATE}-${STUDENT}-feedback.md" \
  -print 2>/dev/null | LC_ALL=C sort -r | head -1)
[ -n "$PREV_FILE" ] && PREV_FEEDBACK=$(cat "$PREV_FILE")

CONTEXT_FILE="$SESSION_DIR/feedback_context.json"
if ! python3 "$SCRIPT_DIR/build_feedback_context.py"   "$SESSION_DIR" "$VAULT_PATH" "$SYSTEM" "$STUDENT" --output "$CONTEXT_FILE" >/dev/null 2>&1; then
  echo "failed to build feedback context: $CONTEXT_FILE" >&2
  exit 1
fi

MATERIAL_DIR="$VAULT_PATH/上课记录/课后反馈草稿"
mkdir -p "$MATERIAL_DIR"
OUTFILE="$MATERIAL_DIR/${DATE}-${STUDENT}-feedback-materials.md"

if [ "$MATCH_STATUS" = "matched" ]; then
  TRANSCRIPT_ARCHIVE="$VAULT_PATH/上课记录/课堂文字稿/${DATE} ${SYSTEM} Class-${STUDENT}.md"
  MATERIAL_STATUS="待AI生成"
else
  TRANSCRIPT_ARCHIVE="$VAULT_PATH/上课记录/课堂文字稿/${DATE} 未匹配 Class-Session-${session_base}.md"
  MATERIAL_STATUS="待AI识别学生"
fi
TRANSCRIPT_SNIPPET=$( { sed -n '1,100p' "$TRANSCRIPT"; printf '\n…（中段省略）…\n'; tail -n 60 "$TRANSCRIPT"; } )

# A non-empty transcript can still be unusable when Whisper only hears room
# noise or emits labels such as "multiple voices". Do not send that material
# to the writing model and do not let the cleanup step discard the only useful
# recovery source.
meaningful_line_count=$(sed -E 's/^\[[^]]+\][[:space:]]*//' "$TRANSCRIPT" \
  | grep -Eiv '^,?[[:space:]]*\(?doorbell rings\)?$|^,?[[:space:]]*\(?door opens\)?$|^\(?speaking in foreign language\)?$|^\(?multiple voices\)?$|^\[[[:space:]]*No Audible Dialogue[[:space:]]*\]$|^,$' \
  | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
TRANSCRIPT_QUALITY="usable"
if [ "${meaningful_line_count:-0}" -lt 3 ]; then
  TRANSCRIPT_QUALITY="unusable_for_lesson_feedback"
  MATERIAL_STATUS="待人工确认录音"
fi
if [ -f "$SESSION_DIR/recording_incomplete" ]; then
  TRANSCRIPT_QUALITY="recording_incomplete"
  MATERIAL_STATUS="待人工确认录音"
fi
if [ "$TRANSCRIPT_QUALITY" = "usable" ]; then
  if [ "$(python3 "$SCRIPT_DIR/check_transcript_quality.py" "$TRANSCRIPT" 2>/dev/null || true)" = "unusable" ]; then
    TRANSCRIPT_QUALITY="unusable_for_lesson_feedback"
    MATERIAL_STATUS="待人工确认录音"
  fi
fi

# Capture completeness and transcript quality are different facts.  A lesson
# with only one native source can still yield a useful recovery transcript, but
# it must never silently update the long-term student ledger or generate a
# confident parent report.
AUDIO_CAPTURE_STATUS="unknown"
AUDIO_CAPTURE_ACTION="unknown"
if [ -s "$SESSION_DIR/audio_health.json" ]; then
  AUDIO_CAPTURE_STATUS=$(python3 -c "import json; d=json.load(open('$SESSION_DIR/audio_health.json')); print(d.get('status','unknown'))" 2>/dev/null || echo unknown)
  AUDIO_CAPTURE_ACTION=$(python3 -c "import json; d=json.load(open('$SESSION_DIR/audio_health.json')); print(d.get('action','unknown'))" 2>/dev/null || echo unknown)
fi
case "$AUDIO_CAPTURE_STATUS" in
  system_audio_missing|microphone_audio_missing)
    TRANSCRIPT_QUALITY="audio_capture_degraded_${AUDIO_CAPTURE_STATUS}"
    MATERIAL_STATUS="待人工确认录音"
    ;;
  no_capturable_audio)
    TRANSCRIPT_QUALITY="audio_capture_failed"
    MATERIAL_STATUS="待人工确认录音"
    ;;
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
source_transcript: $TRANSCRIPT_ARCHIVE
source_profile: ${PROFILE:-（未匹配到学生档案）}
source_previous_feedback: ${PREV_FILE:-（无）}
source_feedback_context: $CONTEXT_FILE
source_calendar_candidates: $(if [ -s "$SESSION_DIR/calendar_candidates.json" ]; then printf '%s' "$SESSION_DIR/calendar_candidates.json"; else printf '（无）'; fi)
teacher_review_dir: $VAULT_PATH/上课记录/教学优化
generated_by: material-pipeline-only
---

# ${DATE} ${STUDENT} 课后反馈

## AI 生成要求
- 由装了该 Skill 的 AI 先完整读取 feedback_context.json 中所有存在的来源，再生成正式客户反馈
- 必须完整读取：本节课文字稿、当前学生档案；若存在，还必须读取上一次正式反馈、上一次课堂文字稿、当前备课和下一次备课
- 生成正式反馈前必须先写入 session/feedback_evidence.json；「孩子当前待加强方向」中的每一条都必须有本节课文字稿时间戳证据
- 历史问题如果本节课没有新的证据，只保留在学生档案内部，不得为了“连续性”反复写进家长反馈
- 下一节课安排必须结合当前档案进度 + 本节课证据；若已有下一次备课则一并读取，若没有则明确作为建议计划而非既定安排
- 本地 Whisper 仅负责转写，不参与备课或反馈正文写作
- 正式反馈需遵循本 Skill 的固定格式与措辞要求，尤其要直接写学生名字，避免泛泛写“学生”
- 如果 status 为“待AI识别学生”，先按 session 开始时间重新查询日历；日历暂时不可用时保留队列，不能跳过或猜学生
- 如果 status 为“待人工确认录音”，不得生成正式家长反馈、不得更新学生问题台账、不得删除原始音频
- 家长反馈、学生档案更新完成后，必须继续读取 docs/teacher-review-spec.md，生成给授课教师本人的教学优化复盘，写入“上课记录/教学优化/”；同时维护“教学优化总览.md”
- 只有正式家长反馈、学生档案更新和教学优化复盘都完成后，才将 status 改为“已完成”并写入 ai_completed.txt

## 学生档案摘要
${PROFILE_TEXT:-（未匹配到学生档案）}

## 上一次课后反馈参考
${PREV_FEEDBACK:-（无历史记录）}

## 强制上下文清单
以下 JSON 只用于告诉 AI 哪些完整来源必须读取；不能仅凭本素材中的摘录生成反馈。

```json
$(cat "$CONTEXT_FILE")
```

## 课堂文字稿摘录
${TRANSCRIPT_SNIPPET}

## 转写质量检查
$(if [ "$TRANSCRIPT_QUALITY" = "usable" ]; then
    echo "转写包含可用于课堂分析的有效内容，且双路采集完整。"
  elif printf '%s' "$TRANSCRIPT_QUALITY" | grep -q '^audio_capture_degraded_'; then
    echo "文字稿可用于人工恢复，但录音只捕获到一路音频（${AUDIO_CAPTURE_STATUS}）；暂不生成正式反馈或更新学生档案。"
  else
    echo "自动转写或录音完整性不足，暂不生成正式反馈；请先确认录音输入链路。"
  fi)

## 1. 本节课内容
> 待装有该 Skill 的 AI 根据完整课堂文字稿补全

## 2. 本节课进步
> 待装有该 Skill 的 AI 根据完整课堂文字稿补全

## 3. 孩子当前待加强方向
> 待装有该 Skill 的 AI 根据当前档案 + 本节课证据补全；没有本节课证据的历史问题不得重复搬入

## 4. 后续计划
> 待装有该 Skill 的 AI 根据完整课堂文字稿补全
EOF

echo "$OUTFILE"
