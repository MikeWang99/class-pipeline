# v2.2.0 — Session identity safety + evidence-grounded feedback

- Stop permanently binding a recorded session to the nearest calendar start time before transcription.
- Calendar queries now preserve event start and end times.
- Final session identity uses meaningful transcript activity versus calendar interval overlap; ambiguous sessions remain pending instead of updating the wrong student.
- Add `calendar_candidates.json` diagnostics for deferred, matched, ambiguous, and unmatched identity decisions.
- Add `feedback_context.json` to enumerate the complete current profile, current transcript, previous feedback/class, prep context, and next prep when available.
- Add `feedback_evidence.json` as a hard pre-feedback gate.
- Require current-lesson transcript evidence for every parent-facing progress claim and current priority issue.
- Historical issues without current-lesson evidence remain in the internal student ledger and are no longer mechanically repeated in parent feedback.
- Next-lesson planning must use current progress plus current-lesson evidence, and existing next-prep material when available.
- Completion/cleanup for new sessions requires formal feedback, student profile, validated evidence packet, and teacher review.
- Preserve backward compatibility for sessions completed before the v2.2 context/evidence gate.
