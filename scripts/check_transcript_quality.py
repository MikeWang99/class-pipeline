#!/usr/bin/env python3
"""Detect common Whisper hallucination patterns before lesson analysis."""
from __future__ import annotations

import json
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path


MEDIA_HALLUCINATION_MARKERS = (
    "字幕志愿者",
    "谢谢观看",
    "下次视频",
    "next video",
    "다음 영상",
    "감사합니다",
)


def normalize(text: str) -> str:
    return re.sub(r"\W+", "", unicodedata.normalize("NFKC", text).lower())


def load_segments(path: Path) -> list[str]:
    json_path = path.with_suffix(".json")
    if json_path.is_file():
        try:
            data = json.loads(json_path.read_text(encoding="utf-8"))
            return [str(item.get("text", "")).strip() for item in data if item.get("text", "").strip()]
        except (OSError, json.JSONDecodeError):
            pass
    segments = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        text = re.sub(r"^\[[^]]+\]\s*", "", line).strip()
        if text:
            segments.append(text)
    return segments


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: check_transcript_quality.py TRANSCRIPT", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        return 2
    segments = load_segments(path)
    if len(segments) < 3:
        print("unusable")
        return 0

    normalized = [normalize(text) for text in segments]
    counts = Counter(item for item in normalized if item)
    repeated_ratio = sum(count for count in counts.values() if count > 1) / len(normalized)
    marker_count = sum(
        sum(marker.lower() in text.lower() for marker in MEDIA_HALLUCINATION_MARKERS)
        for text in segments
    )

    if marker_count >= 2 or (len(segments) >= 20 and repeated_ratio >= 0.30):
        print("unusable")
    else:
        print("usable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
