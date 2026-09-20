#!/usr/bin/env python3
"""Build machine-readable context for one post-class feedback task.

This file does not generate feedback. It records which longitudinal and current-lesson
sources the writing model must read before making claims about progress, weaknesses, or
next steps.
"""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path


def parse_frontmatter(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines or lines[0] != "---":
        return {}
    data: dict[str, str] = {}
    for line in lines[1:]:
        if line == "---":
            break
        if ":" in line:
            key, value = line.split(":", 1)
            data[key.strip()] = value.strip()
    return data


def dt_from_session(session_dir: Path) -> datetime:
    return datetime.strptime(session_dir.name, "%Y-%m-%d_%H%M%S")


def event_dt(path: Path) -> datetime | None:
    fm = parse_frontmatter(path)
    value = fm.get("event_start")
    if value:
        try:
            return datetime.fromisoformat(value).replace(tzinfo=None)
        except ValueError:
            pass
    m = re.match(r"^(\d{4}-\d{2}-\d{2})(?:\s|-)", path.name)
    if m:
        try:
            return datetime.fromisoformat(m.group(1))
        except ValueError:
            pass
    return None


def dated_files(folder: Path, student: str, contains: str | None = None) -> list[Path]:
    if not folder.is_dir():
        return []
    hits = []
    for p in folder.glob("*.md"):
        if student.lower() not in p.name.lower():
            continue
        if contains and contains.lower() not in p.name.lower():
            continue
        hits.append(p)
    return sorted(hits, key=lambda p: (event_dt(p) or datetime.min, p.name))


def nearest_prev_next(paths: list[Path], current: datetime) -> tuple[Path | None, Path | None]:
    prev = None
    nxt = None
    for p in paths:
        dt = event_dt(p)
        if dt is None:
            continue
        if dt < current:
            prev = p
        elif dt > current and nxt is None:
            nxt = p
    return prev, nxt


def latest_previous(paths: list[Path], current_date: str, current_name: str | None = None) -> Path | None:
    eligible = []
    for p in paths:
        if current_name and p.name == current_name:
            continue
        dt = event_dt(p)
        if dt is None:
            continue
        if dt.date().isoformat() <= current_date:
            eligible.append((dt, p))
    return eligible[-1][1] if eligible else None


def build(session_dir: Path, vault: Path, system: str, student: str) -> dict:
    current = dt_from_session(session_dir)
    day = current.date().isoformat()
    root = vault / "上课记录"
    profile = root / "学生档案" / f"{student}.md"
    feedback_dir = root / "课后反馈"
    transcript_dir = root / "课堂文字稿"
    prep_dir = root / "备课内容"

    feedbacks = dated_files(feedback_dir, student, "feedback")
    current_feedback_name = f"{day}-{student}-feedback.md"
    previous_feedback = latest_previous(feedbacks, day, current_feedback_name)

    transcripts = dated_files(transcript_dir, student, "Class-")
    current_transcript_name = f"{day} {system} Class-{student}.md"
    previous_transcript = latest_previous(transcripts, day, current_transcript_name)

    preps = dated_files(prep_dir, student, "Class-")
    previous_prep, next_prep = nearest_prev_next(preps, current)
    current_prep = None
    for p in preps:
        dt = event_dt(p)
        if p.name.startswith(f"{day} {system} Class-{student}"):
            current_prep = p
            break
        if dt and dt.date() == current.date() and abs((dt - current).total_seconds()) <= 7200:
            current_prep = p

    candidates = session_dir / "calendar_candidates.json"
    payload = {
        "schema_version": "2.2",
        "student": student,
        "system": system,
        "session_dir": str(session_dir),
        "session_start": current.isoformat(),
        "sources": {
            "current_transcript": str(session_dir / "transcript.txt"),
            "current_profile": str(profile) if profile.is_file() else None,
            "previous_feedback": str(previous_feedback) if previous_feedback else None,
            "previous_transcript": str(previous_transcript) if previous_transcript else None,
            "current_prep": str(current_prep) if current_prep else None,
            "previous_prep": str(previous_prep) if previous_prep else None,
            "next_prep": str(next_prep) if next_prep else None,
            "calendar_candidates": str(candidates) if candidates.is_file() else None,
        },
        "generation_requirements": {
            "must_read_current_transcript": True,
            "must_read_current_profile_when_present": True,
            "must_read_previous_feedback_when_present": True,
            "must_read_previous_transcript_when_present": True,
            "must_use_current_progress_for_diagnosis": True,
            "priority_issue_requires_current_lesson_evidence": True,
            "historical_issue_without_current_evidence_stays_internal": True,
            "next_lesson_plan_uses_current_progress_and_current_lesson": True,
        },
    }
    return payload


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("session_dir", type=Path)
    p.add_argument("vault_path", type=Path)
    p.add_argument("system")
    p.add_argument("student")
    p.add_argument("--output", type=Path)
    args = p.parse_args()
    payload = build(args.session_dir, args.vault_path, args.system, args.student)
    out = args.output or (args.session_dir / "feedback_context.json")
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
