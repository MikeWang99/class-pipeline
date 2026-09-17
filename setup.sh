#!/bin/bash
# setup.sh — one-command closed-loop installer for physics-class-pipeline.
#
# Steps:
#   1. dependency check (brew / ffmpeg / python3 / swift)
#   2. prepare the native macOS audio capture helper
#   3. detect Obsidian vault (search common locations, take first .obsidian dir)
#   4. check the local Whisper Turbo model
#   5. write config.json
#   6. register two launchd jobs: daily pre-class scan + resident meeting watcher
#   7. link the skill into ~/.codex/skills
#
# Re-running is safe (idempotent). Uninstall with uninstall.sh.
set -u

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SCAN="$HOME/Library/LaunchAgents/com.physicsclass.preclass-scan.plist"
PLIST_WATCH="$HOME/Library/LaunchAgents/com.physicsclass.meeting-watcher.plist"
DATA_DIR="$HOME/physics-class-pipeline-data"
SCAN_HOUR=10
SCAN_MINUTE=0

ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
fail() { echo "  ❌ $*"; }
step() { echo; echo "==> $*"; }

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
if ! command -v brew >/dev/null 2>&1; then
  fail "未安装 Homebrew。请先运行：/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  exit 1
fi
ok "brew: $(command -v brew)"
if ! command -v ffmpeg >/dev/null 2>&1; then
  warn "ffmpeg 未安装，正在自动安装（brew install ffmpeg）..."
  brew install ffmpeg || { fail "ffmpeg 安装失败"; exit 1; }
fi
ok "ffmpeg: $(command -v ffmpeg)"
MISSING=()
for tool in python3 swift osascript; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool: $(command -v "$tool")"
  else MISSING+=("$tool"); fail "$tool 未安装"; fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  fail "请先安装缺失依赖后重跑本脚本"; exit 1
fi

# ---------- 2. native audio capture ----------
step "2/7 原生音频采集组件"
APP_AUDIO="$(make_native_capture_app)" || { fail "原生音频采集组件编译失败"; exit 1; }
ok "系统声音 + 麦克风双路采集：$APP_AUDIO"
ok "不依赖 BlackHole、Multi-Output 或固定的扬声器名称"

# ---------- 3. vault detection ----------
step "3/7 探测 Obsidian Vault"
# iCloud can contain an empty, similarly named directory next to the real
# vault. Prefer the candidate that already contains the teaching tree and
# notes, otherwise a reinstall can silently redirect the pipeline.
VAULT="$(
  find "$HOME/Documents" "$HOME/Desktop" "$HOME/Library/Mobile Documents" \
       -maxdepth 5 -name ".obsidian" -type d 2>/dev/null |
  python3 -c '
import sys
from pathlib import Path

def score(path):
    teaching = path / "上课记录"
    folders = ("备课内容", "课堂文字稿", "课后反馈", "课后反馈草稿", "学生档案")
    note_count = sum(1 for root in (path, teaching) if root.is_dir() for _ in root.glob("*.md"))
    return int(teaching.is_dir()) * 1000 + sum(int((teaching / folder).is_dir()) * 100 for folder in folders) + min(note_count, 1000)

candidates = [Path(line.strip()).parent for line in sys.stdin if line.strip()]
if candidates:
    print(max(candidates, key=score))
'
)"
if [ -z "$VAULT" ]; then
  fail "未找到 Obsidian Vault（含 .obsidian 目录）。请手动创建后编辑 config.json 的 vault_path。"
else
  ok "Vault: $VAULT"
fi

# ---------- 4. local transcription model ----------
step "4/7 本地转写模型检查"
WHISPER_MODEL_PATH="${WHISPER_MODEL:-$HOME/.cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin}"
if [ -f "$WHISPER_MODEL_PATH" ]; then
  ok "本地 Whisper 模型: $WHISPER_MODEL_PATH"
else
  warn "未找到本地模型: $WHISPER_MODEL_PATH"
  warn "请先下载 ggml-large-v3-turbo-q5_0.bin，再运行 setup.sh"
fi

# ---------- 5. config.json ----------
step "5/7 写入 config.json"
python3 - "$SKILL_DIR" "$VAULT" "$DATA_DIR" "$SCAN_HOUR" "$SCAN_MINUTE" <<'PYEOF'
import json, os, sys
skill_dir, vault, data_dir, hour, minute = sys.argv[1:6]
cfg = {
    "vault_path": vault,
    "recordings_dir": data_dir,
    "calendar_keyword": "Class",
    "scan_hour": int(hour),
    "scan_minute": int(minute),
    "transcribe_backend": "local",
    "recording_backend": "native_system_and_microphone",
    "whisper_model": os.path.expanduser(os.environ.get(
        "WHISPER_MODEL", "~/.cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin")),
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
           "$VAULT/上课记录/课后反馈" "$VAULT/上课记录/课后反馈草稿" "$VAULT/上课记录/学生档案"
  ok "Vault 笔记分区已就绪：上课记录/{备课内容,课堂文字稿,课后反馈,课后反馈草稿,学生档案}"
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

launchctl unload "$PLIST_SCAN" 2>/dev/null; launchctl load "$PLIST_SCAN"
launchctl unload "$PLIST_WATCH" 2>/dev/null; launchctl load "$PLIST_WATCH"
ok "每日 $SCAN_HOUR:${SCAN_MINUTE}0 课前扫描（com.physicsclass.preclass-scan）"
ok "常驻会议监听（com.physicsclass.meeting-watcher）"

echo
echo "  首次开始录课时，macOS 可能会分别请求 PhysicsClassAudio 的【麦克风】和【屏幕与系统音频录制】权限。请点击【允许】。"
echo "  如果之前拒绝过：打开 系统设置 → 隐私与安全性 → 麦克风 / 屏幕与系统音频录制，启用 PhysicsClassAudio。"

# ---------- 7. skill install ----------
step "7/7 安装 skill 到 AI 助手"
dest="$HOME/.codex/skills"
mkdir -p "$dest"
ln -sfn "$SKILL_DIR" "$dest/physics-class-pipeline"
ok "$dest/physics-class-pipeline -> $SKILL_DIR"

echo
echo "================ 安装完成 ================"
echo "  config.json : $SKILL_DIR/config.json"
echo "  录音目录    : $DATA_DIR"
echo "  日志        : $DATA_DIR/logs/"
echo "  卸载        : bash $SKILL_DIR/uninstall.sh"
echo "=========================================="
echo "下一步：在 AI 助手里说「备课」补全明天的备课内容，或直接开会测试自动录音。"
