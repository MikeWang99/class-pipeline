#!/bin/bash
# setup.sh — one-command closed-loop installer for physics-class-pipeline.
#
# Steps:
#   1. dependency check and installation (Homebrew / ffmpeg / whisper-cpp / python3 / swift)
#   2. prepare the native macOS audio capture helper
#   3. detect Obsidian vault (search common locations, take first .obsidian dir)
#   4. install or download the local Whisper Turbo model
#   5. write config.json
#   6. register two launchd jobs: daily pre-class scan + resident meeting watcher
#   7. link the skill into ~/.codex/skills and run a health check
#
# Re-running is safe (idempotent). Uninstall with uninstall.sh.
set -Eeuo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SCAN="$HOME/Library/LaunchAgents/com.physicsclass.preclass-scan.plist"
PLIST_WATCH="$HOME/Library/LaunchAgents/com.physicsclass.meeting-watcher.plist"
DATA_DIR="$HOME/physics-class-pipeline-data"
SCAN_HOUR=10
SCAN_MINUTE=0
AUTO_MODE=0
SKIP_MODEL_DOWNLOAD=0
SKILL_VERSION="$(tr -d '[:space:]' < "$SKILL_DIR/VERSION" 2>/dev/null || echo unknown)"
export CLASS_PIPELINE_VERSION="$SKILL_VERSION"
VAULT_OVERRIDE="${VAULT_PATH:-}"
WHISPER_MODEL_PATH="${WHISPER_MODEL:-$HOME/.cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin}"
WHISPER_MODEL_URL="${WHISPER_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true}"

usage() {
  cat <<'EOF'
用法：bash setup.sh [选项]

选项：
  --auto                  首次调用时使用自动化安装路径
  --vault PATH            指定 Obsidian Vault；未指定时自动探测
  --data-dir PATH        指定录音和日志目录
  --skip-model-download   不自动下载 Whisper 模型（安装后将保持未就绪）
  --help                  显示帮助
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --auto|--repair) AUTO_MODE=1 ;;
    --vault)
      [ "$#" -ge 2 ] || { echo "缺少 --vault 的路径" >&2; exit 2; }
      VAULT_OVERRIDE="$2"; shift ;;
    --data-dir)
      [ "$#" -ge 2 ] || { echo "缺少 --data-dir 的路径" >&2; exit 2; }
      DATA_DIR="$2"; shift ;;
    --skip-model-download) SKIP_MODEL_DOWNLOAD=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知选项：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

expand_home() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
fail() { echo "  ❌ $*"; }
step() { echo; echo "==> $*"; }

add_brew_to_path() {
  local brew_bin
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$brew_bin" ]; then
      eval "$("$brew_bin" shellenv)"
      return 0
    fi
  done
  return 1
}

ensure_brew() {
  add_brew_to_path 2>/dev/null || true
  if command -v brew >/dev/null 2>&1; then
    ok "brew: $(command -v brew)"
    return 0
  fi
  if [ "${SKIP_DEPENDENCY_INSTALL:-0}" = "1" ]; then
    fail "未安装 Homebrew，且 SKIP_DEPENDENCY_INSTALL=1"
    return 1
  fi
  command -v curl >/dev/null 2>&1 || {
    fail "缺少 curl，无法自动安装 Homebrew"
    return 1
  }
  warn "未安装 Homebrew，正在运行官方安装程序..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
    fail "Homebrew 安装失败"
    return 1
  }
  add_brew_to_path || true
  command -v brew >/dev/null 2>&1 || {
    fail "Homebrew 安装后仍无法找到 brew"
    return 1
  }
  ok "brew: $(command -v brew)"
}

ensure_formula_command() {
  local command_name="$1" formula_name="$2"
  if command -v "$command_name" >/dev/null 2>&1; then
    ok "$command_name: $(command -v "$command_name")"
    return 0
  fi
  warn "$command_name 未安装，正在执行 brew install $formula_name..."
  brew install "$formula_name" || {
    fail "$formula_name 安装失败"
    return 1
  }
  command -v "$command_name" >/dev/null 2>&1 || {
    fail "安装后仍找不到 $command_name"
    return 1
  }
  ok "$command_name: $(command -v "$command_name")"
}

