#!/usr/bin/env python3
"""Select a class event for a provisional or transcript-aware final lesson reference."""
from __future__ import annotations

import re
import sys
from datetime import datetime


def parse_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.now().astimezone().tzinfo)
    return parsed


def _parse_row(raw: str):
    parts = raw.rstrip("\n").split("\t")
    if len(parts) < 2:
        return None
    # Current Swift format: title, start, end, event_id, notes
    try:
        parse_datetime(parts[1].strip())
    except ValueError:
        pass
    else:
        end = None
        if len(parts) >= 3:
            try:
                end = parse_datetime(parts[2].strip())
            except ValueError:
                end = None
        return parts[0].strip(), parse_datetime(parts[1].strip()), end

    # AppleScript fallback: calendar, title, start, notes
    if len(parts) >= 3:
        try:
            start = parse_datetime(parts[2].strip())
        except ValueError:
            return None
        return parts[1].strip(), start, None
    return None


def select_event(
    lines: list[str],
    keyword: str,
    reference: datetime,
    max_delta: int,
    mode: str = "legacy",
    min_margin_seconds: int = 600,
):
    pattern = re.compile(rf"^(.*?)\s*{re.escape(keyword)}\s*[-－—]\s*(.+)$", re.IGNORECASE)
    candidates = []
    for raw in lines:
        row = _parse_row(raw)
        if row is None:
            continue
        summary, start, _end = row
        match = pattern.search(summary)
        if not match:
            continue
        delta = abs(int((start - reference).total_seconds()))
        if delta > max_delta:
            continue
        system = match.group(1).strip() or "未命名体系"
        student = match.group(2).strip()
        if student:
            candidates.append((delta, system, student))

    if not candidates:
        return None
    candidates.sort(key=lambda item: item[0])

    if mode == "provisional":
        # A provisional match is written before we know when meaningful class
        # dialogue actually starts. If two lessons are packed into the same
        # nearby window, do not lock either student yet; final matching will use
        # the first meaningful transcript timestamp after class ends.
        if len(candidates) > 1:
            return None
    else:
        if len(candidates) > 1 and candidates[1][0] - candidates[0][0] < min_margin_seconds:
            return None
    return candidates[0]


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print("Usage: select_calendar_event.py <keyword> <reference_iso> <max_delta_seconds> [legacy|provisional|final]", file=sys.stderr)
        return 2
    keyword, reference_text, max_delta_text = sys.argv[1:4]
    mode = sys.argv[4] if len(sys.argv) == 5 else "legacy"
    if mode not in {"legacy", "provisional", "final"}:
        print(f"invalid mode: {mode}", file=sys.stderr)
        return 2
    try:
        reference = parse_datetime(reference_text)
        max_delta = int(max_delta_text)
    except ValueError as exc:
        print(f"invalid selector argument: {exc}", file=sys.stderr)
        return 2
    best = select_event(sys.stdin.readlines(), keyword, reference, max_delta, mode=mode)
    if best is None:
        return 1
    print(f"{best[1]}|{best[2]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
