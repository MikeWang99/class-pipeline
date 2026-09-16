#!/bin/bash
# meeting_watcher.sh — resident meeting detector + auto recorder + auto transcriber.
#
# Loops every 15s. When a meeting app is detected it starts recording
# the macOS system-audio and microphone streams. When the meeting has been gone for 3 consecutive
# checks (~45s) it stops recording, transcribes via local Whisper Turbo, prepares
# transcript/feedback draft materials, and posts a macOS notification.
#
# Usage:
#   bash meeting_watcher.sh          # daemon loop (used by launchd)
#   bash meeting_watcher.sh once     # record one session manually (Ctrl-C to stop)
#   bash meeting_watcher.sh notify-test  # show the lifecycle notification test
set -u

# launchd / .app contexts have a minimal PATH; add common Homebrew locations
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$SKILL_DIR/config.json"
INTERVAL=15
MISS_LIMIT=3   # 3 x 15s without meeting => class over
RESOLVER="$SCRIPT_DIR/resolve_student_name.py"

cfg() { python3 -c "import json,os;print(json.load(open('$CONFIG')).get('$1','$2'))" 2>/dev/null || echo "$2"; }

if [ ! -f "$CONFIG" ]; then
  echo "config.json missing — run setup.sh first" >&2
  exit 1
fi
RECORD_DIR="$(cfg recordings_dir "$HOME/physics-class-pipeline-data")"
VAULT_PATH="$(cfg vault_path "$HOME/Obsidian Vault")"
RECORD_DIR="${RECORD_DIR/#\~/$HOME}"
WHISPER_MODEL_CFG="$(cfg whisper_model "")"
if [ -n "$WHISPER_MODEL_CFG" ]; then
  export WHISPER_MODEL="${WHISPER_MODEL_CFG/#\~/$HOME}"
fi
export TRANSCRIBE_LANGUAGE="$(cfg transcribe_language "auto")"
RECORDING_BACKEND="$(cfg recording_backend "native_system_and_microphone")"
NATIVE_CAPTURE_APP="$HOME/Applications/PhysicsClassAudio.app/Contents/MacOS/PhysicsClassAudio"
LOG_DIR="$RECORD_DIR/logs"
mkdir -p "$RECORD_DIR/sessions" "$LOG_DIR"
LOG="$LOG_DIR/watcher.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() {
  local key="$1" body="$2"
  local title="Physics Class Pipeline"
  log "NOTIFY requested: $key"
  (
    # AppleScript notifications can be silently suppressed without returning
    # an error. Keep the banner, and always show a short dialog for the two
    # lifecycle events the teacher must see.
    osascript \
      -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' \
      -e 'end run' "$title" "$body" >/dev/null 2>&1 || true
    if [ "$key" = "recording" ] || [ "$key" = "transcribing" ]; then
      if osascript \
        -e 'on run argv' \
        -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"知道了"} default button 1 giving up after 8' \
        -e 'end run' "$title" "$body" >/dev/null 2>&1; then
        log "NOTIFY dialog displayed: $key"
      else
        log "NOTIFY dialog failed: $key"
      fi
    else
      log "NOTIFY banner requested: $key"
    fi
  ) &
}

