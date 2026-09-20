# v2.2.0 — Evidence-grounded post-class feedback

- Replaced unsafe early student locking with a two-stage identity model: provisional matching before transcript, transcript-aware final matching before feedback
- Packed nearby lessons are no longer provisionally assigned to the nearest calendar event
- Added `derive_lesson_reference.py` so final matching uses the first meaningful classroom speech rather than app-process/session creation time
- Calendar Swift query now emits event end time and event identifier for stronger auditability
- Added mandatory `postclass-context.json` before parent feedback, with current profile, previous lesson, this-lesson evidence, issue status assessment, and next-lesson plan
- Historical issues may enter parent feedback only when this lesson contains supporting evidence; otherwise they remain in the long-term profile only
- Added `validate_postclass_context.py` and `validate_feedback_output.py` hard gates
- Completion now requires validated context, formal feedback, actual student-profile update, and teacher review before source audio cleanup
- Feedback style now removes only paragraph/bullet-final `。` or `.` while preserving normal punctuation inside paragraphs
- Added regression coverage for cancelled-first / attended-second packed lessons
