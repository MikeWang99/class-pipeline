# class-pipeline · 物理教学 Pipeline

物理教学「课前 → 课中 → 课后」全链路自动化 skill（macOS）。

| 阶段 | 行为 | 触发方式 |
|---|---|---|
| 课前 | 扫描明天日历，为每节课生成备课笔记骨架（含学生档案摘要、上次反馈），由装了 Skill 的 AI 补全教学目标与流程 | launchd 每日 10:00 自动 + 说「备课」 |
| 课中 | 检测到会议（Zoom/腾讯会议/钉钉/飞书/Google Meet）自动录音，散会后使用本地 Whisper large-v3-turbo 转写全员文字稿；文字稿生成成功后自动删除原始 audio.wav | 常驻后台，全自动 |
| 课后 | 自动归档文字稿并始终保留反馈任务；日历临时不可用时等待 AI 重试识别。正式家长反馈、学生档案更新、作业建议由装了 Skill 的 AI 完成 | 后台自动 + AI 周期任务 |

所有产出写入 Obsidian Vault 的「上课记录」分区：`备课内容 / 课堂文字稿 / 课后反馈 / 学生档案`。

## 这套仓库里什么最重要

- `SKILL.md`：给 AI 用的主说明书，定义整条课前/课中/课后流水线
- `docs/feedback-spec.md`：课后反馈写作规范
- `scripts/`：录音、日历匹配、课前扫描、转写、反馈素材准备等实际执行脚本
- `setup.sh`：新电脑一键安装入口

本地运行配置放在 `config.json`，故意不进 Git；仓库里的 `config.example.json` 只是模板。

## 安装（新电脑）

```bash
git clone https://github.com/<you>/class-pipeline.git
cd class-pipeline
bash setup.sh
```

`setup.sh` 一键完成：依赖检查（缺 ffmpeg 自动 brew 安装）→ BlackHole 虚拟声卡 → 探测 Obsidian Vault → 写 `config.json` → 创建后台应用并注册 launchd 任务 → 弹出系统麦克风授权窗口 → 链接到 `~/.qoder/skills` 与 `~/.codex/skills`。重复运行安全。

仓库里附带一份 `config.example.json`，方便把这套 skill 迁移到新电脑或分享给别的 AI 环境时快速对照配置结构；实际运行仍以 `setup.sh` 生成的本地 `config.json` 为准。

安装过程中系统会要求您做 4 件事（macOS 安全机制，无法再省）：

1. 输入一次管理员密码（安装 BlackHole 驱动时）
2. **重启一次 Mac**（BlackHole 驱动生效必需），重启后再跑一次 `bash setup.sh`
3. 在弹出的「访问麦克风」窗口点一次【允许】
4. 本地 Whisper Turbo 模型已下载到 `~/.cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin`（setup 会检查）

可选：想录到学生声音，在「音频 MIDI 设置」手动建一个多输出设备（扬声器+BlackHole，30 秒），或在会议 App 里把扬声器设为 BlackHole 2ch。

卸载：`bash uninstall.sh`（保留录音数据与笔记）。

## 依赖

- macOS（日历 / launchd / EventKit / osascript）
- brew、ffmpeg、python3、swift（setup 会检查）
- 本地 Whisper 运行时：`/opt/homebrew/bin/whisper-cli` 与 `~/.cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin`
- 日历事件命名：`{体系} Class-{学生名}`，如 `CIE Class-Sujal`

## 目录结构

```
SKILL.md                  # AI 工作流指令（任何支持 skill 的 AI 可执行）
config.example.json       # 配置模板（分享/迁移时参考）
config.json               # 运行时配置（setup.sh 生成，本地使用，不入库）
setup.sh / uninstall.sh   # 安装 / 卸载
scripts/
  preclass_scan.py        # 课前：日历扫描 → 备课骨架
  meeting_watcher.sh      # 课中：会议检测 + 录音 + 转写 + 反馈草稿素材准备（launchd 常驻）
  setup_audio.sh          # BlackHole 安装/检查/激活/还原
  create_multi_output.swift  # 创建 CoreAudio 多输出设备
  transcribe_audio.py     # 本地 Whisper Turbo 转写（自动分片）
```

录音与文字稿存放在 `~/class-pipeline-data/`，日志在其 `logs/` 子目录。只有正式家长反馈和学生档案更新成功后，才会删除对应 session 的 `audio.wav`，并在同目录写入 `audio_deleted.txt` 记录删除时间、路径和释放字节数；待身份识别、转写质量确认或 AI 生成的任务会保留原音频供复核。`transcript.txt` / `transcript.json` 会保留。本地 Whisper 只负责这一步的语音转写，不负责备课内容或课后反馈正文。文字稿现在会一律归档到 Vault 的 `上课记录/课堂文字稿/`，AI 所需素材也会一律写入 `上课记录/课后反馈草稿/`。日历临时不可用时，任务会标为“待AI识别学生”并保留到后续重试，不会再静默跳过。正式家长反馈与学生档案更新仍由装了该 skill 的 AI 完成；在 Codex 中应配置周期任务来自动消费这批待处理素材。

开课和散会提醒同时使用通知横幅与 8 秒自动关闭的可见对话框，避免 macOS 静默抑制横幅时没有任何提示。可随时运行 `bash scripts/meeting_watcher.sh notify-test` 验证弹窗链路。

音频设置中，`PhysicsClass Multi-Output` 应勾选实际听课设备（本机为 `Mac mini扬声器`）和 `BlackHole 2ch`。Pipeline 开课时切换到该复制设备，散会后会恢复开课前实际使用的输出设备。

课程匹配在开课时尝试锁定，临时读不到日历时会在录音期间每 60 秒重试，直到成功。转写与反馈素材准备完成后，`scripts/trigger_postclass_ai.sh` 会事件式启动一次本机 Codex，由安装了 Skill 的 Codex 读取完整文字稿、生成正式反馈并更新档案。这不是定时轮询；每天 10:00 的 Codex 自动任务仅作为失败重试与次日备课入口。

## 维护建议

- 改工作流或提示词时，优先更新 `SKILL.md` 与 `docs/feedback-spec.md`
- 改自动化行为时，优先更新 `scripts/`
- 换电脑时先复制仓库，再运行 `bash setup.sh`
- 只想迁移配置时，对照 `config.example.json`，不要直接提交自己的 `config.json`