# ---------- meeting detection ----------
meeting_running() {
  # native apps (process name match)
  if pgrep -qi "zoom\.us" || pgrep -qi "wemeetapp" || pgrep -qi "xmeet" \
     || pgrep -qi "DingTalk" || pgrep -qi "Lark" || pgrep -qi "Feishu" \
     || pgrep -qi "TencentMeeting"; then
    echo "native-app"
    return 0
  fi
  # Google Meet in Chrome / Safari (tab URL match)
  local urls=""
  urls=$(osascript -e 'tell application "System Events"
    set out to ""
    if (name of processes) contains "Google Chrome" then
      tell application "Google Chrome"
        repeat with w in windows
          repeat with t in tabs of w
            set out to out & (URL of t) & linefeed
          end repeat
        end repeat
      end tell
    end if
    return out
  end tell' 2>/dev/null)
  if echo "$urls" | grep -q "meet.google.com"; then
    echo "google-meet"
    return 0
  fi
  urls=$(osascript -e 'tell application "System Events"
    if (name of processes) contains "Safari" then
      tell application "Safari"
        set out to ""
        repeat with w in windows
          repeat with t in tabs of w
            set out to out & (URL of t) & linefeed
          end repeat
        end repeat
        return out
      end tell
    end if
    return ""
  end tell' 2>/dev/null)
  if echo "$urls" | grep -q "meet.google.com"; then
    echo "google-meet"
    return 0
  fi
  return 1
}

# ---------- recording ----------
SESSION=""
FFPID=""
SYSTEM_AUDIO_FILE=""
MICROPHONE_AUDIO_FILE=""
NATIVE_STATUS_FILE=""
NOTIFY_STAMP=""
MATCH_RETRY_STAMP=0

lock_course_match() {
  local dir="$1"
  local match=""
  [ -d "$dir" ] || return 1
  [ -s "$dir/calendar_match.txt" ] && return 0
  match=$("$SCRIPT_DIR/match_calendar_event.sh" "$dir" 2>/dev/null) || match=""
  case "$match" in
    *'|'*)
      printf '%s\n' "$match" > "$dir/calendar_match.txt"
      log "course match locked (session=$dir, match=$match)"
      return 0
      ;;
  esac
  log "course match not available (session=$dir)"
  return 1
}

retry_course_match() {
  local now
  [ -n "$SESSION" ] || return 0
  [ -s "$SESSION/calendar_match.txt" ] && return 0
  now=$(date +%s)
  [ $((now - MATCH_RETRY_STAMP)) -lt 60 ] && return 0
  MATCH_RETRY_STAMP=$now
  lock_course_match "$SESSION" || true
}

# avoid notification spam: at most one no-input notification per 10 minutes
notify_throttled() {
  local now=$(date +%s)
  if [ -n "$NOTIFY_STAMP" ] && [ $((now - NOTIFY_STAMP)) -lt 600 ]; then return; fi
  NOTIFY_STAMP=$now
  notify "$1" "$2"
}

session_date() {
  local dir="$1"
  local base
  base="$(basename "$dir")"
  if printf '%s' "$base" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'; then
    printf '%s\n' "${base%%_*}"
  else
    date '+%Y-%m-%d'
  fi
}

archive_transcript() {
  local dir="$1"
  local system="$2"
  local student="$3"
  local matched="$4"
  local session_day duration archive_dir archive_file fallback_student

  session_day="$(session_date "$dir")"
  archive_dir="$VAULT_PATH/上课记录/课堂文字稿"
  mkdir -p "$archive_dir"

  if [ "$matched" = "yes" ]; then
    archive_file="$archive_dir/${session_day} ${system} Class-${student}.md"
  else
    fallback_student="Session-$(basename "$dir")"
    archive_file="$archive_dir/${session_day} 未匹配 Class-${fallback_student}.md"
    student="$fallback_student"
    system="未匹配"
  fi

  duration=$(python3 -c "import subprocess; print(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1','$dir/audio.wav'],text=True).strip())" 2>/dev/null || echo "?")
  {
    echo "---"
    echo "date: $session_day"
    echo "student: $student"
    echo "system: $system"
    echo "duration: ${duration}s"
    echo "calendar_matched: $matched"
    echo "transcript_source: $dir/transcript.txt"
    echo "audio_source_original: $dir/audio.wav"
    echo "audio_retention_policy: delete_after_formal_feedback"
    [ -f "$dir/platform.txt" ] && echo "meeting_platform: $(cat "$dir/platform.txt")"
    echo "---"
    echo
    cat "$dir/transcript.txt"
  } > "$archive_file"

  printf '%s\n' "$archive_file"
}

start_recording() {
  local platform="$1"
  # A native helper has one stable app identity so macOS TCC permissions remain
  # attached to the capture process instead of changing with each shell call.
  local existing
  existing=$(pgrep -f "$RECORD_DIR/sessions/.*/system_audio.caf" | head -1 || true)
  if [ -n "$existing" ]; then
    log "existing native recording (pid $existing) found, adopting instead of duplicate start"
    FFPID="$existing"
    SESSION=$(ps -o command= -p "$existing" | grep -o "$RECORD_DIR/sessions/[^ ]*" | head -1 | cut -d' ' -f1 | xargs dirname)
    MATCH_RETRY_STAMP=0
    lock_course_match "$SESSION" || true
    return 0
  fi
  if [ ! -x "$NATIVE_CAPTURE_APP" ]; then
    log "ERROR: native audio capture app is missing: $NATIVE_CAPTURE_APP"
    notify_throttled "no-input" "检测到开会，但原生录音组件未安装；请运行一次 setup.sh 完成录音组件安装"
    return 1
  fi
  SESSION="$RECORD_DIR/sessions/$(date '+%Y-%m-%d_%H%M%S')"
  MATCH_RETRY_STAMP=0
  mkdir -p "$SESSION"
  echo "$platform" > "$SESSION/platform.txt"
  : > "$SESSION/native_audio_required"
  SYSTEM_AUDIO_FILE="$SESSION/system_audio.caf"
  MICROPHONE_AUDIO_FILE="$SESSION/microphone_audio.caf"
  NATIVE_STATUS_FILE="$SESSION/system_audio_status.txt"
  printf '%s %s\n' "$(date '+%s')" "$(date '+%Y-%m-%d %H:%M:%S %z')" > "$SESSION/recording_started_at.txt"
  "$NATIVE_CAPTURE_APP" "$SYSTEM_AUDIO_FILE" "$MICROPHONE_AUDIO_FILE" "$NATIVE_STATUS_FILE" >> "$LOG" 2>&1 &
  FFPID=$!
  {
    echo "recording_backend: $RECORDING_BACKEND"
    echo "system_audio_source: macOS ScreenCaptureKit system audio stream"
    echo "microphone_source: macOS ScreenCaptureKit microphone stream"
    echo "system_audio_file: $SYSTEM_AUDIO_FILE"
    echo "microphone_audio_file: $MICROPHONE_AUDIO_FILE"
    echo "native_capture_app: $NATIVE_CAPTURE_APP"
    echo "audio_format: stereo WAV after merge (left=system, right=microphone)"
  } > "$SESSION/audio_route.txt"
  local ready=0
  for _ in $(seq 1 20); do
    if [ -s "$NATIVE_STATUS_FILE" ]; then
      if grep -q '^ready$' "$NATIVE_STATUS_FILE"; then ready=1; break; fi
      if grep -q '^error:' "$NATIVE_STATUS_FILE"; then break; fi
    fi
    sleep 0.25
  done
  if [ "$ready" -ne 1 ]; then
    log "ERROR: native audio capture did not become ready (session=$SESSION, status=$(cat "$NATIVE_STATUS_FILE" 2>/dev/null || echo missing))"
    : > "$SESSION/audio_input_unhealthy"
    notify_throttled "no-input" "检测到开会，但系统声音或麦克风原生采集未就绪；已阻止生成不可靠文字稿"
    kill -TERM "$FFPID" 2>/dev/null || true
    wait "$FFPID" 2>/dev/null || true
    FFPID=""
    return 1
  fi
  log "RECORDING started (pid $FFPID, platform=$platform, session=$SESSION, backend=$RECORDING_BACKEND)"
  notify "recording" "检测到开课，录音已开始"
  # Lock the course while calendar/prep metadata is available. Transcription can
  # take several minutes, so relying only on a post-class lookup is fragile.
  lock_course_match "$SESSION" || true
  MATCH_RETRY_STAMP=$(date +%s)
}

merge_native_audio() {
  local dir="$1" rebuilt="$dir/audio.wav"
  [ -s "$dir/system_audio.caf" ] && [ -s "$dir/microphone_audio.caf" ] || {
    log "ERROR: native audio channel file missing (session=$dir)"
    : > "$dir/audio_input_unhealthy"
    return 1
  }
  ffmpeg -nostdin -y -hide_banner -loglevel error \
    -i "$dir/system_audio.caf" -i "$dir/microphone_audio.caf" \
    -filter_complex "[0:a]aresample=44100,pan=mono|c0=c0[system];[1:a]aresample=44100,pan=mono|c0=c0[mic];[system][mic]amerge=inputs=2[stereo]" \
    -map "[stereo]" -ac 2 -ar 44100 -c:a pcm_s16le "$rebuilt" >> "$LOG" 2>&1 || {
      log "ERROR: failed to merge native audio channels (session=$dir)"
      : > "$dir/audio_input_unhealthy"
      return 1
    }
  return 0
}

finalize_session() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  if [ -f "$dir/audio_input_unhealthy" ] && [ ! -s "$dir/system_audio.caf" ] && [ ! -s "$dir/microphone_audio.caf" ]; then
    log "native recording already marked unavailable; leaving diagnostic session untouched (session=$dir)"
    return 1
  fi
  if [ -f "$dir/native_audio_required" ] && [ ! -f "$dir/audio.wav" ]; then
    merge_native_audio "$dir" || return 1
  fi
  printf '%s %s\n' "$(date '+%s')" "$(date '+%Y-%m-%d %H:%M:%S %z')" > "$dir/recording_stopped_at.txt"
  check_recording_duration "$dir"
  check_audio_capture "$dir" || true
  check_transcription_preflight "$dir" || true
  log "RECORDING finalized (session=$dir)"
  transcribe_session "$dir"
  return 0
}

