---
name: physics-class-pipeline
description: 物理教学课前/课中/课后全链路自动化。课前定时扫描日历生成备课笔记骨架；课中自动录制会议音频；课后基于转写文字稿准备反馈草稿与资料，由当前装了 Skill 的 AI 生成正式备课内容和家长反馈。触发词：备课、课前、上课、下课、课后、全链路、class pipeline。
---

# Physics Class Pipeline · 物理教学全链路

把「课前备课 → 课中录音 → 课后反馈/档案/作业」串成一条自动化流水线。语音转写默认优先使用 Groq Whisper，遇到权限、网络或区域限制时自动切换到本地 whisper.cpp；备课内容、课后反馈、档案更新、作业建议都由当前执行该 Skill 的 AI 负责。所有产出写入 Obsidian Vault 的「上课记录」分区。

## 0. 通用约定

- **配置文件**：`config.json`（位于本 skill 目录），由 `setup.sh` 生成。字段：
  - `vault_path`：Obsidian Vault 根目录
  - `recordings_dir`：录音/文字稿工作目录（默认 `~/physics-class-pipeline-data`）
  - `calendar_keyword`：日历事件识别关键词（默认 `Class`）
  - `scan_hour` / `scan_minute`：每日课前扫描时间（默认 10:00）
- **笔记根目录**：`{vault_path}/上课记录/`，下设四个子分区：
  - `备课内容/`、`课堂文字稿/`、`课后反馈/`、`课后反馈草稿/`、`学生档案/`
- **文件命名**：`YYYY-MM-DD {体系} Class-{学生}.md`（学生档案固定为 `{学生}.md`，累积更新）
- **日历事件格式**：`{体系} Class-{学生名}`，如 `CIE Class-Sujal`、`AP Class-Eden`。体系取 `Class` 前文本，学生取连字符后文本。
- 读取配置后再干活；`config.json` 不存在时提示用户先运行 `setup.sh`。
- 所有脚本在 `scripts/` 下，用绝对路径调用。
- **转写后端**：`scripts/transcribe_audio.py` 支持 `TRANSCRIBE_BACKEND=auto|groq|local`，默认是 `auto`。`auto` 模式不会因 Groq 403 把课后流程卡死，而是切换到本地 Whisper。多语言课堂使用 `~/.cache/whisper-cpp/ggml-small.bin`；也可用 `WHISPER_MODEL` 指定模型路径，`TRANSCRIBE_LANGUAGE=zh`、`en` 或 `auto` 指定语言。

## 1. 首次安装（闭环）

用户说「安装/设置 physics-class-pipeline」时：

```bash
bash {skill_dir}/setup.sh
```

setup.sh 会自动完成：依赖检查（brew/ffmpeg 缺则自动装/python3/swift）→ 安装 BlackHole 虚拟声卡（需重启一次，重启后重跑 setup.sh）→ 尝试创建多输出音频设备（新系统可能失败，会提示手动替代方案，不阻塞安装）→ 探测 Obsidian Vault → 读取 GROQ_API_KEY（仅供转写使用）→ 创建后台应用 PhysicsClassWatcher/PhysicsClassScanner 并注册两个 launchd 任务（每日 10:00 课前扫描 + 常驻会议监听）→ 自动弹出系统麦克风授权窗口并等待用户点一次「允许」→ 安装 skill 到 `~/.qoder/skills` 与 `~/.codex/skills`。全程打印每一步结果。卸载用 `uninstall.sh`。

## 2. 课前：备课内容生成

**自动部分（launchd 每天 10:00）**：`preclass_scan.py` 用 EventKit 扫描明天日历，找出所有含 `Class` 关键词的事件，为每节课在 `{vault}/上课记录/备课内容/` 生成带上下文的备课笔记骨架（已自动填入学生档案摘要、最近一次课后反馈、上次课内容回顾，并记录 `event_start` 日历元数据供课后匹配兜底），并发送 macOS 通知提醒补全。

**AI 补全部分**：用户说「备课」「补全备课」「生成备课内容」时：

1. 读 `config.json` 拿 `vault_path`。
2. 列出 `{vault}/上课记录/备课内容/` 中明天日期开头的笔记（若无，先手动运行 `python3 {skill_dir}/scripts/preclass_scan.py` 生成）。
3. 对每份骨架笔记：
   - 结合**该体系的官方 syllabus**（CIE IGCSE 0625 / AP Physics 1/2/C 等，依据学生档案中的体系字段；本地工作区如有 syllabus 资料优先引用）
   - 结合 `{vault}/上课记录/学生档案/{学生}.md` 的当前进度、薄弱项
   - 结合骨架中已嵌入的上节课回顾
   - 补全「本次课教学目标」「教学流程与时间分配」「关键题目/演示」「预判学生卡点」等章节