download_whisper_model() {
  WHISPER_MODEL_PATH="$(expand_home "$WHISPER_MODEL_PATH")"
  if [ -s "$WHISPER_MODEL_PATH" ]; then
    ok "本地 Whisper 模型: $WHISPER_MODEL_PATH"
    return 0
  fi
  if [ "$SKIP_MODEL_DOWNLOAD" -eq 1 ]; then
    warn "未找到本地模型，已按选项跳过自动下载: $WHISPER_MODEL_PATH"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || {
    fail "缺少 curl，无法下载 Whisper 模型"
    return 1
  }
  mkdir -p "$(dirname "$WHISPER_MODEL_PATH")"
  local partial="${WHISPER_MODEL_PATH}.partial"
  warn "未找到本地模型，正在自动下载 Whisper Turbo 模型（文件较大，请耐心等待）..."
  curl --fail --location --retry 3 --progress-bar "$WHISPER_MODEL_URL" -o "$partial" || {
    rm -f "$partial"
    fail "Whisper 模型下载失败；可设置 WHISPER_MODEL 指向已有本地模型"
    return 1
  }
  [ -s "$partial" ] || {
    rm -f "$partial"
    fail "Whisper 模型下载结果为空"
    return 1
  }
  mv -f "$partial" "$WHISPER_MODEL_PATH"
  ok "本地 Whisper 模型已就绪: $WHISPER_MODEL_PATH"
}

# Build a minimal background .app wrapper. macOS attributes TCC permission
# prompts (microphone / files) to the app bundle, so launching our scripts
# inside an app is what makes the one-click "Allow" dialog appear.
# IMPORTANT: TCC grants are bound to the app's code signature — NEVER rebuild
# or re-sign an existing app, or the previously granted permission is voided.
make_app() {
  local name="$1" bundleid="$2" cmd="$3"
  local app="$HOME/Applications/$name.app"
  if [ -x "$app/Contents/MacOS/$name" ] && [ -f "$app/Contents/Info.plist" ]; then
    echo "$app"   # keep existing bundle + signature, preserve TCC grant
    return 0
  fi
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$bundleid</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>NSCalendarsUsageDescription</key><string>读取课程日历，用于生成备课记录并将课堂文字稿匹配到对应学生。</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>读取课程日历，用于生成备课记录并将课堂文字稿匹配到对应学生。</string>
  <key>NSMicrophoneUsageDescription</key><string>录制在线课程音频，以便生成课堂文字稿。</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
  printf '#!/bin/bash\nexec %s\n' "$cmd" > "$app/Contents/MacOS/$name"
  chmod +x "$app/Contents/MacOS/$name"
  codesign --force --sign - "$app" >/dev/null 2>&1 || true
  # register with LaunchServices so TCC attributes the permission prompt to the app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$app" >/dev/null 2>&1 || true
  echo "$app"
}

# ScreenCaptureKit provides the current system playback stream and the current
# microphone stream directly. Keep this helper in a stable app bundle so the
# user's macOS TCC grants survive watcher restarts.
make_native_capture_app() {
  local app="$HOME/Applications/PhysicsClassAudio.app"
  local binary="$app/Contents/MacOS/PhysicsClassAudio"
  local changed=0
  mkdir -p "$app/Contents/MacOS"
  if [ ! -x "$binary" ] || [ "$SKILL_DIR/scripts/capture_native_audio.swift" -nt "$binary" ]; then
    swiftc "$SKILL_DIR/scripts/capture_native_audio.swift" -o "$binary" || return 1
    chmod +x "$binary"
    changed=1
  fi
  if [ ! -f "$app/Contents/Info.plist" ]; then
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.physicsclass.audio-capture</string>
  <key>CFBundleName</key><string>PhysicsClassAudio</string>
  <key>CFBundleExecutable</key><string>PhysicsClassAudio</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>NSMicrophoneUsageDescription</key><string>录制在线课程音频，以便生成课堂文字稿。</string>
  <key>NSScreenCaptureUsageDescription</key><string>采集在线课程的系统播放声音，以便生成完整课堂文字稿。</string>
  <key>NSAudioCaptureUsageDescription</key><string>采集在线课程的系统播放声音，以便生成完整课堂文字稿。</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
    changed=1
  fi
  if [ "$changed" -eq 1 ]; then
    codesign --force --sign - "$app" >/dev/null 2>&1 || true
  fi
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$app" >/dev/null 2>&1 || true
  printf '%s\n' "$app"
}

# ---------- 1. dependencies ----------
step "1/7 依赖检查"
ensure_brew || exit 1
ensure_formula_command ffmpeg ffmpeg || exit 1
ensure_formula_command whisper-cli whisper-cpp || exit 1
MISSING=()
for tool in python3 swift osascript; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool: $(command -v "$tool")"
  else MISSING+=("$tool"); fail "$tool 未安装"; fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  fail "系统依赖缺失，无法完成安装"; exit 1
fi

