# 贡献指南 / Contributing

欢迎通过 Issue 提交问题或功能建议，通过 Pull Request 提交改进。

## 本地开发

需要 macOS 14+、Swift 6.2+、Homebrew FFmpeg；运行 MCP 集成测试还需要 Python 3。

```sh
brew install ffmpeg
swift build
swift test
python3 scripts/test-mcp.py
./scripts/build-app.sh
```

转换测试生成临时媒体，不需要个人文件。`FlowHarness` 与 `FLOW_SUPPORT_DIRECTORY` 用于隔离测试数据，不随 APP 发布。

## 提交要求

- 说明具体问题、预期行为与验证方法。
- 修改转换或权限逻辑时，添加覆盖实际行为的测试。
- UI 改动请检查 macOS 最小窗口尺寸与长文件名；截图使用合成测试数据。
- 保持源文件不覆盖、MCP 默认关闭、显式目录授权与确认流程。
- 不提交个人媒体、绝对用户路径、密钥、客户端配置、调用日志或构建缓存。
- 更新依赖时同时检查 `Package.resolved`、最低 Swift 版本及 `LICENSES/`。

项目原创代码采用 MIT 许可证，提交前请确认有权贡献相关内容。安全问题请参阅 [SECURITY.md](SECURITY.md)。

English: Please describe the problem, resulting behavior, and validation in your pull request. Use synthetic fixtures, preserve the permission boundaries, and never include private files or credentials.
