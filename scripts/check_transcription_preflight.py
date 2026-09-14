#!/usr/bin/env python3
"""Sample a long recording before committing to a full local transcription."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from transcribe_audio import audio_channels, conversion_filter, probe_duration, transcribe_local_file


SAMPLE_SECONDS = 30
MIN_DURATION_SECONDS = 600
HALLUCINATION_MARKERS = ("字幕志愿者", "谢谢观看", "next video", "다음 영상")


def normalize(text: str) -> str:
    return re.sub(r"\W+", "", text).lower()


def sample_offsets(duration: float) -> list[int]:
    if duration < MIN_DURATION_SECONDS:
        return []
    latest_start = max(0, int(duration - SAMPLE_SECONDS))
    return sorted({min(latest_start, int(duration * fraction)) for fraction in (0.25, 0.5, 0.75)})


def assess_segments(segments: list[str]) -> dict[str, object]:
    normalized = [normalize(text) for text in segments if normalize(text)]
    counts = Counter(normalized)
    dominant_ratio = max(counts.values(), default=0) / len(normalized) if normalized else 1.0
    repeated_ratio = (
        sum(count for count in counts.values() if count > 1) / len(normalized)
        if normalized else 1.0
    )
    marker_count = sum(
        marker.lower() in text.lower() for text in segments for marker in HALLUCINATION_MARKERS
    )
    unusable = (
        len(normalized) < 3
        or dominant_ratio >= 0.5
        or repeated_ratio >= 0.65
        or marker_count >= 2
    )
    return {
        "status": "unusable" if unusable else "usable",
        "segment_count": len(normalized),
        "unique_segment_count": len(counts),
        "dominant_segment_ratio": round(dominant_ratio, 3),
        "repeated_segment_ratio": round(repeated_ratio, 3),
        "hallucination_marker_count": marker_count,
    }


def run_preflight(audio: Path) -> dict[str, object]:
    duration = probe_duration(str(audio))
    offsets = sample_offsets(duration)
    if not offsets:
        return {"status": "skipped_short_recording", "duration_seconds": duration, "samples": []}
    channels = audio_channels(str(audio))
    all_segments: list[str] = []
    with tempfile.TemporaryDirectory(prefix="physics-preflight-") as temp:
        for index, offset in enumerate(offsets):
            sample = Path(temp) / f"sample-{index}.wav"
            subprocess.run([
                "ffmpeg", "-nostdin", "-y", "-v", "error", "-ss", str(offset),
                "-t", str(SAMPLE_SECONDS), "-i", str(audio), "-af", conversion_filter(channels),
                "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(sample),
            ], check=True)
            result = transcribe_local_file(str(sample), "auto", str(Path(temp) / f"result-{index}"))
            all_segments.extend(
                str(item.get("text", "")).strip()
                for item in result.get("transcription", [])
                if str(item.get("text", "")).strip()
            )
    report = assess_segments(all_segments)
    report.update({"duration_seconds": duration, "sample_offsets_seconds": offsets})
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.audio.is_file():
        parser.error(f"audio file not found: {args.audio}")
    report = run_preflight(args.audio)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 1 if report["status"] == "unusable" else 0


if __name__ == "__main__":
    raise SystemExit(main())