# ---------- 2. native audio capture ----------
step "2/7 原生音频采集组件"
APP_AUDIO="$(make_native_capture_app)" || { fail "原生音频采集组件编译失败"; exit 1; }
ok "系统声音 + 麦克风双路采集：$APP_AUDIO"
ok "不依赖 BlackHole、Multi-Output 或固定的扬声器名称"
if [ -t 0 ] && [ -t 1 ]; then
  permission_probe_dir="$(mktemp -d "$DATA_DIR/.permission-probe.XXXXXX")"
  "$APP_AUDIO" "$permission_probe_dir/system.caf" +    "$permission_probe_dir/microphone.caf" "$permission_probe_dir/status.txt" +    >/dev/null 2>&1 &
  permission_probe_pid=$!
  sleep 2
  kill -TERM "$permission_probe_pid" 2>/dev/null || true
  wait "$permission_probe_pid" 2>/dev/null || true
  rm -rf "$permission_probe_dir"
  ok "已完成一次音频权限探测；如 macOS 弹窗出现，请点击允许"
fi

# ---------- 3. vault detection ----------
step "3/7 探测 Obsidian Vault"
# iCloud can contain an empty, similarly named directory next to the real
# vault. Prefer the candidate that already contains the teaching tree and
# notes, otherwise a reinstall can silently redirect the pipeline.
if [ -n "$VAULT_OVERRIDE" ]; then
  VAULT="$(expand_home "$VAULT_OVERRIDE")"
else
  VAULT="$(
    {
      mdfind 'kMDItemFSName == ".obsidian"c' 2>/dev/null || true
      find "$HOME/Documents" "$HOME/Desktop" "$HOME/Library/Mobile Documents" \
           "$HOME/Library/CloudStorage" "$HOME/Obsidian" \
           -maxdepth 7 -name ".obsidian" -type d 2>/dev/null || true
    } | python3 -c '
import sys
from pathlib import Path

def score(path):
    teaching = path / "上课记录"
    folders = ("备课内容", "课堂文字稿", "课后反馈", "课后反馈草稿", "学生档案")
    note_count = sum(1 for root in (path, teaching) if root.is_dir() for _ in root.glob("*.md"))
    return int(teaching.is_dir()) * 1000 + sum(int((teaching / folder).is_dir()) * 100 for folder in folders) + min(note_count, 1000)

candidates = {Path(line.strip()).parent for line in sys.stdin if line.strip()}
if candidates:
    print(max(candidates, key=score))
'
  )"
fi
if [ -z "$VAULT" ]; then
  fail "未找到 Obsidian Vault。请使用 --vault /绝对路径，或设置 VAULT_PATH 后重跑 setup.sh"
  exit 1
fi
if [ ! -d "$VAULT" ]; then
  fail "指定的 Vault 不存在：$VAULT"
  exit 1
fi
ok "Vault: $VAULT"

# ---------- 4. local transcription model ----------
step "4/7 本地转写模型检查"
download_whisper_model || exit 1
WHISPER_CLI_PATH="$(command -v whisper-cli)"

# ---------- 5. config.json ----------
step "5/7 写入 config.json"
python3 - "$SKILL_DIR" "$VAULT" "$DATA_DIR" "$SCAN_HOUR" "$SCAN_MINUTE" \
  "$WHISPER_CLI_PATH" "$WHISPER_MODEL_PATH" <<'PYEOF'
