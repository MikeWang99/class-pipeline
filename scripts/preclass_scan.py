#!/usr/bin/env python3
"""preclass_scan.py — 扫描明天日历中的课程事件，自动生成备课笔记草稿。

日历事件格式：`{体系} Class-{学生名}`（含关键词 Class，默认大小写不敏感匹配）。
为每节课在 {vault}/上课记录/备课内容/ 下生成备课笔记，自动嵌入：
  - 学生档案摘要（学生档案/{学生}.md 的基本信息/当前进度/主要问题）
  - 最近一次课后反馈（课后反馈/ 下该学生最新一篇）
  - 上一次备课/课次线索
  - 为 AI 生成部分预留固定结构和提示语。
已存在同名笔记则跳过（幂等，可重复运行）。完成后发 macOS 通知。
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import fcntl
from datetime import datetime
from datetime import date, timedelta
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
CONFIG = SKILL_DIR / "config.json"
PLACEHOLDER = "> 待装有该 Skill 的 AI 根据现有材料补全"
LOG_FILE = Path.home() / "physics-class-pipeline-data" / "logs" / "preclass-scan.log"


def load_config() -> dict:
    if not CONFIG.exists():
        sys.exit("config.json 不存在，请先运行 setup.sh")
    return json.loads(CONFIG.read_text(encoding="utf-8"))


def log(message: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {message}\n")


def parse_event(summary: str, keyword: str):
    """从 '体系 Class-学生' 提取 (体系, 学生)。"""
    m = re.search(rf"^(.*?)\s*{re.escape(keyword)}\s*[-－—]\s*(.+)$", summary.strip(), re.IGNORECASE)
    if m:
        return m.group(1).strip() or "未命名体系", m.group(2).strip()
    if keyword.lower() in summary.lower():
        return "未命名体系", summary.replace(keyword, "").strip("- –—·").strip()
    return None


def read_head(path: Path, max_lines: int = 80) -> str:
    if not path.exists():
        return ""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(lines[:max_lines])


def latest_file_for_student(folder: Path, student: str) -> Path | None:
    if not folder.exists():
        return None
    hits = [p for p in sorted(folder.glob("*.md")) if student.lower() in p.name.lower()]
    return hits[-1] if hits else None


def update_existing_note_metadata(path: Path, event_start: str, event_end: str, event_id: str, calendar_title: str) -> bool:
    text = path.read_text(encoding="utf-8", errors="replace")
    if not text.startswith("---\n"):
        return False

    lines = text.splitlines()
    end_idx = None
    for idx in range(1, len(lines)):
        if lines[idx] == "---":
            end_idx = idx
            break
    if end_idx is None:
        return False

    frontmatter_lines = lines[1:end_idx]
    keys = {
        "event_start": event_start,
        "event_end": event_end,
        "calendar_event_id": event_id,
        "calendar_title": calendar_title,
    }
    changed = False
    seen = set()

    for idx, line in enumerate(frontmatter_lines):
        if ":" not in line:
            continue
        key, _value = line.split(":", 1)
        key = key.strip()
        if key in keys:
            seen.add(key)
            new_line = f"{key}: {keys[key]}"
            if frontmatter_lines[idx] != new_line:
                frontmatter_lines[idx] = new_line
                changed = True

    for key, value in keys.items():
        if key not in seen:
            frontmatter_lines.append(f"{key}: {value}")
            changed = True

    if not changed:
        return False

    lines[1:end_idx] = frontmatter_lines
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return True


def build_skeleton(when: str, system: str, student: str, event_start: str, event_end: str,
                   event_id: str, calendar_title: str, notes: str,
                   profile_md: str, last_feedback_md: str, last_prep_md: str) -> str:
    return f"""---
date: {when}
system: {system}
student: {student}
status: 待AI补全
event_start: {event_start}
event_end: {event_end}
calendar_event_id: {event_id}
calendar_title: {calendar_title}
---

# {when} {system} Class-{student} · 备课

## 日历备注
{notes.strip() or '（无）'}

## 学生档案摘要
{profile_md.strip() or '（尚无学生档案，请课后建立）'}

## 最近一次课后反馈
{last_feedback_md.strip() or '（无历史记录）'}

## 上一次备课参考
{last_prep_md.strip() or '（无历史记录）'}

