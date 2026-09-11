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

# 读取学生档案与最近一次反馈（保持问题跟踪连续性）
PROFILE_TEXT=""
[ -n "$PROFILE" ] && PROFILE_TEXT=$(sed -n '1,120p' "$PROFILE")
PREV_FEEDBACK=""
PREV_FILE=$(find "$VAULT_PATH/上课记录/课后反馈" -maxdepth 1 -type f \
  -name "*-${STUDENT}-feedback.md" ! -name "${DATE}-${STUDENT}-feedback.md" \
  -print 2>/dev/null | LC_ALL=C sort -r | head -1)
[ -n "$PREV_FILE" ] && PREV_FEEDBACK=$(sed -n '1,100p' "$PREV_FILE")
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

cat > "$OUTFILE" <<EOF
---
date: $DATE
student: $STUDENT
system: $SYSTEM
status: $MATERIAL_STATUS
calendar_match_status: $MATCH_STATUS
transcript_quality: $TRANSCRIPT_QUALITY
source_transcript: $TRANSCRIPT_ARCHIVE
source_profile: ${PROFILE:-（未匹配到学生档案）}
source_previous_feedback: ${PREV_FILE:-（无）}
generated_by: material-pipeline-only
---

# ${DATE} ${STUDENT} 课后反馈

## AI 生成要求
- 由装了该 Skill 的 AI 基于课堂文字稿、学生档案和最近一次反馈生成正式客户反馈
- 本地 Whisper 仅负责转写，不参与备课或反馈正文写作
- 正式反馈需遵循本 Skill 的固定格式与措辞要求，尤其要直接写学生名字，避免泛泛写“学生”
- 如果 status 为“待AI识别学生”，先按 session 开始时间重新查询日历；日历暂时不可用时保留队列，不能跳过或猜学生

## 学生档案摘要
${PROFILE_TEXT:-（未匹配到学生档案）}

## 上一次课后反馈参考
${PREV_FEEDBACK:-（无历史记录）}

## 课堂文字稿摘录
${TRANSCRIPT_SNIPPET}

## 转写质量检查
$(if [ "$TRANSCRIPT_QUALITY" = "usable" ]; then echo "转写包含可用于课堂分析的有效内容。"; else echo "自动转写主要由环境声或无法辨认的占位标签组成，暂不生成正式反馈；请先确认录音输入链路。"; fi)

## 1. 本节课内容
> 待装有该 Skill 的 AI 根据完整课堂文字稿补全

## 2. 本节课进步
> 待装有该 Skill 的 AI 根据完整课堂文字稿补全

## 3. 当前待解决问题
> 待装有该 Skill 的 AI 根据完整课堂文字稿补全

## 4. 下一步计划
> 待装有该 Skill 的 AI 根据完整课堂文字稿补全
EOF

echo "$OUTFILE"
