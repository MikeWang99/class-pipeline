#!/usr/bin/env python3
"""Validate the separate system-audio and microphone channels in a recording.

New recordings store BlackHole in the left channel and the physical microphone
in the right channel. A normal file duration cannot prove that either source
was present, so this check gates expensive transcription when an input was
silent or disconnected.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


SILENT_RMS_DB = -58.0


def probe_channels(audio: Path) -> int:
    output = subprocess.check_output(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
         "stream=channels", "-of", "default=noprint_wrappers=1:nokey=1", str(audio)],
        text=True,
    ).strip()
    return int(output)


def rms_for_channel(audio: Path, channel: int) -> float | None:
    command = [
        "ffmpeg", "-nostdin", "-hide_banner", "-i", str(audio), "-filter:a",
        f"pan=mono|c0=c{channel},volumedetect", "-f", "null", "-",
    ]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                            errors="replace")
    match = re.findall(r"mean_volume:\s*(-?(?:inf|\d+(?:\.\d+)?))\s*dB", result.stderr)
    if not match:
        return None
    value = match[-1]
    return float("-inf") if value == "-inf" else float(value)


def assess(audio: Path) -> dict[str, object]:
    channels = probe_channels(audio)
    result: dict[str, object] = {
        "audio": str(audio),
        "channels": channels,
        "threshold_rms_db": SILENT_RMS_DB,
    }
    if channels < 2:
        result.update({
            "status": "legacy_mixed_audio",
            "action": "allow_transcription_with_existing_quality_gate",
        })
        return result

    system_rms = rms_for_channel(audio, 0)
    microphone_rms = rms_for_channel(audio, 1)
    result.update({"system_rms_db": system_rms, "microphone_rms_db": microphone_rms})
    system_missing = system_rms is None or system_rms <= SILENT_RMS_DB
    mic_missing = microphone_rms is None or microphone_rms <= SILENT_RMS_DB
    if system_missing and mic_missing:
        status = "no_capturable_audio"
    elif system_missing:
        status = "system_audio_missing"
    elif mic_missing:
        status = "microphone_audio_missing"
    else:
        status = "healthy"
    result["status"] = status
    result["action"] = "transcribe" if status == "healthy" else "hold_for_audio_repair"
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.audio.is_file():
        parser.error(f"audio file not found: {args.audio}")
    report = assess(args.audio)
    rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    return 0 if report["status"] in {"healthy", "legacy_mixed_audio"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
