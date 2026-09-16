#!/bin/bash
# setup_audio.sh — install BlackHole and manage the existing multi-output device used for meeting recording.
# Usage:
#   bash setup_audio.sh install [playback device]  # install + create multi-output once
#   bash setup_audio.sh check [playback device]    # verify audio chain is ready
#   bash setup_audio.sh activate [playback device] # select existing output before class
#   bash setup_audio.sh ensure [playback device]   # rebuild this pipeline's multi-output device
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
  local playback="${1:-}"
  if [ -z "$playback" ] && ! command -v SwitchAudioSource >/dev/null 2>&1; then
    log "Installing SwitchAudioSource..."
    brew install switchaudio-osx >/dev/null 2>&1 || true
  fi
  if [ -z "$playback" ] && command -v SwitchAudioSource >/dev/null 2>&1; then
    playback=$(SwitchAudioSource -c -t output 2>/dev/null || true)
  fi
  if [ -z "$playback" ] || [ "$playback" = "$MO_NAME" ]; then
    log "ERROR: no physical playback device was supplied for '$MO_NAME'"
    return 1
  fi
  log "Binding '$MO_NAME' to '$playback' and BlackHole..."
  if swift "$SWIFT_SRC" ensure "$MO_NAME" "$playback"; then
    return 0
  fi
  log "ERROR: unable to build the multi-output device for '$playback'"
  return 1
}

device_exists() {
  system_profiler SPAudioDataType 2>/dev/null | grep -qi "$1"
}

activate() {
  local playback="${1:-${PHYSICSCLASS_PLAYBACK_DEVICE:-}}"
  if ! command -v SwitchAudioSource >/dev/null 2>&1; then
    log "Installing SwitchAudioSource..."
    brew install switchaudio-osx >/dev/null 2>&1 || true
  fi
  if command -v SwitchAudioSource >/dev/null 2>&1; then
    # Preserve the exact device selected before class; never guess on restore.
    SwitchAudioSource -c -t output > "$STATE_FILE"
    if ! device_exists "$MO_NAME"; then
      log "ERROR: '$MO_NAME' is missing; refusing to create it during class startup"
      log "Run setup_audio.sh install once if this device is intentionally absent"
      return 1
    fi
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
  local playback="${1:-${PHYSICSCLASS_PLAYBACK_DEVICE:-}}"
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
  if [ -n "$playback" ]; then
    if device_exists "$playback"; then
      log "OK: preferred playback device '$playback' exists"
    else
      log "MISSING: preferred playback device '$playback'"
      ok=0
    fi
  fi
  [ "$ok" = 1 ]
}

install_audio() {
  local playback="${1:-${PHYSICSCLASS_PLAYBACK_DEVICE:-}}"
  install_blackhole
  local rc=$?
  if [ "$rc" = 2 ]; then
    log "Skipping multi-output device until BlackHole is loaded (after reboot)."
    log "After reboot run: bash $(cd "$(dirname "$0")" && pwd)/setup_audio.sh install"
    return 0
  fi
  [ "$rc" = 0 ] || return "$rc"
  if device_exists "$MO_NAME"; then
    log "Multi-output device '$MO_NAME' already exists; leaving its membership unchanged."
    return 0
  fi
  create_multi_output "$playback"
}

case "${1:-install}" in
  install) install_audio "${2:-}" ;;
  check) check "${2:-}" ;;
  ensure) create_multi_output "${2:-}" ;;
  activate) activate "${2:-}" ;;
  restore) restore ;;
  *) echo "Usage: $0 {install|check|ensure|activate|restore} [playback device]"; exit 1 ;;
esac