import json, os, sys
skill_dir, vault, data_dir, hour, minute, whisper_cli, whisper_model = sys.argv[1:8]
cfg = {
    "vault_path": vault,
    "recordings_dir": data_dir,
    "skill_version": os.environ.get("CLASS_PIPELINE_VERSION", "unknown"),
    "calendar_keyword": "Class",
    "scan_hour": int(hour),
    "scan_minute": int(minute),
    "transcribe_backend": "local",
    "recording_backend": "native_system_and_microphone",
    "whisper_cli": sys.argv[6],
    "whisper_model": sys.argv[7],
    "transcribe_language": os.environ.get("TRANSCRIBE_LANGUAGE", "auto"),
}
with open(f"{skill_dir}/config.json", "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
print("  written:", f"{skill_dir}/config.json")
PYEOF
mkdir -p "$DATA_DIR/sessions" "$DATA_DIR/logs"
# note folders in vault (Obsidian creates on demand, but pre-create for clarity)
if [ -n "$VAULT" ]; then
  mkdir -p "$VAULT/上课记录/备课内容" "$VAULT/上课记录/课堂文字稿" \
           "$VAULT/上课记录/课后反馈" "$VAULT/上课记录/课后反馈草稿" +           "$VAULT/上课记录/学生档案" "$VAULT/上课记录/教学优化"
  ok "Vault 笔记分区已就绪：上课记录/{备课内容,课堂文字稿,课后反馈,课后反馈草稿,学生档案,教学优化}"
fi

# ---------- 6. launchd jobs + permission guidance ----------
step "6/7 注册后台任务并引导系统授权"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Applications"

APP_WATCH="$(make_app "PhysicsClassWatcher" "com.physicsclass.watcher" "bash '$SKILL_DIR/scripts/meeting_watcher.sh'")"
APP_SCAN="$(make_app "PhysicsClassScanner" "com.physicsclass.scanner" "/usr/bin/python3 '$SKILL_DIR/scripts/preclass_scan.py'")"
ok "后台应用已创建：PhysicsClassWatcher（录音监听）/ PhysicsClassScanner（课前扫描）/ PhysicsClassAudio（原生采集）"

cat > "$PLIST_SCAN" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.physicsclass.preclass-scan</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/open</string>
    <string>-gj</string>
    <string>$APP_SCAN</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>$SCAN_HOUR</integer>
    <key>Minute</key><integer>$SCAN_MINUTE</integer>
  </dict>
  <key>StandardOutPath</key><string>$DATA_DIR/logs/preclass-scan.log</string>
  <key>StandardErrorPath</key><string>$DATA_DIR/logs/preclass-scan.log</string>
</dict></plist>
EOF

cat > "$PLIST_WATCH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.physicsclass.meeting-watcher</string>
  <key>ProgramArguments</key><array>
    <string>$APP_WATCH/Contents/MacOS/PhysicsClassWatcher</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$DATA_DIR/logs/watcher-stdout.log</string>
  <key>StandardErrorPath</key><string>$DATA_DIR/logs/watcher-stderr.log</string>
</dict></plist>
EOF

load_launchd_job() {
  local plist="$1" label="$2" uid
  uid="$(id -u)"
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  if ! launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null; then
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist"
  fi
  launchctl print "gui/$uid/$label" >/dev/null 2>&1 || {
    fail "launchd 任务未能注册：$label"
    return 1
  }
}
load_launchd_job "$PLIST_SCAN" "com.physicsclass.preclass-scan" || exit 1
load_launchd_job "$PLIST_WATCH" "com.physicsclass.meeting-watcher" || exit 1
ok "每日 $SCAN_HOUR:${SCAN_MINUTE}0 课前扫描（com.physicsclass.preclass-scan）"
ok "常驻会议监听（com.physicsclass.meeting-watcher）"

echo
echo "  首次开始录课时，macOS 可能会分别请求 PhysicsClassAudio 的【麦克风】和【屏幕与系统音频录制】权限。请点击【允许】。"
echo "  如果之前拒绝过：打开 系统设置 → 隐私与安全性 → 麦克风 / 屏幕与系统音频录制，启用 PhysicsClassAudio。"

# ---------- 7. skill install ----------
step "7/7 安装 skill 到 AI 助手"
dest="$HOME/.codex/skills"
mkdir -p "$dest"
link_skill() {
  local link_path="$1"
  if [ "$link_path" = "$SKILL_DIR" ]; then
    ok "skill 已在当前安装目录：$SKILL_DIR"
  elif [ -L "$link_path" ]; then
    ln -sfn "$SKILL_DIR" "$link_path"
    ok "$link_path -> $SKILL_DIR"
  elif [ -e "$link_path" ]; then
    warn "保留已有 skill 目录，不覆盖：$link_path"
  else
    ln -s "$SKILL_DIR" "$link_path"
    ok "$link_path -> $SKILL_DIR"
  fi
}
link_skill "$dest/class-pipeline"
link_skill "$dest/physics-class-pipeline"

export CLASS_PIPELINE_VERSION="$SKILL_VERSION"
if [ -x "$SKILL_DIR/scripts/healthcheck.sh" ]; then
  "$SKILL_DIR/scripts/healthcheck.sh" || warn "安装完成，但健康检查仍有未就绪项目，请按上方提示处理"
fi

echo
echo "================ 安装完成 ================"
echo "  版本        : $SKILL_VERSION"
echo "  config.json : $SKILL_DIR/config.json"
echo "  录音目录    : $DATA_DIR"
echo "  日志        : $DATA_DIR/logs/"
echo "  卸载        : bash $SKILL_DIR/uninstall.sh"
echo "=========================================="
echo "下一步：在 AI 助手里说「备课」补全明天的备课内容，或直接开会测试自动录音。"