stop_recording() {
  [ -z "$FFPID" ] && return
  kill -TERM "$FFPID" 2>/dev/null
  wait "$FFPID" 2>/dev/null
  finalize_session "$SESSION" || true
  FFPID=""
  SESSION=""
  SYSTEM_AUDIO_FILE=""
  MICROPHONE_AUDIO_FILE=""
  NATIVE_STATUS_FILE=""
  MATCH_RETRY_STAMP=0
}

check_recording_duration() {
  local dir="$1" start_epoch stop_epoch wall_seconds audio_seconds
  [ -s "$dir/recording_started_at.txt" ] || return 0
  [ -f "$dir/audio.wav" ] || return 0
  start_epoch=$(awk 'NR==1 {print $1}' "$dir/recording_started_at.txt")
  stop_epoch=$(awk 'NR==1 {print $1}' "$dir/recording_stopped_at.txt" 2>/dev/null || date '+%s')
  audio_seconds=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$dir/audio.wav" 2>/dev/null || echo 0)
  wall_seconds=$((stop_epoch - start_epoch))
  if [ "$wall_seconds" -gt 120 ] && awk "BEGIN {exit !($audio_seconds < $wall_seconds * 0.75)}"; then
    : > "$dir/recording_incomplete"
    log "WARNING: recorded audio is shorter than meeting runtime (audio=${audio_seconds}s wall=${wall_seconds}s, session=$dir)"
    notify "recording-incomplete" "录音时长明显短于会议时长，已暂停课后反馈并保留音频供检查"
  fi
}

