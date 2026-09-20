#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

CURRENT_STATUSES = {"new", "repeated", "improving", "resolved", "not_observed"}


def _nonempty(value) -> bool:
    return isinstance(value, str) and bool(value.strip())


def validate(path: Path, expected_student: str | None = None) -> list[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    if data.get("schema_version") != "2.2":
        errors.append("schema_version must be 2.2")

    identity = data.get("identity")
    if not isinstance(identity, dict):
        errors.append("identity must be an object")
        identity = {}
    if identity.get("status") != "confirmed":
        errors.append("identity.status must be confirmed before feedback generation")
    student = str(identity.get("student") or "").strip()
    if not student:
        errors.append("identity.student is required")
    if expected_student and student.casefold() != expected_student.strip().casefold():
        errors.append(f"identity.student {student!r} does not match expected student {expected_student!r}")
    if not _nonempty(identity.get("match_basis")):
        errors.append("identity.match_basis is required")

    sources = data.get("sources")
    if not isinstance(sources, dict):
        errors.append("sources must be an object")
        sources = {}
    for key in ("transcript", "current_profile"):
        item = sources.get(key)
        if not isinstance(item, dict):
            errors.append(f"sources.{key} must be an object")
            continue
        if item.get("read_complete") is not True:
            errors.append(f"sources.{key}.read_complete must be true")
        if not _nonempty(item.get("path")):
            errors.append(f"sources.{key}.path is required")
    prev = sources.get("previous_feedback")
    if isinstance(prev, dict) and prev.get("path") and prev.get("read_complete") is not True:
        errors.append("sources.previous_feedback.read_complete must be true when a previous feedback path exists")

    before = data.get("before_lesson")
    if not isinstance(before, dict):
        errors.append("before_lesson must be an object")
        before = {}
    if not _nonempty(before.get("current_progress")):
        errors.append("before_lesson.current_progress is required")
    if not isinstance(before.get("active_issues", []), list):
        errors.append("before_lesson.active_issues must be an array")

    lesson = data.get("this_lesson")
    if not isinstance(lesson, dict):
        errors.append("this_lesson must be an object")
        lesson = {}
    if not isinstance(lesson.get("actual_content"), list) or not lesson.get("actual_content"):
        errors.append("this_lesson.actual_content must be a non-empty array")
    for key in ("successes", "difficulties"):
        items = lesson.get(key, [])
        if not isinstance(items, list):
            errors.append(f"this_lesson.{key} must be an array")
            continue
        for i, item in enumerate(items):
            if not isinstance(item, dict):
                errors.append(f"this_lesson.{key}[{i}] must be an object")
                continue
            if not _nonempty(item.get("claim")):
                errors.append(f"this_lesson.{key}[{i}].claim is required")
            evidence = item.get("evidence")
            if not isinstance(evidence, list) or not evidence:
                errors.append(f"this_lesson.{key}[{i}].evidence must be non-empty")

    issues = data.get("issue_assessment")
    if not isinstance(issues, list):
        errors.append("issue_assessment must be an array")
        issues = []
    for i, issue in enumerate(issues):
        if not isinstance(issue, dict):
            errors.append(f"issue_assessment[{i}] must be an object")
            continue
        if not _nonempty(issue.get("issue")):
            errors.append(f"issue_assessment[{i}].issue is required")
        status = issue.get("current_status")
        if status not in CURRENT_STATUSES:
            errors.append(f"issue_assessment[{i}].current_status must be one of {sorted(CURRENT_STATUSES)}")
        include = issue.get("include_in_parent_feedback")
        if not isinstance(include, bool):
            errors.append(f"issue_assessment[{i}].include_in_parent_feedback must be boolean")
            include = False
        evidence = issue.get("this_lesson_evidence", [])
        if not isinstance(evidence, list):
            errors.append(f"issue_assessment[{i}].this_lesson_evidence must be an array")
            evidence = []
        if include:
            if status == "not_observed":
                errors.append(f"issue_assessment[{i}] cannot be included when current_status is not_observed")
            if not evidence:
                errors.append(f"issue_assessment[{i}] included in parent feedback without this-lesson evidence")
        if not _nonempty(issue.get("reason")):
            errors.append(f"issue_assessment[{i}].reason is required")

    next_lesson = data.get("next_lesson")
    if not isinstance(next_lesson, dict):
        errors.append("next_lesson must be an object")
        next_lesson = {}
    if not isinstance(next_lesson.get("planned_topics"), list) or not next_lesson.get("planned_topics"):
        errors.append("next_lesson.planned_topics must be a non-empty array")
    if not isinstance(next_lesson.get("basis"), list) or not next_lesson.get("basis"):
        errors.append("next_lesson.basis must be a non-empty array")

    if data.get("unresolved") not in ([], None):
        errors.append("unresolved must be empty before feedback generation")
    return errors


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("context", type=Path)
    p.add_argument("--expected-student")
    args = p.parse_args()
    errors = validate(args.context, args.expected_student)
    for error in errors:
        print(f"ERROR: {error}")
    if not errors:
        print("postclass-context: OK")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
