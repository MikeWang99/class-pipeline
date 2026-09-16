#!/usr/bin/env python3
"""Validate captured audio without conflating "silence" with "capture failure".

New recordings store macOS system audio in the left channel and microphone audio
in the right channel.  The capture gate answers a narrow question: did each
source carry a real signal?  A missing side is degraded, not fatal, because the
remaining side may still contain recoverable lesson speech.

Exit codes:
    0  at least one useful signal exists; inspect ``action`` for degradation
    1  no capturable signal exists; hold for repair
"""
from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
from pathlib import Path

# Mean volume alone is a bad capture test for lessons with long quiet periods.
# Treat a channel as present when either sustained RMS or a meaningful peak
# exists.  Speech commonly has peaks far above -48 dB even when the whole-file
# mean is much lower.
SILENT_RMS_DB = -58.0
SILENT_PEAK_DB = -48.0


def probe_channels(audio: Path) -> int:
    output = subprocess.check_output(
        [
            "ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=channels",
            "-of", "default=noprint_wrappers=1:nokey=1", str(audio),
        ],
        text=True,
    ).strip()
    return int(output)


def _parse_db(value: str) -> float:
    return float("-inf") if value == "-inf" else float(value)


def volume_stats_for_channel(audio: Path, channel: int) -> dict[str, float | None]:
    command = [
        "ffmpeg", "-nostdin", "-hide_banner", "-i", str(audio), "-filter:a",
        f"pan=mono|c0=c{channel},volumedetect", "-f", "null", "-",
    ]
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    mean_match = re.findall(
        r"mean_volume:\s*(-?(?:inf|\d+(?:\.\d+)?))\s*dB", result.stderr
    )
    peak_match = re.findall(
        r"max_volume:\s*(-?(?:inf|\d+(?:\.\d+)?))\s*dB", result.stderr
    )
    return {
        "rms_db": _parse_db(mean_match[-1]) if mean_match else None,
        "peak_db": _parse_db(peak_match[-1]) if peak_match else None,
    }


def rms_for_channel(audio: Path, channel: int) -> float | None:
    """Compatibility helper retained for callers/tests that only need RMS."""
    return volume_stats_for_channel(audio, channel)["rms_db"]


def signal_present(stats: dict[str, float | None]) -> bool:
    rms = stats.get("rms_db")
    peak = stats.get("peak_db")
    rms_ok = rms is not None and math.isfinite(rms) and rms > SILENT_RMS_DB
    peak_ok = peak is not None and math.isfinite(peak) and peak > SILENT_PEAK_DB
    return rms_ok or peak_ok


def _source_report(name: str, stats: dict[str, float | None], present: bool) -> dict[str, object]:
    return {
        "source": name,
        "signal_present": present,
        "rms_db": stats.get("rms_db"),
        "peak_db": stats.get("peak_db"),
        "threshold_rms_db": SILENT_RMS_DB,
        "threshold_peak_db": SILENT_PEAK_DB,
    }


def assess(audio: Path, system_only: bool = False) -> dict[str, object]:
    channels = probe_channels(audio)
    result: dict[str, object] = {
        "audio": str(audio),
        "channels": channels,
        "threshold_rms_db": SILENT_RMS_DB,
        "threshold_peak_db": SILENT_PEAK_DB,
    }

    if system_only:
        system = volume_stats_for_channel(audio, 0)
        present = signal_present(system)
        result.update({
            "system_rms_db": system["rms_db"],
            "system_peak_db": system["peak_db"],
            "system_signal_present": present,
            "status": "healthy" if present else "system_audio_missing",
            "completeness": "complete" if present else "none",
            "action": "transcribe" if present else "hold_for_audio_repair",
        })
        return result

    if channels < 2:
        mixed = volume_stats_for_channel(audio, 0)
        present = signal_present(mixed)
        if not present:
            result.update({
                "mixed_rms_db": mixed["rms_db"],
                "mixed_peak_db": mixed["peak_db"],
                "mixed_signal_present": False,
                "status": "no_capturable_audio",
                "completeness": "none",
                "action": "hold_for_audio_repair",
            })
            return result
        result.update({
            "mixed_rms_db": mixed["rms_db"],
            "mixed_peak_db": mixed["peak_db"],
            "mixed_signal_present": True,
            "status": "legacy_mixed_audio",
            "completeness": "legacy",
            "action": "allow_transcription_with_existing_quality_gate",
        })
        return result

    system = volume_stats_for_channel(audio, 0)
    microphone = volume_stats_for_channel(audio, 1)
    system_present = signal_present(system)
    microphone_present = signal_present(microphone)

    result.update({
        "system_rms_db": system["rms_db"],
        "system_peak_db": system["peak_db"],
        "system_signal_present": system_present,
        "microphone_rms_db": microphone["rms_db"],
        "microphone_peak_db": microphone["peak_db"],
        "microphone_signal_present": microphone_present,
    })

    if system_present and microphone_present:
        status = "healthy"
        completeness = "complete"
        action = "transcribe"
    elif system_present:
        status = "microphone_audio_missing"
        completeness = "degraded"
        action = "transcribe_degraded"
    elif microphone_present:
        status = "system_audio_missing"
        completeness = "degraded"
        action = "transcribe_degraded"
    else:
        status = "no_capturable_audio"
        completeness = "none"
        action = "hold_for_audio_repair"

    result["status"] = status
    result["completeness"] = completeness
    result["action"] = action
    return result


def write_source_reports(output: Path, report: dict[str, object]) -> None:
    if int(report.get("channels", 0) or 0) < 2:
        return
    system_stats = {
        "rms_db": report.get("system_rms_db"),
        "peak_db": report.get("system_peak_db"),
    }
    microphone_stats = {
        "rms_db": report.get("microphone_rms_db"),
        "peak_db": report.get("microphone_peak_db"),
    }
    system_report = _source_report(
        "system_audio", system_stats, bool(report.get("system_signal_present"))
    )
    microphone_report = _source_report(
        "microphone", microphone_stats, bool(report.get("microphone_signal_present"))
    )
    (output.parent / "system_audio_health.json").write_text(
        json.dumps(system_report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (output.parent / "microphone_audio_health.json").write_text(
        json.dumps(microphone_report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--system-only", action="store_true")
    args = parser.parse_args()
    if not args.audio.is_file():
        parser.error(f"audio file not found: {args.audio}")

    report = assess(args.audio, system_only=args.system_only)
    rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
        if not args.system_only:
            write_source_reports(args.output, report)
    else:
        sys.stdout.write(rendered)

    status = str(report["status"])
    allowed = {
        "healthy",
        "legacy_mixed_audio",
        "system_audio_missing",
        "microphone_audio_missing",
    }
    if status in allowed and not (
        args.system_only and status == "system_audio_missing"
    ):
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
