# class-pipeline · 物理教学 Pipeline

物理教学「课前 → 课中 → 课后」全链路自动化 skill（macOS）。

| 阶段 | 行为 | 触发方式 |
|---|---|---|
| 课前 | 扫描明天日历，为每节课生成备课笔记骨架（含学生档案摘要、上次反馈），由装了 Skill 的 AI 补全教学目标与流程 | launchd 每日 10:00 自动 + 说「备课」 |
| 课中 | 检测到会议（Zoom/腾讯会议/钉钉/飞书/Google Meet）自动录音，散会后使用本地 Whisper large-v3-turbo 转写全员文字稿；文字稿生成成功后自动删除原始 audio.wav | 常驻后台，全自动 |
| 课后 | 用 transcript-aware final match 确认学生身份，先建立 evidence-grounded `postclass-context.json`，再生成家长反馈、更新学生档案和教师教学优化复盘 | 后台自动 + AI 事件触发/失败补偿 |

所有产出写入 Obsidian Vault 的「上课记录」分区：`备课内容 / 课堂文字稿 / 课后反馈 / 学生档案 / 教学优化`。

## 这套仓库里什么最重要

- `SKILL.md`：给 AI 用的主说明书，定义整条课前/课中/课后流水线
- `docs/postclass-context-spec.md`：课后反馈前的强制上下文 / 证据 gate
- `docs/feedback-spec.md`：面向家长的课后反馈写作规范
- `docs/teacher-review-spec.md`：面向授课教师的教学优化复盘规范
- `scripts/validate_postclass_context.py`：阻止没有完整档案/本节证据的反馈生成
- `scripts/validate_feedback_output.py`：检查四段结构和段落末尾标点风格
- `scripts/`：录音、日历匹配、课前扫描、转写、反馈素材准备等实际执行脚本
- `setup.sh`：新电脑一键安装入口

本地运行配置放在 `config.json`，故意不进 Git；仓库里的 `config.example.json` 只是模板。

## 安装（新电脑）

```bash
git clone https://github.com/<you>/class-pipeline.git
cd class-pipeline
bash setup.sh --auto
```

`setup.sh --auto` 一键完成：自动安装 Homebrew、ffmpeg 和 whisper-cpp（系统目录不可写时自动安装到用户目录）→ 自动下载 Whisper Turbo 模型 → 探测 Obsidian Vault → 写 `config.json` → 创建原生音频采集助手 → 注册 launchd 任务 → 运行健康检查 → 链接到 `~/.codex/skills/class-pipeline`。重复运行安全。

仓库里附带一份 `config.example.json`，方便把这套 skill 迁移到新电脑或分享给别的 AI 环境时快速对照配置结构；实际运行仍以 `setup.sh` 生成的本地 `config.json` 为准。

安装过程中只需要处理 macOS 无法代办的一次性授权：麦克风、屏幕与系统音频录制、日历访问。setup 会自动安装本地 Whisper 运行时和模型；如果系统没有 Obsidian Vault，可用 `bash setup.sh --vault /绝对路径` 指定。

卸载：`bash uninstall.sh`（保留录音数据与笔记）。

## 依赖

- macOS（日历 / launchd / EventKit / osascript）
- Homebrew、ffmpeg、whisper-cpp、python3、swift（setup 会自动安装缺失的依赖；没有管理员权限时使用用户目录 Homebrew）
- 本地 Whisper 运行时：setup 会自动安装 whisper-cpp，并写入实际 CLI 和模型路径
- 日历事件命名：`{体系} Class-{学生名}`，如 `CIE Class-Sujal`

## 目录结构

```
SKILL.md                  # AI 工作流指令（首次触发会自动初始化）
config.example.json       # 配置模板（分享/迁移时参考）
config.json               # 运行时配置（setup.sh 生成，本地使用，不入库）
setup.sh / uninstall.sh   # 安装 / 卸载
scripts/
  preclass_scan.py        # 课前：日历扫描 → 备课骨架
  meeting_watcher.sh      # 课中：会议检测 + 录音 + 转写 + 反馈草稿素材准备（launchd 常驻）
  healthcheck.sh          # 检查配置、后台任务、录音组件和本地转写
  transcribe_audio.py     # 本地 Whisper Turbo 转写（自动分片）
```

录音与文字稿存放在 `~/physics-class-pipeline-data/`，日志在其 `logs/` 子目录。只有 `postclass-context.json`、正式家长反馈、学生档案更新和教师教学优化复盘四项全部成功并通过验证后，才会删除对应 session 的 `audio.wav`；待身份识别、转写质量确认或 AI 生成的任务会保留原音频供复核。文字稿会一律归档到 Vault 的 `上课记录/课堂文字稿/`，AI 素材写入 `上课记录/课后反馈草稿/`。安装后可运行 `bash scripts/healthcheck.sh` 验证后台监听和转写依赖。

开课和散会提醒同时使用通知横幅与 8 秒自动关闭的可见对话框，避免 macOS 静默抑制横幅时没有任何提示。可随时运行 `bash scripts/meeting_watcher.sh notify-test` 验证弹窗链路。

音频采集使用 macOS 原生 ScreenCaptureKit，同时捕获系统播放声和麦克风，不需要 BlackHole、Multi-Output 或手动切换会议 App 的扬声器设备。

课程身份现在采用两阶段确认：录音开始时的匹配只算 provisional；如果附近有多节紧邻课程就不会提前锁学生。完整转写后，Pipeline 会用文字稿第一段有效课堂语音对应的实际时间重新做 final match，因此“第一节取消、第二节实际开课”不会再沿用第一节的早期身份。随后 `scripts/trigger_postclass_ai.sh` 事件式启动本机 Codex，先完整读取本节文字稿 + 当前学生档案 + 最近反馈（以及可用的上一节文字稿/本次备课），建立并验证 `postclass-context.json`，再依次生成家长反馈、更新档案并生成教学优化复盘。这不是定时轮询；每天 10:00 的 Codex 自动任务仅作为失败重试与次日备课入口。

## 维护建议

- 改工作流或提示词时，优先更新 `SKILL.md` 与 `docs/feedback-spec.md`
- 改自动化行为时，优先更新 `scripts/`
- 换电脑时先复制仓库，再运行 `bash setup.sh --auto`
- 只想迁移配置时，对照 `config.example.json`，不要直接提交自己的 `config.json`


## v2.2 课后反馈证据规则

`「3. 孩子当前待加强方向」` 不再直接复制学生档案中的历史问题。每个写给家长的问题必须在本节课中有可观察 evidence，并先记录到 `postclass-context.json`。历史问题若本节未再次出现，继续保留在学生档案中观察，但不机械重复到本节反馈

反馈正文保留正常的段内标点，但每个段落或 bullet 最末尾不使用中文句号 `。` 或英文句点 `.`
