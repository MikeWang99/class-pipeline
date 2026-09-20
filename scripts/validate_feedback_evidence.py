#!/usr/bin/env python3
"""Validate the evidence packet that must precede parent feedback generation."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

TIME_RE = re.compile(r"(?<!\d)(?:(?:\d{1,2}):)?\d{1,2}:\d{2}(?!\d)")


def extract_times(text: str) -> set[str]:
    return set(TIME_RE.findall(text))


def validate(context_path: Path, evidence_path: Path) -> list[str]:
    context = json.loads(context_path.read_text(encoding="utf-8"))
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    errors: list[str] = []
    if evidence.get("schema_version") != "2.2":
        errors.append("evidence schema_version must be 2.2")
    if evidence.get("student") != context.get("student"):
        errors.append("evidence student does not match feedback context")

    sources = context.get("sources") or {}
    transcript_path = Path(sources.get("current_transcript") or "")
    if not transcript_path.is_file():
        errors.append("current transcript missing")
        transcript_times: set[str] = set()
    else:
        transcript_times = extract_times(
            transcript_path.read_text(encoding="utf-8", errors="replace")
        )

    read = evidence.get("context_read")
    if not isinstance(read, dict):
        errors.append("context_read must be an object")
        read = {}
    if read.get("current_transcript") is not True:
        errors.append("current transcript must be marked as read")
    for key in (
        "current_profile",
        "previous_feedback",
        "previous_transcript",
        "current_prep",
        "previous_prep",
        "next_prep",
    ):
        if sources.get(key) and read.get(key) is not True:
            errors.append(f"available context source was not marked as read: {key}")

    if not str(evidence.get("current_progress_summary") or "").strip():
        errors.append("current_progress_summary is required")

    def check_claims(field: str, require_nonempty: bool = False):
        items = evidence.get(field)
        if not isinstance(items, list):
            errors.append(f"{field} must be an array")
            return
        if require_nonempty and not items:
            errors.append(f"{field} must contain at least one evidence-backed item")
        for i, item in enumerate(items):
            if not isinstance(item, dict):
                errors.append(f"{field}[{i}] must be an object")
                continue
            if not str(item.get("claim") or item.get("issue") or "").strip():
                errors.append(f"{field}[{i}] claim/issue is required")
            refs = item.get("transcript_refs")
            if not isinstance(refs, list) or not refs:
                errors.append(f"{field}[{i}] requires current-lesson transcript_refs")
                continue
            for ref in refs:
                if ref not in transcript_times:
                    errors.append(
                        f"{field}[{i}] transcript ref not found in current transcript: {ref}"
                    )
            if (
                field == "priority_issues"
                and item.get("status") == "historical"
                and not str(item.get("profile_issue") or "").strip()
            ):
                errors.append(
                    f"priority_issues[{i}] historical issue requires profile_issue linkage"
                )

    check_claims("lesson_content", require_nonempty=True)
    check_claims("progress_evidence", require_nonempty=False)
    check_claims("priority_issues", require_nonempty=False)
    if isinstance(evidence.get("priority_issues"), list) and len(evidence["priority_issues"]) > 2:
        errors.append("priority_issues may contain at most 2 items")

    plans = evidence.get("next_lesson_plan")
    if not isinstance(plans, list) or not plans:
        errors.append("next_lesson_plan must contain at least one item")
    else:
        for i, item in enumerate(plans):
            if not isinstance(item, dict) or not str(item.get("plan") or "").strip():
                errors.append(f"next_lesson_plan[{i}].plan is required")
            basis = item.get("basis") if isinstance(item, dict) else None
            if not isinstance(basis, list) or not basis:
                errors.append(f"next_lesson_plan[{i}].basis must be a non-empty array")

    return errors


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("context", type=Path)
    p.add_argument("evidence", type=Path)
    args = p.parse_args()
    errors = validate(args.context, args.evidence)
    for error in errors:
        print(f"ERROR: {error}")
    if not errors:
        print("feedback-evidence: OK")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