check_audio_capture() {
  local dir="$1" rc status
  [ -f "$dir/audio.wav" ] || return 0
  python3 "$SCRIPT_DIR/check_audio_capture.py" "$dir/audio.wav" \
    --output "$dir/audio_health.json" >> "$LOG" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 1 ] || {
    log "WARNING: audio source health check failed to run (session=$dir)"
    return 0
  }
  status=$(python3 -c "import json; print(json.load(open('$dir/audio_health.json')).get('status', 'unknown'))" 2>/dev/null || echo unknown)
  : > "$dir/audio_input_unhealthy"
  log "WARNING: audio source health check failed (status=$status, session=$dir)"
  case "$status" in
    system_audio_missing) body="录音已保留：麦克风已采集，但系统播放声没有进入录音；已跳过错误转写和课后反馈" ;;
    microphone_audio_missing) body="录音已保留：系统播放声已采集，但麦克风没有进入录音；已跳过错误转写和课后反馈" ;;
    *) body="录音已保留：系统声和麦克风没有被完整采集；已跳过错误转写和课后反馈" ;;
  esac
  notify "audio-input-unhealthy" "$body"
  return 1
}

check_transcription_preflight() {
  local dir="$1" rc status
  [ -f "$dir/audio.wav" ] || return 0
  [ -f "$dir/audio_input_unhealthy" ] && return 0
  python3 "$SCRIPT_DIR/check_transcription_preflight.py" "$dir/audio.wav" \
    --output "$dir/transcription_preflight.json" >> "$LOG" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 1 ] || {
    log "WARNING: transcription preflight failed to run (session=$dir)"
    return 0
  }
  status=$(python3 -c "import json; print(json.load(open('$dir/transcription_preflight.json')).get('status', 'unknown'))" 2>/dev/null || echo unknown)
  [ "$status" = "unusable" ] || return 0
  : > "$dir/audio_content_unhealthy"
  log "WARNING: transcription preflight rejected audio content (session=$dir)"
  notify "audio-content-unhealthy" "录音已保留，但抽样转写重复异常；已跳过完整转写和课后反馈"
  return 1
}

perm_selftest() {
  if [ -x "$NATIVE_CAPTURE_APP" ]; then
    log "NATIVE AUDIO PERMISSION: checked when a class starts (ScreenCaptureKit + microphone)"
  else
    log "NATIVE AUDIO PERMISSION: capture app missing; run setup.sh"
  fi
}