4. 直接编辑该笔记文件（保持 front matter 与已填上下文不动）。

这里的“补全”必须由当前装了该 Skill 的 AI 自己完成。不要调用 Groq 或其他本地脚本模型去写备课正文。

## 3. 课中：自动录音（全自动，无需 AI 参与）

launchd 常驻任务 `meeting_watcher.sh` 每 15 秒检测一次会议进程：

- **覆盖平台**：Zoom（zoom.us）、腾讯会议（wemeetapp/xmeet）、钉钉、飞书、Google Meet（Chrome/Safari 打开 meet.google.com 标签页）
- **检测到开课**：自动用 ffmpeg 录制 BlackHole（会议双方声音）+ 麦克风（双保险），存入 `{recordings_dir}/sessions/{YYYY-MM-DD_HHMM}/audio.wav`
- **检测到散会**（连续 45 秒无会议进程）：停止录音 → 自动调用 Groq Whisper，失败时切换本地 Whisper 转写 → 文字稿存 `transcript.txt` → **无论是否匹配到日历，都会先把文字稿归档到 Vault 的 `课堂文字稿/`** → 创建课后反馈待处理素材并交给当前 AI；只有正式反馈和学生档案更新成功后才删除对应的 `audio.wav`（写入 `audio_deleted.txt` 删除记录），待身份识别、转写质量确认或 AI 生成的任务会保留原音频供复核
- **课程身份锁定**：开课时立即按 session 时间匹配日历；若 EventKit 或 iCloud 当时短暂不可用，录音期间每 60 秒重试，直到将 `{SYSTEM}|{STUDENT}` 写入 `calendar_match.txt`

用户无需任何手动操作。若用户说「开始上课/手动录音」，可直接运行 `bash {skill_dir}/scripts/meeting_watcher.sh once` 强制走一轮录音+转写。

## 4. 课后：反馈 + 档案 + 作业（半自动）

散会后 watcher 自动完成以下步骤：

1. **归档文字稿与清理音频**：转写成功后，一律将 `transcript.txt` 加 front matter（日期/学生/体系/时长/是否匹配课程/文字稿来源/原始音频路径/音频保留策略）归档到 `{vault}/上课记录/课堂文字稿/`。若匹配到课程，则文件名为 `{YYYY-MM-DD} {体系} Class-{学生}.md`；若未匹配到课程，则文件名降级为 `{YYYY-MM-DD} 未匹配 Class-Session-{时戳}.md`，至少保证课堂文字稿不会丢。反馈素材生成和 AI 复核前先检查转写质量；只有正式反馈和学生档案更新成功后才删除 `audio.wav`，并写入 `audio_deleted.txt` 删除记录。若文字稿主要是环境声、`multiple voices` 等占位标签，素材标记为“待人工确认录音”，不触发 AI、不删除原音频
2. **自动准备反馈草稿素材**（无论日历是否临时可用）：`postclass_generate.sh` 读取转写稿 + 学生档案 + 上次反馈，生成一个待 AI 填写的反馈素材文件。已匹配时写入 `{vault}/上课记录/课后反馈草稿/{YYYY-MM-DD}-{学生}-feedback-materials.md`；未匹配时以 session 标识进入同一目录并标记为“待AI识别学生”，不能跳过。该素材稿只负责把来源材料和固定结构铺好，不负责生成正式反馈正文，也不会由 watcher 直接改写学生档案。学生名会做清洗并与档案模糊匹配（防日历标题污染）
3. **事件式触发当前 AI**：素材生成后立即运行 `trigger_postclass_ai.sh`，只启动一次本机 `codex exec`。该 Codex 必须读取完整文字稿、学生档案、最近反馈和 `docs/feedback-spec.md`，然后生成正式反馈、更新档案并写入 `ai_completed.txt`。它是课后事件触发，不是每 15 分钟轮询

**通知逻辑**：
- 有日历日程：「转写完成，文字稿已归档，反馈素材已准备好（正式反馈/档案更新待 AI 完成）✅」
- 未匹配到课程：「转写完成，文字稿已归档；课程待重新识别，反馈任务已保留」

**AI 生成部分**：用户说「生成反馈」「精修反馈」「更新档案」时，AI 读取 `课后反馈草稿/` 里的素材稿、课堂文字稿与学生档案，按本 skill 内置规范 `docs/feedback-spec.md` 生成正式反馈，并写入 `{vault}/上课记录/课后反馈/{YYYY-MM-DD}-{学生}-feedback.md`，同时按规范的台账更新规则同步 `{vault}/上课记录/学生档案/{学生}.md`。也就是说，学生档案更新发生在这一步，而不是 watcher 仅靠转写就能自动完成。

