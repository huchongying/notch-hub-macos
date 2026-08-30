# NotchHub macOS

<p align="center">
  <img src="docs/screenshots/notch-idle.png" alt="NotchHub 在闲置刘海中显示 Codex 周额度与内存" width="900">
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="GPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="SwiftUI">
</p>

NotchHub macOS 是一个面向中文 macOS 用户的刘海信息中心。它基于开源项目 [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) 二次开发：保留原项目的音乐控制、文件架、系统 HUD 等能力，并新增 Codex 额度与 Token 统计、QQ 音乐同步歌词、低占用硬件监控、每日预算预警和全局快捷工具。

> 本仓库目前只发布源代码，不提供未经签名或公证的安装包。应用名称与部分工程标识仍沿用上游，以减少合并和构建成本；NotchHub macOS 是本分支的仓库名称，并非上游官方版本。

## 界面预览

下图均来自实际运行界面。为保护隐私，账号标识、额度、Token 数量和时间已替换为示例数据，界面结构与功能状态保持不变。

<p align="center">
  <img src="docs/screenshots/codex-dashboard.png" alt="Codex 每日预算和额度窗口" width="360">
  &nbsp;&nbsp;
  <img src="docs/screenshots/dashboard-layout-editor.png" alt="硬件面板模块布局编辑" width="360">
</p>

## 相比上游增加了什么

| 方向 | 上游 boring.notch | NotchHub macOS 新增能力 |
| --- | --- | --- |
| 刘海闲置状态 | 以媒体与系统活动为主 | 持续显示 Codex 主额度与系统内存占用 |
| 音乐播放 | 标题、封面、控制与可视化 | QQ 音乐优先的同步歌词；无歌词时回退到歌曲标题 |
| Codex 额度 | 无 | 自动识别 Plus / Pro；Plus 强调 5 小时额度，Pro 强调周额度 |
| Token 统计 | 无 | 本机每日输入、缓存输入、输出和推理 Token 去重统计，统一使用“亿” |
| 预算管理 | 无 | 按剩余周额度动态分配每日预算，达到 100% 和 150% 时各通知一次 |
| 重置监测 | 无 | 每小时检查 Tibo 公开硬重置信号，并与本地额度变化交叉确认 |
| 硬件信息 | 无独立常驻面板 | 中文桌面面板展示 CPU、GPU、内存、磁盘、网络、电池、温度与运行时间 |
| 布局 | 固定为主 | 面板可缩放，六个模块可隐藏、拖动排序并持久保存 |
| 快捷工具 | 原有刘海快捷操作 | 全局快捷键打开 macOS 应用启动台和系统截图工具 |
| 资源占用 | 通用刷新策略 | 2 / 5 / 15 秒自适应采样；低电量、温控、锁屏或屏幕休眠时降频/暂停 |

## 核心功能

### 1. 刘海中的 Codex 状态

- 不播放音乐时，闭合刘海持续显示 Codex 额度和内存占用。
- 自动读取本地已登录的 `codex app-server`，不读取或复制登录 Token。
- Plus 用户优先显示 5 小时窗口；Pro / Pro Lite 用户优先显示周窗口。
- 详情页同时列出所有可用额度窗口、重置时间、预计剩余额度和置信度。
- 提供紧凑、标准、信息增强三种中文布局。
- 修复详情页展开后悬停状态丢失、鼠标移开仍无法收起的问题。

### 2. 每日 Token 与周预算

- 增量扫描 `~/.codex/sessions` 和 `~/.codex/archived_sessions`，只读取新增 JSONL 内容。
- 按事件去重，分别统计输入、缓存输入、输出与推理 Token。
- 所有 Token 数量在自定义界面中使用“亿”为单位。
- 使用同一额度窗口最近 12 个兼容样本的中位数估算剩余额度，并显示估算区间、样本数和中文置信度。
- 每日预算在本地午夜锁定；未用额度滚入后续日期，新额度周期会立即重建预算。
- 仅在达到当日预算 100% 和 150% 时通知，避免频繁打扰。

### 3. QQ 音乐同步歌词

- 播放音乐时，歌词优先于 Codex 与硬件状态显示。
- 优先适配 QQ 音乐，通过 macOS Now Playing / MediaRemote 获取当前歌曲。
- 尝试匹配同步歌词；找不到时回退为歌曲标题，不让刘海空白。
- 切歌时取消过期请求并缓存已验证结果，降低网络与 CPU 开销。

### 4. 中文硬件桌面面板

- 展示处理器占用与系统负载、GPU、内存压力、压缩内存和 Swap。
- 展示磁盘余量、实时上下行网络速率、电池健康、循环次数、温度状态和运行时间。
- 面板默认采用紧凑尺寸，可从边缘自由调整大小并纵向滚动。
- 历史趋势支持额度、硬件和 Token 三种视图。
- 六个内容模块可开关、拖动排序，顺序和可见性会跨启动保存。
- 数据源失败时保留最后一次成功值，显示过期状态，并采用有上限的退避重试。

