#!/bin/bash
# uninstall.sh — remove all background jobs and skill links created by setup.sh.
# Keeps: recordings/data dir and Vault notes (delete manually if wanted).
set -u

PLIST_SCAN="$HOME/Library/LaunchAgents/com.physicsclass.preclass-scan.plist"
PLIST_WATCH="$HOME/Library/LaunchAgents/com.physicsclass.meeting-watcher.plist"

echo "==> 移除 launchd 任务"
for p in "$PLIST_SCAN" "$PLIST_WATCH"; do
  if [ -f "$p" ]; then
    launchctl unload "$p" 2>/dev/null
    rm -f "$p"
    echo "  removed: $p"
  fi
done

echo "==> 移除 skill 链接"
for dest in "$HOME/.qoder/skills/physics-class-pipeline" "$HOME/.codex/skills/physics-class-pipeline"; do
  if [ -L "$dest" ]; then rm "$dest"; echo "  removed: $dest"; fi
done

echo "==> 移除后台应用"
pkill -f "physics-class-pipeline/scripts/meeting_watcher.sh" 2>/dev/null
for app in "$HOME/Applications/PhysicsClassWatcher.app" "$HOME/Applications/PhysicsClassScanner.app" "$HOME/Applications/PhysicsClassAudio.app"; do
  if [ -d "$app" ]; then rm -rf "$app"; echo "  removed: $app"; fi
done

echo
echo "完成。以下内容未删除（如需彻底清理请手动处理）："
echo "  - 录音与文字稿目录 ~/physics-class-pipeline-data"
echo "  - Obsidian Vault 中的「上课记录」笔记"
