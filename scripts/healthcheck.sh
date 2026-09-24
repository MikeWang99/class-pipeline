#!/bin/bash
# healthcheck.sh — verify that class-pipeline is actually ready to record.
#
# Exit codes:
#   0  ready
#   1  configured but one or more runtime checks failed
#   2  setup has not been run yet
set -u

export PATH="$HOME/.local/Homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$SKILL_DIR/config.json"
RECORD_DIR_DEFAULT="$HOME/physics-class-pipeline-data"
FAILURES=0

pass() { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
fail() { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }

echo "Class Pipeline health check"
echo "Skill: $SKILL_DIR"

if [ ! -f "$CONFIG" ]; then
  echo "  ⏳ 尚未初始化：请运行 bash $SKILL_DIR/setup.sh --auto"
  exit 2
fi

if ! python3 - "$CONFIG" <<'PYEOF'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    json.load(handle)
PYEOF
then
  fail "config.json 不是有效 JSON：$CONFIG"
else
  pass "config.json 可读取"
fi

cfg() {
  python3 - "$CONFIG" "$1" "$2" <<'PYEOF'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value = json.load(handle).get(sys.argv[2], sys.argv[3])
except Exception:
    value = sys.argv[3]
print(value)
PYEOF
}

expand_home() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

VAULT_PATH="$(expand_home "$(cfg vault_path "")")"
RECORD_DIR="$(expand_home "$(cfg recordings_dir "$RECORD_DIR_DEFAULT")")"
WHISPER_CLI="$(expand_home "$(cfg whisper_cli "")")"
WHISPER_MODEL="$(expand_home "$(cfg whisper_model "$HOME/.cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin")")"

[ -n "$VAULT_PATH" ] && [ -d "$VAULT_PATH" ] \
  && pass "Obsidian Vault: $VAULT_PATH" \
  || fail "Obsidian Vault 不存在或未配置：$VAULT_PATH"

for folder in "备课内容" "课堂文字稿" "课后反馈" "课后反馈草稿" "学生档案" "教学优化"; do
  if [ -d "$VAULT_PATH/上课记录/$folder" ]; then
    pass "Vault 分区存在：上课记录/$folder"
  else
    fail "Vault 分区缺失：上课记录/$folder"
  fi
done

if [ -d "$RECORD_DIR/sessions" ] && [ -d "$RECORD_DIR/logs" ]; then
  pass "录音与日志目录已就绪：$RECORD_DIR"
else
  fail "录音目录未就绪：$RECORD_DIR"
fi

if [ -x "$HOME/Applications/PhysicsClassAudio.app/Contents/MacOS/PhysicsClassAudio" ]; then
  pass "原生音频采集组件已安装"
else
  fail "PhysicsClassAudio 未安装"
fi

if [ -n "$WHISPER_CLI" ] && [ -x "$WHISPER_CLI" ]; then
  pass "Whisper CLI 已安装：$WHISPER_CLI"
else
  fail "Whisper CLI 未安装或路径无效：$WHISPER_CLI"
fi

if [ -s "$WHISPER_MODEL" ]; then
  pass "Whisper 模型已就绪：$WHISPER_MODEL"
else
  fail "Whisper 模型缺失：$WHISPER_MODEL"
fi

if command -v launchctl >/dev/null 2>&1; then
  launchctl print "gui/$(id -u)/com.physicsclass.meeting-watcher" >/dev/null 2>&1 \
    && pass "会议监听后台任务已运行" \
    || fail "会议监听后台任务未运行"
  launchctl print "gui/$(id -u)/com.physicsclass.preclass-scan" >/dev/null 2>&1 \
    && pass "课前扫描后台任务已注册" \
    || fail "课前扫描后台任务未注册"
else
  fail "当前系统没有 launchctl；class-pipeline 需要 macOS"
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "READY: 安装、配置、后台监听和转写依赖均已就绪"
  exit 0
fi

echo "NOT READY: 请运行 bash $SKILL_DIR/setup.sh --auto 修复，或查看上面的失败项"
exit 1
