# v2.4.0 — Bounded and self-healing class recording

- Added a hard 150-minute maximum for every recording session at both watcher and native-helper levels
- Added a per-meeting hold latch so reaching the limit cannot immediately start another recording while the same meeting/window is still detected
- Added start-time and live disk-space guards (defaults: 8 GB recommended to start, 3 GB critical stop)
- Added ScreenCaptureKit runtime-error handling and a 10-second native capture heartbeat
- Added watcher monitoring for stale heartbeat and prolonged no-frame progress
- Added same-session segmented recovery after unexpected capture interruption, with ordered merge into one final stereo audio file
- Capped automatic capture recovery attempts; exhausted recovery marks the recording incomplete
- Tightened end-of-session completeness detection from the previous loose 75% rule to configurable ratio + absolute-gap checks
- Made `recording_incomplete` a real hard gate: partial audio may be transcribed for diagnosis, but automatic formal feedback/profile/teacher-review generation is forbidden and source audio is retained
- Updated cleanup to delete every recovered raw CAF segment only after validated post-class completion
- Added upgrade health checks for config version, native capture binary freshness, hard duration configuration and disk headroom