### 5. 快捷工具

- `⌃⌥A`：打开 macOS 应用启动台，显示所有已安装应用图标。
- `⌃⌥S`：打开系统截图与录屏工具栏。
- 快捷键可在应用设置中修改。

## 数据来源与隐私

NotchHub 的主要统计都在本机完成：

- Codex 额度通过本机已认证的 `codex app-server` 只读接口获取。
- Token 统计只读取本机 Codex 会话日志，不上传日志内容。
- 内存与硬件状态来自 macOS 系统接口，不需要管理员权限。
- QQ 音乐曲目信息来自 macOS Now Playing；同步歌词匹配可能访问 LRCLIB。
- Tibo 硬重置信号来自 `tibo.modelyard.dev` 的公开结构化信息。

应用不会把 Codex 登录凭证、会话正文、个人额度历史或硬件历史提交到本仓库。更完整的边界说明见 [PRIVACY.md](PRIVACY.md)。

## 刷新频率与资源控制

- Codex 额度与本机 Token 增量统计：后台每 10 分钟；打开刘海或面板时按需刷新过期数据。
- 内存摘要：每 10 秒。
- 硬件详情：可见时通常每 5 秒；低电量、温控受限、隐藏或被遮挡时降至 15 秒；屏幕关闭或会话锁定时暂停。
- Tibo 硬重置检查：每小时一次，并在启动和唤醒后补查。

## 系统要求

- macOS 14 Sonoma 或更高版本。
- Apple Silicon 或 Intel Mac。
- 构建需要完整 Xcode；当前工程建议使用 Xcode 26 或更高版本。
- 使用 Codex 状态功能前，需要本机 Codex 已登录且 `codex app-server` 可用。

## 从源码构建

```bash
git clone https://github.com/huchongying/notch-hub-macos.git
cd notch-hub-macos
open boringNotch.xcodeproj
```

在 Xcode 中选择 `boringNotch` Scheme，按 `⌘R` 运行。也可以在终端执行无签名验证构建：

```bash
xcodebuild \
  -project boringNotch.xcodeproj \
  -scheme boringNotch \
  -configuration Release \
  -derivedDataPath /tmp/NotchHubDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

若要安装到“应用程序”，请先使用自己的开发者签名在 Xcode 中构建，再将生成的 `boringNotch.app` 复制到 `/Applications`。不要从陌生来源运行未经签名的二进制文件。

## 权限说明

不同功能可能请求以下 macOS 权限：

- 辅助功能：全局快捷键、媒体按键与部分系统交互。
- 通知：每日预算 100% / 150% 和确认后的硬重置提醒。
- 日历、提醒事项、相机：仅用于上游原有的对应功能，可不授权。
- 网络：同步歌词、更新检查与 Tibo 公开状态检查。

未授权某项权限时，只影响对应功能，不应阻止基础刘海和本地硬件监控运行。

## 主要代码位置

- `boringNotch/models/ResourceStatsViewModel.swift`：Codex 额度、预算、估算与 Tibo 状态。
- `boringNotch/models/CodexTokenStatsViewModel.swift`：本机 Token 增量与去重统计。
- `boringNotch/models/HardwareStatsViewModel.swift`：硬件采样与自适应刷新。
- `boringNotch/components/Hardware/HardwareDashboard.swift`：中文桌面面板与模块布局。
- `boringNotch/components/Notch/BoringHeader.swift`：刘海状态、详情和歌词优先级。
- `boringNotch/managers/MusicManager.swift`：QQ 音乐元数据和同步歌词。
- `BoringNotchXPCHelper/CodexRateLimitProbe.swift`：Codex 本地只读额度探测。

## 已知边界

- 本机 Token 统计不包含其他设备产生的精确用量；这部分只能根据额度变化估算，并明确标为未归因估算。
- Codex 服务返回结构变化时，额度探测可能暂时不可用；界面会保留最后成功值并标记过期。
- 同步歌词取决于曲目元数据匹配和可用歌词源，并非所有歌曲都能匹配。
- Tibo 信息只作为候选信号；预算重算仍以本地观察到的额度窗口变化为准。

## 上游、致谢与许可证

本项目直接基于 [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) 开发，保留其版权、第三方依赖声明和 GPL-3.0 许可证。特别感谢上游维护者，以及以下项目：

- [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)：macOS Now Playing 元数据适配。
- [NotchDrop](https://github.com/Lakr233/NotchDrop)：上游文件架功能的重要参考。
- [Codex Usage Bar](https://github.com/CMMUU/codex-usage-bar)：Codex 进程握手和可执行文件发现逻辑参考，遵循其 MIT 许可证。

完整声明见 [LICENSE](LICENSE) 与 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。提交改动前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
