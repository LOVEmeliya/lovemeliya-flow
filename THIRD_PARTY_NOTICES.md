# Third-party notices / 第三方声明

LOVEmeliya Flow 原创源码采用 MIT 许可证。本文件列出 `Package.resolved` 固定的第三方 Swift 包；源码通过 Swift Package Manager 获取，未修改上游源代码。

构建的 MCP 辅助程序静态链接依赖。发布 APP 的 `Contents/Resources/LICENSES/` 保留相应许可及 NOTICE 原文；依赖许可不被本项目 MIT 许可替代。

| 组件 | 固定版本 | 上游许可 | 许可文件 |
| --- | --- | --- | --- |
| [eventsource](https://github.com/mattt/eventsource) | 1.5.1 | MIT | [原文](LICENSES/eventsource/) |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 + Runtime Library Exception | [原文](LICENSES/swift-atomics/) |
| [swift-collections](https://github.com/apple/swift-collections) | 1.7.1 | Apache-2.0 + Runtime Library Exception | [原文](LICENSES/swift-collections/) |
| [swift-log](https://github.com/apple/swift-log) | 1.15.1 | Apache-2.0 | [原文](LICENSES/swift-log/) |
| [swift-nio](https://github.com/apple/swift-nio) | 2.103.0 | Apache-2.0 | [原文](LICENSES/swift-nio/) |
| [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | Apache-2.0 / MIT（上游过渡声明） | [原文](LICENSES/swift-sdk/) |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 + Runtime Library Exception | [原文](LICENSES/swift-system/) |

`swift-sdk` 的 LICENSE 包含上游从 MIT 转向 Apache-2.0 的说明及相关原文；具体适用范围以上游文本为准。SwiftNIO 的附带 `CNIOLLHTTP` 许可证一并保留。

## FFmpeg 与 ffprobe

本项目通过子进程调用用户安装的 FFmpeg / ffprobe，不附带这些可执行文件、不复制 FFmpeg 源码，也不链接 FFmpeg 库。它们不属于本项目 MIT 许可范围。FFmpeg 的许可随构建配置变化，详见 <https://ffmpeg.org/legal.html>；源码位于 <https://ffmpeg.org/download.html>。

## 系统组件

AppKit、SwiftUI、Foundation 等由 macOS 提供。应用图标由本仓库的 `scripts/generate-icon.swift` 绘制，没有额外图片、字体或媒体素材包。

## 维护

升级依赖时对照 `Package.resolved` 更新此表、许可与 NOTICE 原文，并重新打包。以上文件来自各固定提交的检出内容。
