#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from datetime import datetime, timedelta
from pathlib import Path

NOISE = re.compile(
    r"^(?:,?\s*)?(?:\(?doorbell rings\)?|\(?door opens\)?|\(?speaking in foreign language\)?|\(?multiple voices\)?|\[?\s*No Audible Dialogue\s*\]?|,?)$",
    re.IGNORECASE,
)
STAMP = re.compile(
    r"^\[(?P<start>\d{1,2}:\d{2}(?::\d{2})?)(?:\s*(?:-->|-|–|—)\s*(?P<end>\d{1,2}:\d{2}(?::\d{2})?))?\]\s*(?P<text>.*)$"
)


def seconds(value: str) -> int:
    parts = [int(x) for x in value.split(":")]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    raise ValueError(value)


def session_start(session: Path) -> datetime:
    marker = session / "recording_started_at.txt"
    if marker.is_file():
        first = marker.read_text(encoding="utf-8", errors="replace").splitlines()[0].split()[0]
        try:
            return datetime.fromtimestamp(int(first), tz=datetime.now().astimezone().tzinfo)
        except (ValueError, OSError):
            pass
    try:
        naive = datetime.strptime(session.name, "%Y-%m-%d_%H%M%S")
    except ValueError as exc:
        raise ValueError("session directory must be YYYY-MM-DD_HHMMSS or include recording_started_at.txt") from exc
    return naive.replace(tzinfo=datetime.now().astimezone().tzinfo)


def first_meaningful_offset(transcript: Path) -> int | None:
    if not transcript.is_file():
        return None
    for raw in transcript.read_text(encoding="utf-8", errors="replace").splitlines():
        m = STAMP.match(raw.strip())
        if not m:
            continue
        text = m.group("text").strip()
        if not text or NOISE.match(text):
            continue
        offset = seconds(m.group("start"))
        if 0 <= offset <= 8 * 3600:
            return offset
    return None


def derive(session: Path) -> datetime:
    start = session_start(session)
    offset = first_meaningful_offset(session / "transcript.txt")
    return start + timedelta(seconds=offset or 0)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("session", type=Path)
    args = p.parse_args()
    print(derive(args.session).isoformat(timespec="seconds"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
