# LOVEmeliya Flow

面向日常使用的开源 macOS 音视频转换工具。SwiftUI 原生界面，独立调用本机 FFmpeg 与 ffprobe，不上传媒体文件；内置本地 MCP，支持 AI 提交任务与查询结果。

Native macOS media converter with a shared GUI/MCP task queue. Local processing, explicit directory permissions, and no accounts or media uploads. Project code is MIT licensed; third-party licenses are preserved separately.

[下载最新版本](https://github.com/LOVEmeliya/lovemeliya-flow/releases/latest) · [报告问题](https://github.com/LOVEmeliya/lovemeliya-flow/issues) · [贡献指南](CONTRIBUTING.md) · [许可证](LICENSE)

## 安装与快速开始

- **系统：** macOS 14 或更高版本。发布包为 Apple Silicon（arm64）；Intel Mac 暂未验证。
- **引擎：** 需要单独安装 FFmpeg，例如 `brew install ffmpeg`；应用不附带 FFmpeg。
- **下载：** 从 Releases 下载 ZIP，解压后将 `LOVEmeliya Flow.app` 放入“应用程序”目录。发布包仅作 ad-hoc 签名，尚未进行 Apple 公证；也可按下方步骤自行构建。
- **AI：** 可选功能，默认关闭；从侧栏“AI 接入 · MCP”配置。

从源码构建需要 macOS、Swift 6.2+（已在 Swift 6.3.3 验证）、Xcode 或对应 Command Line Tools。当前锁定的部分传递依赖要求 Swift 6.2。

```sh
git clone https://github.com/LOVEmeliya/lovemeliya-flow.git
cd lovemeliya-flow
brew install ffmpeg
./scripts/build-app.sh
open "dist/LOVEmeliya Flow.app"
```

`Package.resolved` 锁定依赖版本。构建和下载均不需要账户、API Key 或云服务。

## 打开应用

构建好的应用在 `dist/LOVEmeliya Flow.app`，双击即可打开。当前构建适用于 Apple Silicon Mac；最低系统版本为 macOS 14。

1. 添加或拖入音视频文件。
2. 在右侧选择视频、音频或换封装，并选择格式、质量和保存位置。
3. 点击“开始转换”。手动待处理文件使用右侧设置，按顺序处理；AI 任务保留各自的设置。
4. 完成后点击任务上的文件夹图标，在 Finder 中查看结果。

默认输出到每个源文件旁的“LOVEmeliya Flow 输出”文件夹，也可以指定统一目录。输出使用 `原文件名.目标扩展名`；同名时自动添加 `_2`、`_3`，不覆盖原文件。转换先写入隐藏临时文件，成功后才移到最终文件名，失败或取消时清理临时输出。

队列和设置保存在 `~/Library/Application Support/MediaFlow/`。品牌改名后沿用原存储位置和应用标识，保留已有设置、队列和输出记录。退出后重新打开会恢复记录；中断任务可重新转换。移除队列记录不会删除源文件或已完成的输出。

## 功能

- MP4（H.264）、轻量 MP4、HEVC（H.265）、WebM（VP9）视频转换。
- MP3、M4A、WAV（16-bit PCM）、FLAC 音频转换及提取。
- MP4 / MKV 直接复制码流换封装。
- 质量预设、最大分辨率、保留或移除音频。
- H.264 / HEVC 可选择 Apple VideoToolbox 硬件编码。
- 转码时按秒数或 `HH:MM:SS` 截取片段。
- 顺序任务队列、实时进度、速度和预计剩余时间、取消当前任务、停止队列、重试、日志与命令复制。
- 引擎检测、自定义路径、通过 Homebrew 安装或更新 FFmpeg。

## 引擎

默认检测 `/opt/homebrew/bin/ffmpeg`、`/usr/local/bin/ffmpeg` 和运行环境 PATH。自定义时选择 `ffmpeg` 文件，同目录必须有可运行的 `ffprobe`。

应用内“FFmpeg 引擎”支持调用 Homebrew 安装或更新：

```sh
brew install ffmpeg
# 已安装后
brew upgrade ffmpeg
```

更新会修改本机共用的 Homebrew FFmpeg，也可能更新依赖。维护期间不能开始转换。本版没有内置 FFmpeg 下载器或一键版本回退。

## 当前边界

- 视频转码不导出字幕；保留全部音轨，但转为双声道。音频提取使用第一条音轨。
- MKV 换封装复制音视频、字幕与附件；MP4 换封装只复制音视频。原始编码必须兼容输出容器。
- 换封装不支持精确截取；截取需要选择重新编码的预设。
- 检测到 PQ / HLG HDR 视频时阻止转码，避免错误转换颜色；可使用换封装保留原始视频。尚未实现 HDR 色调映射。
- 暂不支持字幕烧录、多文件合并、自定义编码参数或目标文件大小。
- 质量预设不保证每个源文件都能变小；尤其是从已高度压缩的文件转换时。

## 开发与验证

要求 Xcode / Command Line Tools 和 Swift 6.2+。MCP 辅助程序使用官方 Swift SDK，版本见 Package.resolved。

```sh
swift test
python3 scripts/test-mcp.py
./scripts/build-app.sh
./scripts/package-release.sh
```

构建脚本生成图标、release 可执行文件和 `.app`，附带许可证及第三方声明，并进行本地 ad-hoc 签名。打包脚本生成 ZIP 和 SHA-256 校验文件；未进行 Apple 公证。

测试覆盖参数边界、时间解析、无覆盖命名、HDR 和媒体流验证、进度解析，以及真实 FFmpeg 的十种预设、VideoToolbox、截取、静音、取消和超时。引擎集成测试需要本机 Homebrew FFmpeg。

GitHub Actions 在 macOS 上验证构建、软件编码转换与 MCP 集成。虚拟运行器跳过 VideoToolbox 硬件测试；该测试需在支持硬件编码的 Mac 上运行完整 `swift test`。

### 1.1.0

- 新增本地 stdio MCP 与七个工具，共用 APP 转换队列。
- 新增目录授权、待确认模式、AI 任务标识和工具调用记录。
- 支持批次预检、幂等提交、独立音频参数及实际输出信息。
- 首个公开源码版本；发布说明见 [1.1.0](docs/releases/1.1.0.md)。

### 1.0.2

- 应用更名为 LOVEmeliya Flow，更新品牌标识、窗口、图标、关于信息与默认输出文件夹。
- 修复省略号菜单与系统下拉箭头重叠，扩大按钮点击区域。
- 为长文件名、任务状态与操作按钮分别保留空间。
- 设置区域可独立滚动，滚动条可见；底部开始按钮独立分区，不遮挡设置。
- 限制最小窗口大小，改善窄窗口与日志标题的排版。

### 1.0.1

- 移除文件名中重复的预设标签：`片段_wav.wav` 改为 `片段.wav`。
- 同名输出继续自动编号；重新导入输出文件不会叠加格式标签。

## AI 接入 / MCP（1.1.0）

侧栏进入 **AI 接入 · MCP**：

1. 添加允许读取媒体的目录、允许写入结果的目录（含子目录）。默认不授权任何目录。
2. 开启 MCP，选择“先加入待确认队列”或“授权目录内直接执行”。
3. 复制页面中的 JSON 配置到 AI 客户端的本地 stdio MCP 配置中；程序为 APP 内的 `Contents/MacOS/lovemeliya-flow-mcp`，参数为 `--stdio`。
4. 如果客户端要求分别填写，名称为 `lovemeliya-flow`，命令使用页面中的完整路径，参数为 `--stdio`。无需端口、URL、Node、Python 或 API Key。

应用移动位置后重新复制配置。此版本不提供远程 HTTP MCP；必须由当前 Mac 上的客户端启动本地程序。应用不会自动修改任何 AI 客户端的配置。

### 工具

| 工具 | 作用 |
| --- | --- |
| `flow_capabilities` | 能力、引擎、预设与目录授权查询，禁用 MCP 时也能调用 |
| `flow_inspect` | 单个文件的媒体信息，包括采样率、声道、HDR |
| `flow_plan` | 校验最多 20 个显式文件，保存有效期 15 分钟的方案，不转换文件 |
| `flow_submit` | 使用 `plan_id` 与稳定的 `request_id` 提交批次 |
| `flow_get_job` | 查询进度、实际输出路径、输出媒体信息与结构化错误 |
| `flow_list_jobs` | 按来源、状态、批次分页查询；默认只列出 AI 任务 |
| `flow_cancel` | 取消一个 AI 任务或批次，不取消手动任务、不删除已完成文件 |

调用流程：`flow_capabilities` → `flow_inspect`（可选）→ `flow_plan` → `flow_submit` → `flow_get_job`。推荐每 2–5 秒查询一次进度。

`flow_plan` 示例：

```json
{
  "inputs": ["/已授权目录/录音.caf"],
  "preset": "wav",
  "audio": {"sample_rate": "source", "channels": "source"},
  "output_directory": "/已授权输出目录",
  "existing_file": "rename"
}
```

- `audio.sample_rate` 可选 `source` 或 8000、16000、22050、24000、32000、44100、48000、96000；具体编码器还会检查兼容性。
- `audio.channels` 可选 `source` 或 1、2、6、8；MP3 最多双声道。
- 未指定音频选项时沿用原预设：WAV/FLAC 保持来源；MP3 默认为 44100 Hz 双声道；M4A/视频音频默认双声道。
- 每个文件有独立设置；不同采样率和声道的文件可以在同一个 `source` 批次中保持各自参数。
- `start_seconds`、`end_seconds` 使用非负秒数；其他选项为 `quality`、`resolution`、`hardware`、`include_audio`。
- 方案里的输出名为预览，真正执行时仍检查重名并编号。方案检查源文件大小、修改时间和 inode；变化后须重新生成方案。
- 重试同一提交时必须复用 `request_id`。同一方案即使换了请求编号，也只会创建一次批次。去重记录持久保存。

### 队列、生命周期与权限

GUI 和 MCP 共用 `FlowService.TaskService`，转换在 APP 中执行。stdio 辅助程序通过仅当前用户可用的 Unix socket 通信，没有 TCP 监听端口。socket 目录权限 0700、socket 权限 0600，并校验 peer UID；客户端报告的名称仅用于展示与去重，不是独立安全身份。

AI 断开不会取消已提交任务。APP 未运行时辅助程序会自动打开同一个 APP。退出正在转换的 APP 会询问是否停止；中断的 AI 任务在重启后回到待确认状态，不自动重新开始。待确认任务也可在卡片上取消。手动任务的右侧设置不受 AI 提交影响，AI 提交不会启动手动待处理项。

权限在检查、提交和执行时重新校验。路径解析包含符号链接和 `..`，拒绝目录边界外访问。MCP 限制 FFmpeg 协议与解封装器，不接受网络媒体、播放列表、脚本、任意命令或图片序列。MCP 只能使用应用已配置的引擎，不能更新它。目录授权不是操作系统沙箱，也不防御同一用户的恶意本地进程竞争更改文件或权限。

默认不向 AI 返回媒体内容，只返回路径、元数据、状态和按需读取的最多 8000 字符日志。上述信息会进入所连接的 AI 客户端。最近 200 次工具调用记录保存在本机。

任务、方案和去重记录保存于 `service.json`；首次运行自动读取旧 `queue.json`。原文件保留以便回退。新权限文件为 `ai-policy.json`，调用记录为 `ai-audit.json`，均位于原有 Application Support/MediaFlow 目录。关闭 MCP 不清除历史任务。

### 开发验证

MCP SDK 固定为官方 Swift SDK 0.12.1，依赖锁定于 `Package.resolved`；整个项目使用当前锁定依赖构建时需要 Swift 6.2+。原 GUI/转换核心无需额外运行时，MCP helper 静态链接 Swift 包依赖。

```sh
swift build
swift test
python3 scripts/test-mcp.py
./scripts/build-app.sh
```

`FlowHarness` 仅供隔离端到端测试，不进入 APP 包。测试使用临时的 `FLOW_SUPPORT_DIRECTORY`，不修改真实用户的队列与权限。`FLOW_NO_AUTO_LAUNCH=1` 禁止测试客户端启动真实 APP。这两个环境变量不应加入正常客户端配置。

实际测试涵盖 MCP initialize / tools/list / tools/call、七个工具、结构化错误、WAV 转换、断开重连、提交去重、运行任务取消、stdout 纯 JSON 与 EOF 退出；Swift 测试还覆盖目录与符号链接边界、旧记录迁移、手动/AI 队列隔离和确认流程。

## 许可证与第三方组件

本项目原创源码采用 [MIT License](LICENSE)，Copyright © 2026 LOVEmeliya。第三方代码保留其原始许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 [LICENSES](LICENSES)。

FFmpeg / ffprobe 由用户独立安装，应用通过子进程调用，不捆绑其可执行文件或链接其库。FFmpeg 的许可取决于其构建配置，参见 [FFmpeg 官方许可说明](https://ffmpeg.org/legal.html)。
