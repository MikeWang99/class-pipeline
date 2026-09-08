#!/bin/bash
# setup.sh — one-command closed-loop installer for physics-class-pipeline.
#
# Steps:
#   1. dependency check (brew / ffmpeg / python3 / swift)
#   2. install BlackHole 2ch virtual audio device + create multi-output device
#   3. detect Obsidian vault (search common locations, take first .obsidian dir)
#   4. check optional GROQ_API_KEY (local Whisper is the fallback)
#   5. write config.json
#   6. register two launchd jobs: daily pre-class scan + resident meeting watcher
#   7. link the skill into ~/.qoder/skills and ~/.codex/skills
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

# ---------- 2. audio chain ----------
step "2/7 音频链路（BlackHole + 多输出设备）"
bash "$SKILL_DIR/scripts/setup_audio.sh" install || warn "音频链路安装未完成，可稍后运行 scripts/setup_audio.sh install 补齐"

# ---------- 3. vault detection ----------
step "3/7 探测 Obsidian Vault"
VAULT=""
CANDIDATES=()
while IFS= read -r d; do CANDIDATES+=("$d"); done < <(
  find "$HOME/Documents" "$HOME/Desktop" "$HOME/Library/Mobile Documents" \
       -maxdepth 5 -name ".obsidian" -type d 2>/dev/null | head -3)
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  fail "未找到 Obsidian Vault（含 .obsidian 目录）。请手动创建后编辑 config.json 的 vault_path。"
else
  VAULT="$(dirname "${CANDIDATES[0]}")"
  ok "Vault: $VAULT"
fi

# ---------- 4. transcription backends ----------
step "4/7 转写后端检查"
if [ -n "${GROQ_API_KEY:-}" ]; then
  ok "环境变量已设置"
elif grep -q "GROQ_API_KEY" "$HOME/.zshrc" 2>/dev/null; then
  ok "已在 ~/.zshrc 中找到（转写脚本会自动读取）"
else
  warn "未找到 GROQ_API_KEY。Groq 将被跳过，转写会自动使用本地 Whisper；如需 Groq，可稍后写入 ~/.zshrc"
fi

# ---------- 5. config.json ----------
step "5/7 写入 config.json"
python3 - "$SKILL_DIR" "$VAULT" "$DATA_DIR" "$SCAN_HOUR" "$SCAN_MINUTE" <<'PYEOF'
import json, sys
skill_dir, vault, data_dir, hour, minute = sys.argv[1:6]
cfg = {
    "vault_path": vault,
    "recordings_dir": data_dir,
    "calendar_keyword": "Class",
    "scan_hour": int(hour),
    "scan_minute": int(minute),
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
ok "后台应用已创建：PhysicsClassWatcher（录音监听）/ PhysicsClassScanner（课前扫描）"

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

# guided one-time microphone authorization
echo
echo "  ⏳ 正在启动监听程序并申请麦克风权限……"
echo "  👉 屏幕上会弹出系统窗口「PhysicsClassWatcher 想要访问麦克风」——请点击【允许】（仅此一次，之后全自动）"
LOGF="$DATA_DIR/logs/watcher.log"
BASE=$(wc -l < "$LOGF" 2>/dev/null || echo 0)
GRANTED=0
for _ in $(seq 1 60); do
  if tail -n +"$((BASE+1))" "$LOGF" 2>/dev/null | grep -q "MIC PERMISSION: granted"; then GRANTED=1; break; fi
  sleep 2
done
if [ "$GRANTED" = 1 ]; then
  ok "麦克风授权成功"
else
  warn "还没检测到授权完成。若未看到弹窗：打开 系统设置 → 隐私与安全性 → 麦克风，把 PhysicsClassWatcher 打开即可；完成后会自动生效。"
fi

# ---------- 7. skill install ----------
step "7/7 安装 skill 到 AI 助手"
for dest in "$HOME/.qoder/skills" "$HOME/.codex/skills"; do
  mkdir -p "$dest"
  ln -sfn "$SKILL_DIR" "$dest/physics-class-pipeline"
  ok "$dest/physics-class-pipeline -> $SKILL_DIR"
done

echo
echo "================ 安装完成 ================"
if ! system_profiler SPAudioDataType 2>/dev/null | grep -qi "blackhole"; then
  echo "  ⚠️  BlackHole 尚未生效：重启 Mac 后再跑一次 bash $SKILL_DIR/setup.sh 完成音频链路"
fi
echo "  config.json : $SKILL_DIR/config.json"
echo "  录音目录    : $DATA_DIR"
echo "  日志        : $DATA_DIR/logs/"
echo "  卸载        : bash $SKILL_DIR/uninstall.sh"
echo "=========================================="
echo "下一步：在 AI 助手里说「备课」补全明天的备课内容，或直接开会测试自动录音。"