每天 10:00 的 Codex 定时任务保留为失败补偿与次日备课入口：扫描 `课后反馈草稿/` 中仍处于“待AI生成 / 待AI识别学生”的文件，先重试日历匹配，再由当前宿主 AI 读取完整文字稿生成正式反馈并更新档案。日历暂时不可用时保留任务，不得猜学生或标记完成。Groq Whisper 始终只负责转写，不参与正文生成。

## 4.1 课后反馈写作规范（内置）

完整的课后反馈写作规范在 `docs/feedback-spec.md`，原为独立的 parent-lesson-feedback skill，现已融合为本 pipeline 的一部分。任何由 AI 生成/精修课后反馈的场景（AI 手动生成、用户直接要求写反馈）都必须遵循该文档：

- 四段式结构：「1. 本节课内容」「2. 本节课进步」「3. 孩子当前待加强方向」「4. 后续计划」
- 证据优先：一切判断必须有文字稿中的可观察证据，信息不足时先向用户提问而不是编造
- 问题台账连续性：与学生档案「主要问题」保持用词一致，带（本节课新增）/（历史问题）括号标签，老问题不许凭空消失
- 篇幅 400-600 字，面向不懂物理的家长，第一人称「我」
- 文风要具体、定制化：优先直接点名学生（如“Eden 这次……”或“Julian 已经……”），避免整篇只写“学生”“孩子”这种泛称
- 如果本节课的文字稿足够具体，反馈里要落到这位学生实际做过的动作、说过的话、卡住的点和修正后的变化，避免模板化概括
- 「1. 本节课内容」必须先给整体框架，再给 1–3 个主要模块；不要把整节课缩成某一道题的单题讲解
- 「2. 本节课进步」不要使用 `1. 2. 3. 4.` 这类编号列表；优先用“模块名：一句简述”的要点式写法，或模块标题配简短项目符号
- 「4. 后续计划」必须拆成「课后练习安排」和「下节课安排」两个小节：前者只写老师明确布置或需要完成的课后练习，后者只写下一节课的教学安排；没有明确作业时不要自行编造
- 反馈正文不要使用加粗、下划线等强调格式；标题之外尽量保持纯文本风格

台账即学生档案：`{vault}/上课记录/学生档案/{学生}.md`，反馈定稿后按其「主要问题」的更新规则同步。

## 5. 故障排查

| 现象 | 处理 |
|---|---|
| 录音文件无声/只有单方 | 确认 `PhysicsClass Multi-Output` 中包含你实际使用的扬声器（本机为 `Mac mini扬声器`）和 `BlackHole 2ch`；运行 `scripts/setup_audio.sh check`。若 BlackHole 或多输出路由缺失，watcher 会拒绝启动不完整录音并提示修复 |
| 录音时长明显短于实际课程 | 检查 `recording_started_at.txt`、`recording_stopped_at.txt` 与 `recording_incomplete`；先修复音频路由，再重新上课，不能拿不完整录音生成反馈 |
| 没检测到开会 | 运行 `bash scripts/meeting_watcher.sh once` 看检测日志；浏览器开 Meet 需在 Chrome/Safari 且标签页可见 |
| 日志报 `MIC PERMISSION: missing` | 麦克风未授权：打开 系统设置→隐私与安全性→麦克风，把 PhysicsClassWatcher 打开（或重跑 setup.sh 触发弹窗） |
| 转写失败 | 先看 `{recordings_dir}/logs/watcher.log`；默认 `auto` 会在 Groq 不可用时使用本地 Whisper。若本地模型缺失，运行 `bash {skill_dir}/setup.sh` 或设置 `WHISPER_MODEL` 指向已下载的 ggml 多语言模型 |
| 转写报 Forbidden | Groq 的当前项目/密钥没有权限或受网络区域限制；脚本会先读取 macOS 系统代理，仍失败时自动切到本地 Whisper。只有明确设置 `TRANSCRIBE_BACKEND=groq` 才会在 Groq 失败时停止 |
| 文字稿只有环境声或占位标签 | 反馈素材会标记为“待人工确认录音”，不会调用 AI 生成反馈，也不会删除原始音频；先检查 BlackHole / 多输出设备和会议 App 的扬声器设置 |
| 定时任务没跑 | `launchctl list \| grep physicsclass` 确认任务在；plist 在 `~/Library/LaunchAgents/` |
| 明明 UI 里有 Google 日历事件，但脚本没扫到 | 先确认系统“日历”权限已给 PhysicsClassScanner；查询脚本会重试 EventKit，并使用后台 AppleScript 读取 Calendar 数据，课后再优先回退到备课笔记里的 `event_start` 元数据做匹配；不会为了刷新权限主动打开 Calendar 窗口 |
