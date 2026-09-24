# v2.3.0

## 安装即用与可诊断性

- 首次触发 Skill 时自动执行 setup.sh --auto，不再只提示用户手动初始化
- setup 自动安装缺失的 Homebrew、ffmpeg、whisper-cpp，并下载 Whisper Turbo 模型
- 自动探测更多 Obsidian Vault 位置，找不到 Vault 时快速失败并给出 --vault 用法
- 配置中记录实际 whisper_cli、模型路径和 Skill 版本，避免 Intel/Apple Silicon 路径不一致
- 新增 scripts/healthcheck.sh，验证 Vault、录音组件、转写依赖和 launchd 后台任务
- 修正 Codex skill 链接名称，统一使用 class-pipeline，并保留旧名称兼容链接
- 更新 README，移除已过时的 BlackHole / Multi-Output 安装说明
