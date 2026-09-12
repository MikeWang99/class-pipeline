#!/usr/bin/env python3
"""Select the closest class event from tab-separated EventKit output."""

from __future__ import annotations

import re
import sys
from datetime import datetime


def parse_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.now().astimezone().tzinfo)
    return parsed


def select_event(lines: list[str], keyword: str, reference: datetime, max_delta: int):
    pattern = re.compile(
        rf"^(.*?)\s*{re.escape(keyword)}\s*[-－—]\s*(.+)$", re.IGNORECASE
    )
    best = None

    for raw in lines:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) < 2:
            continue
        summary, start_text = parts[0].strip(), parts[1].strip()
        # Swift emits title, start, notes. The AppleScript fallback emits
        # calendar, title, start, notes. Accept both output shapes.
        if len(parts) >= 4:
            try:
                parse_datetime(start_text)
            except ValueError:
                try:
                    parse_datetime(parts[2].strip())
                except ValueError:
                    pass
                else:
                    summary, start_text = parts[1].strip(), parts[2].strip()
        match = pattern.search(summary)
        if not match:
            continue
        try:
            start = parse_datetime(start_text)
        except ValueError:
            continue

        delta = abs(int((start - reference).total_seconds()))
        if delta > max_delta:
            continue
        system = match.group(1).strip() or "未命名体系"
        student = match.group(2).strip()
        if student and (best is None or delta < best[0]):
            best = (delta, system, student)

    return best


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "Usage: select_calendar_event.py <keyword> <reference_iso> <max_delta_seconds>",
            file=sys.stderr,
        )
        return 2

    keyword, reference_text, max_delta_text = sys.argv[1:]
    try:
        reference = parse_datetime(reference_text)
        max_delta = int(max_delta_text)
    except ValueError as exc:
        print(f"invalid selector argument: {exc}", file=sys.stderr)
        return 2

    best = select_event(sys.stdin.readlines(), keyword, reference, max_delta)
    if best is None:
        return 1
    print(f"{best[1]}|{best[2]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
