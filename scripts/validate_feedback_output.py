#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

HEADINGS = (
    "「1. 本节课内容」",
    "「2. 本节课进步」",
    "「3. 孩子当前待加强方向」",
    "「4. 后续计划」",
)


def validate(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    errors: list[str] = []
    for heading in HEADINGS:
        if heading not in text:
            errors.append(f"missing required heading: {heading}")
    if "课后练习安排：" not in text:
        errors.append("missing 课后练习安排：")
    if "下节课安排：" not in text:
        errors.append("missing 下节课安排：")

    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line in HEADINGS or line == "本节课反馈：":
            continue
        if line.endswith("：") or line.endswith(":"):
            continue
        if line.endswith("。") or line.endswith("."):
            errors.append(f"line {number} ends with a terminal period; remove only the paragraph/bullet-final period")
    return errors


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("feedback", type=Path)
    args = p.parse_args()
    errors = validate(args.feedback)
    for error in errors:
        print(f"ERROR: {error}")
    if not errors:
        print("feedback-output: OK")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
