#!/usr/bin/env python3
"""Resolve a recorded session to a calendar class only after transcript evidence exists.

The selector is intentionally conservative.  Before transcription it returns no match so
meeting_watcher cannot permanently bind a session merely because a meeting window opened
near a scheduled class.  After transcription it compares the *active transcript interval*
with calendar event intervals.  Ambiguous matches are queued for AI/human reconciliation
instead of attaching feedback to the wrong student.
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

PLACEHOLDER_RE = re.compile(
    r"doorbell rings|door opens|speaking in foreign language|multiple voices|no audible dialogue|录音.*失败|未生成.*文字稿",
    re.IGNORECASE,
)
TS_RE = re.compile(
    r"^\[(?P<s>(?:(?:\d{1,2}):)?\d{1,2}:\d{2})(?:\s*-\s*(?P<e>(?:(?:\d{1,2}):)?\d{1,2}:\d{2}))?\]"
)


def parse_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.now().astimezone().tzinfo)
    return parsed


def parse_offset(value: str) -> int:
    parts = [int(x) for x in value.split(":")]
    if len(parts) == 2:
        mm, ss = parts
        return mm * 60 + ss
    if len(parts) == 3:
        hh, mm, ss = parts
        return hh * 3600 + mm * 60 + ss
    raise ValueError(value)


def session_start(session_dir: Path) -> datetime:
    base = session_dir.name
    parsed = datetime.strptime(base, "%Y-%m-%d_%H%M%S")
    return parsed.replace(tzinfo=datetime.now().astimezone().tzinfo)


def recording_end(session_dir: Path, start: datetime) -> datetime:
    marker = session_dir / "recording_stopped_at.txt"
    if marker.is_file():
        first = marker.read_text(encoding="utf-8", errors="replace").split()
        if first:
            try:
                return datetime.fromtimestamp(int(first[0]), tz=start.tzinfo)
            except (ValueError, OSError):
                pass
    return start + timedelta(hours=1)


def active_transcript_window(session_dir: Path) -> tuple[datetime, datetime] | None:
    transcript = session_dir / "transcript.txt"
    if not transcript.is_file():
        return None
    start = session_start(session_dir)
    points: list[tuple[int, int]] = []
    for raw in transcript.read_text(encoding="utf-8", errors="replace").splitlines():
        m = TS_RE.match(raw.strip())
        if not m:
            continue
        body = raw[m.end():].strip()
        if not body or PLACEHOLDER_RE.search(body):
            continue
        try:
            s = parse_offset(m.group("s"))
            e = parse_offset(m.group("e")) if m.group("e") else s
        except ValueError:
            continue
        points.append((s, max(s, e)))
    # A single accidental utterance while waiting for a no-show should not be
    # enough to bind a student. Require at least three meaningful timestamped lines.
    if len(points) < 3:
        return start, recording_end(session_dir, start)
    return start + timedelta(seconds=points[0][0]), start + timedelta(seconds=points[-1][1])


def parse_event_row(raw: str, keyword: str):
    parts = raw.rstrip("\n").split("\t")
    if len(parts) < 2:
        return None

    # Supported shapes:
    # Swift v2: title, start, end, notes
    # AppleScript v2: calendar, title, start, end, notes
    # Legacy Swift: title, start, notes
    # Legacy AppleScript: calendar, title, start, notes
    title_idx = 0
    start_idx = 1
    try:
        parse_datetime(parts[start_idx].strip())
    except ValueError:
        if len(parts) < 3:
            return None
        title_idx, start_idx = 1, 2
        try:
            parse_datetime(parts[start_idx].strip())
        except ValueError:
            return None

    summary = parts[title_idx].strip()
    pattern = re.compile(rf"^(.*?)\s*{re.escape(keyword)}\s*[-－—]\s*(.+)$", re.IGNORECASE)
    match = pattern.search(summary)
    if not match:
        return None
    event_start = parse_datetime(parts[start_idx].strip())
    event_end = None
    if len(parts) > start_idx + 1:
        try:
            event_end = parse_datetime(parts[start_idx + 1].strip())
        except ValueError:
            event_end = None
    return match.group(1).strip() or "未命名体系", match.group(2).strip(), event_start, event_end


def resolve_event(
    lines: list[str],
    keyword: str,
    active_start: datetime,
    active_end: datetime,
    max_delta: int,
    ambiguity_margin: int = 300,
):
    candidates: list[dict] = []
    for raw in lines:
        parsed = parse_event_row(raw, keyword)
        if not parsed:
            continue
        system, student, event_start, event_end = parsed
        delta = abs(int((event_start - active_start).total_seconds()))
        overlap = 0
        if event_end and event_end > event_start:
            overlap = max(0, int((min(event_end, active_end) - max(event_start, active_start)).total_seconds()))
        if overlap <= 0 and delta > max_delta:
            continue
        candidates.append({
            "system": system,
            "student": student,
            "event_start": event_start.isoformat(),
            "event_end": event_end.isoformat() if event_end else None,
            "overlap_seconds": overlap,
            "start_delta_seconds": delta,
        })

    if not candidates:
        return "none", None, []

    overlapping = [c for c in candidates if c["overlap_seconds"] > 0]
    if overlapping:
        ranked = sorted(overlapping, key=lambda c: (-c["overlap_seconds"], c["start_delta_seconds"], c["event_start"]))
        if len(ranked) > 1 and ranked[0]["overlap_seconds"] - ranked[1]["overlap_seconds"] < ambiguity_margin:
            return "ambiguous", None, sorted(candidates, key=lambda c: (c["event_start"], c["student"].lower()))
        return "matched", ranked[0], sorted(candidates, key=lambda c: (c["event_start"], c["student"].lower()))

    ranked = sorted(candidates, key=lambda c: (c["start_delta_seconds"], c["event_start"]))
    if len(ranked) > 1 and ranked[1]["start_delta_seconds"] - ranked[0]["start_delta_seconds"] < ambiguity_margin:
        return "ambiguous", None, sorted(candidates, key=lambda c: (c["event_start"], c["student"].lower()))
    return "matched", ranked[0], sorted(candidates, key=lambda c: (c["event_start"], c["student"].lower()))


def write_candidates(session_dir: Path, status: str, active_start: datetime, active_end: datetime, candidates: list[dict]) -> None:
    payload = {
        "schema_version": "2.2",
        "status": status,
        "active_start": active_start.isoformat(),
        "active_end": active_end.isoformat(),
        "candidates": candidates,
    }
    (session_dir / "calendar_candidates.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print(
            "Usage: select_calendar_event.py <keyword> <session_dir> <max_delta_seconds> [ambiguity_margin_seconds]",
            file=sys.stderr,
        )
        return 2
    keyword = sys.argv[1]
    session_dir = Path(sys.argv[2])
    try:
        max_delta = int(sys.argv[3])
        ambiguity_margin = int(sys.argv[4]) if len(sys.argv) == 5 else 300
    except ValueError:
        return 2

    window = active_transcript_window(session_dir)
    if window is None:
        # Deliberately refuse pre-transcript identity locking.
        start = session_start(session_dir)
        end = recording_end(session_dir, start)
        write_candidates(session_dir, "deferred_until_transcript", start, end, [])
        return 4

    active_start, active_end = window
    status, match, candidates = resolve_event(
        sys.stdin.readlines(), keyword, active_start, active_end, max_delta, ambiguity_margin
    )
    write_candidates(session_dir, status, active_start, active_end, candidates)
    if status == "matched" and match:
        print(f"{match['system']}|{match['student']}")
        return 0
    if status == "ambiguous":
        return 3
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
