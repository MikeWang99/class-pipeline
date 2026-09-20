# Post-class Context Gate · v2.2

正式家长反馈不是直接从 Prompt 或历史问题台账生成，而是必须先建立一份本节课的 `postclass-context.json`

## Evidence priority

判断顺序固定为：

1. **本节课完整课堂文字稿** — 最高优先级，决定本节实际发生了什么
2. **当前完整学生档案** — 提供长期进度、已有问题和历史状态
3. **最近一次正式课后反馈 / 上次课记录** — 提供上一课的承接关系
4. **本次备课内容** — 用于对比“原计划”与“实际完成”
5. **下一课已有安排（如存在）** — 作为后续计划参考

历史档案不能替代本节课证据

## Required shape

```json
{
  "schema_version": "2.2",
  "identity": {
    "student": "Eden",
    "system": "AP Physics 1",
    "status": "confirmed",
    "match_basis": "transcript-aware final calendar match"
  },
  "sources": {
    "transcript": {"path": "...", "read_complete": true},
    "current_profile": {"path": "...", "read_complete": true},
    "previous_feedback": {"path": "...", "read_complete": true},
    "current_prep": {"path": "...", "read_complete": true}
  },
  "before_lesson": {
    "current_progress": "...",
    "active_issues": [],
    "previous_lesson_summary": "...",
    "prior_next_plan": "..."
  },
  "this_lesson": {
    "actual_content": [],
    "successes": [
      {"claim": "...", "evidence": [{"timestamp": "...", "observation": "..."}]}
    ],
    "difficulties": [
      {"claim": "...", "evidence": [{"timestamp": "...", "observation": "..."}]}
    ],
    "homework_assigned": []
  },
  "issue_assessment": [
    {
      "issue": "...",
      "previous_status": "active",
      "current_status": "repeated",
      "this_lesson_evidence": [{"timestamp": "...", "observation": "..."}],
      "include_in_parent_feedback": true,
      "reason": "..."
    }
  ],
  "next_lesson": {
    "planned_topics": [],
    "issue_checks": [],
    "basis": []
  },
  "unresolved": []
}
```

## Issue rule

`「3. 孩子当前待加强方向」` 中的每一项都必须来自 `issue_assessment` 且满足：

- `include_in_parent_feedback = true`
- 本节课存在 `this_lesson_evidence`
- `current_status` 不能是 `not_observed`

历史问题如果本节课没有再次出现，不要为了“连续性”重复写进家长反馈；它继续留在学生档案中跟踪即可

允许的 `current_status`：`new / repeated / improving / resolved / not_observed`

## Next lesson rule

下一节课安排必须同时考虑：

- 当前 syllabus / course progress
- 本节课实际完成到哪里
- 本节课仍需处理的问题
- 上一版计划或下一课备课（如果存在）

不要仅复制上一次反馈中的“继续加强”

## Gate

正式反馈生成前必须运行：

```bash
python scripts/validate_postclass_context.py <session>/postclass-context.json --expected-student <student>
```

验证失败时，不生成正式家长反馈，不更新长期问题台账，不删除原始音频
