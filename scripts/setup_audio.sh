#!/bin/bash
# setup_audio.sh — install BlackHole and create the multi-output device used for meeting recording.
# Usage:
#   bash setup_audio.sh install   # install BlackHole + create multi-output device
#   bash setup_audio.sh check     # verify audio chain is ready
#   bash setup_audio.sh activate  # set system output to the multi-output device (before class)
#   bash setup_audio.sh restore   # set system output back to the built-in/default device
set -u

BH_NAME="BlackHole 2ch"
MO_NAME="PhysicsClass Multi-Output"
SWIFT_SRC="$(cd "$(dirname "$0")" && pwd)/create_multi_output.swift"
STATE_FILE="${TMPDIR:-/tmp}/physics-class-pipeline-output-device.txt"

log() { echo "[audio] $*"; }

has_blackhole() {
  system_profiler SPAudioDataType 2>/dev/null | grep -qi "blackhole"
}

# installed on disk but driver not loaded yet (needs reboot)
blackhole_installed() {
  [ -d "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" ] \
    || pkgutil --pkgs 2>/dev/null | grep -qi "blackhole"
}

install_blackhole() {
  if has_blackhole; then
    log "BlackHole already installed."
    return 0
  fi
  if blackhole_installed; then
    log "BlackHole is installed but not loaded yet — REBOOT your Mac to activate it."
    return 2
  fi
  log "Installing BlackHole 2ch via Homebrew (may ask for your password)..."
  if ! brew install --cask blackhole-2ch; then
    log "ERROR: brew install failed. Install manually: brew install --cask blackhole-2ch"
    return 1
  fi
  # give the audio driver a moment to register
  sleep 3
  if has_blackhole; then
    log "BlackHole installed."
  else
    log "BlackHole installed but not visible yet — REBOOT your Mac to activate it."
    return 2
  fi
}

create_multi_output() {
  if system_profiler SPAudioDataType 2>/dev/null | grep -qi "$MO_NAME"; then
    log "Multi-output device '$MO_NAME' already exists."
    return 0
  fi
  log "Trying to create multi-output device '$MO_NAME' automatically..."
  if swift "$SWIFT_SRC" "$MO_NAME" >/dev/null 2>&1; then
    osascript -e 'do shell script "killall coreaudiod" with administrator privileges' >/dev/null 2>&1 || true
    sleep 5
    if device_exists "$MO_NAME"; then
      log "Multi-output device '$MO_NAME' is now active."
      return 0
    fi
  fi
  log "Automatic creation not supported on this macOS version. Two alternatives:"
  log "  A) (one-time, 30s) Open 'Audio MIDI Setup' (音频 MIDI 设置) -> '+' ->"
  log "     Create Multi-Output Device -> tick your speakers + 'BlackHole 2ch' ->"
  log "     right-click rename to: $MO_NAME"
  log "  B) In your meeting app (Zoom/TencentMeeting), set the SPEAKER/扬声器 to"
  log "     'BlackHole 2ch' — student audio then flows straight into the recording."
  return 0   # non-blocking: recording still works with the mic
}

device_exists() {
  system_profiler SPAudioDataType 2>/dev/null | grep -qi "$1"
}

activate() {
  if ! command -v SwitchAudioSource >/dev/null 2>&1; then
    log "Installing SwitchAudioSource..."
    brew install switchaudio-osx >/dev/null 2>&1 || true
  fi
  if command -v SwitchAudioSource >/dev/null 2>&1 && device_exists "$MO_NAME"; then
    # Preserve the exact device selected before class; never guess on restore.
    SwitchAudioSource -c -t output > "$STATE_FILE"
    SwitchAudioSource -s "$MO_NAME" -t output && log "System output -> $MO_NAME"
  else
    log "ERROR: cannot switch output (missing SwitchAudioSource or device). Set manually in System Settings -> Sound."
    return 1
  fi
}

restore() {
  if command -v SwitchAudioSource >/dev/null 2>&1; then
    local dev
    dev=$(cat "$STATE_FILE" 2>/dev/null || true)
    if [ -z "$dev" ] || ! device_exists "$dev"; then
      # Compatibility fallback for sessions started before state tracking.
      dev=$(SwitchAudioSource -a -t output | grep -vi "blackhole" | grep -vi "multi-output" | grep -vi "aggregate" | head -1)
    fi
    if [ -n "$dev" ]; then
      SwitchAudioSource -s "$dev" -t output && log "System output restored -> $dev"
    fi
    unlink "$STATE_FILE" 2>/dev/null || true
  fi
}

check() {
  local ok=1
  if has_blackhole; then log "OK: BlackHole visible"; else log "MISSING: BlackHole"; ok=0; fi
  if device_exists "$MO_NAME"; then log "OK: $MO_NAME exists"; else log "MISSING: $MO_NAME"; ok=0; fi
  if command -v ffmpeg >/dev/null 2>&1; then log "OK: ffmpeg"; else log "MISSING: ffmpeg"; ok=0; fi
  # can we open BlackHole as input?
  if ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | grep -qi "blackhole"; then
    log "OK: BlackHole listable by ffmpeg"
  else
    log "WARNING: ffmpeg does not list BlackHole yet"
  fi
  [ "$ok" = 1 ]
}

install_audio() {
  install_blackhole
  local rc=$?
  if [ "$rc" = 2 ]; then
    log "Skipping multi-output device until BlackHole is loaded (after reboot)."
    log "After reboot run: bash $(cd "$(dirname "$0")" && pwd)/setup_audio.sh install"
    return 0
  fi
  [ "$rc" = 0 ] || return "$rc"
  create_multi_output
}

case "${1:-install}" in
  install) install_audio ;;
  check) check ;;
  activate) activate ;;
  restore) restore ;;
  *) echo "Usage: $0 {install|check|activate|restore}"; exit 1 ;;
esac
