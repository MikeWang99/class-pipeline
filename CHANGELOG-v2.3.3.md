# v2.3.3 — 无管理员权限也可安装即用

- Homebrew 不可写入 `/opt/homebrew` 时，自动回退到用户目录安装。
- 常驻监听器和健康检查自动包含用户目录 Homebrew 的 `ffmpeg` / `ffprobe` 路径。
- 保持原有本地 Whisper 转写、原生系统声 + 麦克风采集和 launchd 自动注册流程。