transcribe_session() {
  local dir="$1"
  local match="" sys="" stu="" archive_file="" material_file="" matched="no"
  [ -f "$dir/audio.wav" ] || { log "no audio.wav in $dir"; return; }
  # A completed transcript still needs to pass identity, quality, and AI
  # completion checks before its source audio can be removed.
  if [ -f "$dir/transcript.txt" ]; then
    log "already transcribed: $dir"
    if [ -f "$dir/retain_audio" ]; then
      log "audio retained by session marker: $dir"
    else
      log "audio retained until formal feedback completion: $dir"
    fi
    return
  fi
  # A failed attempt must not permanently quarantine a session. Retry after a
  # short cooldown so transient network/model failures recover automatically.
  if [ -f "$dir/.transcribe_failed" ]; then
    local failed_at now
    failed_at=$(stat -f%m "$dir/.transcribe_failed" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$failed_at" -gt 0 ] && [ $((now - failed_at)) -lt 900 ]; then
      log "skipping failed transcription during cooldown: $dir"
      return
    fi
    log "retrying previously failed transcription: $dir"
    unlink "$dir/.transcribe_failed" 2>/dev/null || true
  fi
  local size
  size=$(stat -f%z "$dir/audio.wav" 2>/dev/null || echo 0)
  if [ "$size" -lt 100000 ]; then log "audio too small ($size bytes), skipping transcription"; notify "skip" "录音文件过小，跳过转写"; return; fi
  if [ -f "$dir/audio_input_unhealthy" ] || [ -f "$dir/audio_content_unhealthy" ]; then
    if [ -f "$dir/audio_input_unhealthy" ]; then
      printf '%s\n' "[00:00 - 00:00] [录音输入自检失败：系统声或麦克风没有被正确采集，未生成课堂文字稿。]" > "$dir/transcript.txt"
      log "transcription skipped after audio source health failure (session=$dir)"
    else
      printf '%s\n' "[00:00 - 00:00] [录音抽样转写重复异常：未生成完整课堂文字稿。]" > "$dir/transcript.txt"
      log "transcription skipped after preflight rejection (session=$dir)"
    fi
  else
    notify "transcribing" "会议结束，录音已停止，正在转写文字稿…"
  fi
  # Transcription is intentionally local-only; no API key is loaded here.
  if [ -f "$dir/audio_input_unhealthy" ] || [ -f "$dir/audio_content_unhealthy" ] || python3 "$SCRIPT_DIR/transcribe_audio.py" "$dir/audio.wav" "$dir" >> "$LOG" 2>&1; then
    if [ -s "$dir/calendar_match.txt" ]; then
      match=$(sed -n '1p' "$dir/calendar_match.txt")
      log "using course match locked at recording start (session=$dir, match=$match)"
    else
      match=$("$SCRIPT_DIR/match_calendar_event.sh" "$dir" 2>/dev/null) || match=""
    fi
    if [ -n "$match" ]; then
      matched="yes"
      sys="${match%%|*}"
      stu="${match##*|}"
      if [ -x "$RESOLVER" ]; then
        stu="$(python3 "$RESOLVER" "$VAULT_PATH" "$stu" 2>/dev/null || printf '%s' "$stu")"
      fi
    fi
    archive_file="$(archive_transcript "$dir" "$sys" "$stu" "$matched")"
    log "archived transcript to $archive_file"
    # 无论日历是否临时可用都创建待 AI 队列，避免一次匹配失败截断课后链路。
    if [ "$matched" = "yes" ]; then
      if material_file=$(bash "$SCRIPT_DIR/postclass_generate.sh" "$dir" "$VAULT_PATH" "$sys" "$stu" 2>> "$LOG"); then
        printf '%s\n' "$material_file" >> "$LOG"
        if grep -q '^status: 待人工确认录音$' "$material_file"; then
          log "post-class AI withheld: transcript quality unusable (session=$dir)"
          notify "done" "转写完成，但录音内容无法辨认，暂未生成正式反馈"
        else
          bash "$SCRIPT_DIR/trigger_postclass_ai.sh" "$dir" "$material_file" >> "$LOG" 2>&1 || \
            log "WARNING: failed to launch post-class AI trigger (session=$dir)"
          notify "done" "转写完成，文字稿已归档，Codex 正在生成正式反馈并更新档案"
        fi
      else
        RC=$?
        if [ "$RC" -eq 2 ]; then
          notify "done" "转写完成，文字稿已归档（未匹配到课程，跳过反馈素材/档案更新）"
        else
          notify "done" "转写完成 ✅（反馈草稿准备失败，查看日志）"
        fi
      fi
    else
      if material_file=$(bash "$SCRIPT_DIR/postclass_generate.sh" "$dir" "$VAULT_PATH" 2>> "$LOG"); then
        printf '%s\n' "$material_file" >> "$LOG"
        log "calendar match unavailable; queued transcript for AI reconciliation: $dir"
        if grep -q '^status: 待人工确认录音$' "$material_file"; then
          log "post-class AI withheld: transcript quality unusable (session=$dir)"
          notify "done" "转写完成，但录音内容无法辨认，暂未生成正式反馈"
        else
          bash "$SCRIPT_DIR/trigger_postclass_ai.sh" "$dir" "$material_file" >> "$LOG" 2>&1 || \
            log "WARNING: failed to launch post-class AI trigger (session=$dir)"
          notify "done" "转写完成，文字稿已归档；Codex 正在重试识别课程并生成反馈"
        fi
      else
        notify "done" "转写完成 ✅（待处理任务创建失败，查看日志）"
      fi
    fi
  else
    touch "$dir/.transcribe_failed"
    notify "transcribe-failed" "转写失败，查看日志：$LOG"
  fi
}

# ---------- modes ----------
if [ "${1:-}" = "notify-test" ]; then
  notify "recording" "通知测试：开课和散会弹窗链路正常"
  wait
  exit 0
fi

if [ "${1:-}" = "once" ]; then
  echo "Manual recording — press Ctrl-C when class ends."
  start_recording "manual" || exit 1
  trap 'stop_recording; exit 0' INT TERM
  while true; do sleep 5; done
fi

# daemon loop
log "watcher started (pid $$)"
# Crash recovery for native sessions left by a previous watcher instance.
for marker in "$RECORD_DIR"/sessions/*/native_audio_required; do
  [ -f "$marker" ] || continue
  dir="$(dirname "$marker")"
  [ -f "$dir/audio_input_unhealthy" ] && continue
  if [ ! -f "$dir/audio.wav" ] && ! pgrep -qf "$dir/system_audio.caf"; then
    log "adopting orphaned native recording: $dir"
    finalize_session "$dir" || true
  fi
done
# Compatibility recovery: transcribe old BlackHole recordings left by a
# previous version. New recordings never use this path.
for f in "$RECORD_DIR"/sessions/*/audio.wav; do
  [ -f "$f" ] || continue
  if ! pgrep -qf "ffmpeg.*$(basename "$(dirname "$f")")"; then
    log "adopting orphaned recording: $f"
    transcribe_session "$(dirname "$f")"
  fi
done
perm_selftest
miss=0
while true; do
  platform=$(meeting_running) && in_meeting=1 || in_meeting=0
  if [ "$in_meeting" = 1 ]; then
    miss=0
    if [ -n "$FFPID" ] && ! kill -0 "$FFPID" 2>/dev/null; then
      log "ERROR: recording process exited unexpectedly (pid=$FFPID, session=$SESSION)"
      notify "recording-error" "录音进程意外中断，已保留当前片段并尝试恢复"
      finalize_session "$SESSION" || true
      FFPID=""
      SESSION=""
    fi
    [ -z "$FFPID" ] && start_recording "$platform"
    [ -n "$FFPID" ] && retry_course_match
  else
    if [ -n "$FFPID" ]; then
      miss=$((miss+1))
      if [ "$miss" -ge "$MISS_LIMIT" ]; then stop_recording; fi
    else
      # meeting gone and we hold no recording — finalize any orphaned one
      for marker in "$RECORD_DIR"/sessions/*/native_audio_required; do
        [ -f "$marker" ] || continue
        dir="$(dirname "$marker")"
        [ -f "$dir/audio_input_unhealthy" ] && continue
        if [ ! -f "$dir/audio.wav" ] && ! pgrep -qf "$dir/system_audio.caf"; then
          log "meeting over, finalizing orphaned native recording: $dir"
          finalize_session "$dir" || true
        fi
      done
      for f in "$RECORD_DIR"/sessions/*/audio.wav; do
        [ -f "$f" ] || continue
        if ! pgrep -qf "ffmpeg.*$(basename "$(dirname "$f")")" && [ ! -f "$(dirname "$f")/transcript.txt" ]; then
          log "meeting over, transcribing orphaned recording: $f"
          transcribe_session "$(dirname "$f")"
        fi
      done
    fi
  fi
  sleep "$INTERVAL"
done