## AI 补全要求
- 结合这位学生现有档案、最近一次反馈、以及该体系 syllabus，补全本次课安排
- 不要脱离当前进度重写整套计划，要紧贴明天这节课真正要上的内容
- 先给整体框架，再细化重点题型、时间分配和预判卡点

## 本次课教学目标
{PLACEHOLDER}

## 教学流程与时间分配
{PLACEHOLDER}

## 关键题目与演示
{PLACEHOLDER}

## 预判学生卡点
{PLACEHOLDER}
"""


def notify(msg: str) -> None:
    log(f"NOTIFY: {msg}")
    subprocess.run(["osascript", "-e",
                    f'display notification "{msg}" with title "Physics Class Pipeline"'],
                   capture_output=True)


def read_events(day_arg: str) -> str:
    query_script = SKILL_DIR / "scripts" / "query_calendar_events.sh"
    out = subprocess.run(
        [str(query_script), day_arg],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "读取日历失败")
    return out.stdout


def resolve_target(day_arg: str) -> tuple[str, str]:
    try:
        offset = int(day_arg)
    except ValueError:
        target = date.fromisoformat(day_arg)
    else:
        target = date.today() + timedelta(days=offset)
    return target.isoformat(), day_arg


def main() -> None:
    cfg = load_config()
    global LOG_FILE
    LOG_FILE = Path(os.path.expanduser(cfg["recordings_dir"])) / "logs" / "preclass-scan.log"
    lock_path = LOG_FILE.with_name("preclass-scan.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_handle = lock_path.open("w", encoding="utf-8")
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("preclass scan skipped: another instance is already running")
        return

    try:
        log("preclass scan started")
        vault = Path(os.path.expanduser(cfg["vault_path"]))
        keyword = cfg.get("calendar_keyword", "Class")
        root = vault / "上课记录"
        prep_dir = root / "备课内容"
        profile_dir = root / "学生档案"
        feedback_dir = root / "课后反馈"
        for d in (prep_dir, profile_dir, feedback_dir, root / "课堂文字稿"):
            d.mkdir(parents=True, exist_ok=True)

        day_arg = sys.argv[1] if len(sys.argv) > 1 else "1"
        target_date, normalized_arg = resolve_target(day_arg)

        try:
            events_output = read_events(normalized_arg)
            log("calendar query succeeded")
        except Exception as exc:
            log(f"calendar query failed: {exc}")
            sys.exit(f"读取日历失败：{exc}")

        created = 0
        refreshed = 0
        for line in events_output.splitlines():
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            summary, start_str = parts[0].strip(), parts[1].strip()
            # query_calendar_events.sh normalizes both Swift and AppleScript
            # sources to title/start/end/event_id/notes.
            if len(parts) >= 5:
                end_str = parts[2].strip()
                event_id = parts[3].strip()
                notes = parts[4]
            else:
                end_str = ""
                event_id = ""
                notes = parts[2] if len(parts) > 2 else ""
            parsed = parse_event(summary, keyword)
            if not parsed:
                continue
            system, student = parsed
            target = prep_dir / f"{target_date} {system} Class-{student}.md"
            if target.exists():
                if update_existing_note_metadata(target, start_str, end_str, event_id, summary):
                    refreshed += 1
                    log(f"refreshed prep metadata: {target.name}")
                log(f"skip existing prep note: {target.name}")
                print(f"skip (exists): {target.name}")
                continue

            profile = read_head(profile_dir / f"{student}.md", 80)
            last_feedback = read_head(latest_file_for_student(feedback_dir, student) or Path("/nonexistent"), 60)
            last_prep = read_head(latest_file_for_student(prep_dir, student) or Path("/nonexistent"), 40)

            skeleton = build_skeleton(
                target_date, system, student, start_str, end_str, event_id, summary, notes,
                profile, last_feedback, last_prep
            )

            target.write_text(skeleton, encoding="utf-8")
            created += 1
            log(f"created prep note: {target}")
            print(f"created: {target}")

        if created:
            notify(f"明天有 {created} 节课的备课笔记已自动生成 ✅")
        elif refreshed:
            notify(f"已刷新 {refreshed} 份备课笔记的日历元数据 ✅")
        else:
            log("no new prep notes created")
            print("明天没有新的课程事件（或笔记已存在）。")
    finally:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
        lock_handle.close()


if __name__ == "__main__":
    main()
