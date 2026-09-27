# 安全报告 / Security

当前维护版本为 1.1.x。

如发现目录授权绕过、任意命令执行或其他安全问题，请使用仓库 **Security → Report a vulnerability** 私密报告。请勿在公开 Issue 中粘贴个人路径、媒体、日志或凭据。普通功能问题可提交 Issue。

报告建议包含：受影响版本、macOS / FFmpeg 版本、使用合成文件的最小复现、预期与实际行为。

## 边界

- MCP 默认关闭，读取与输出目录分别授权。
- 本地 stdio 辅助程序通过当前用户的 Unix socket 连接 APP；不提供远程网络服务。
- MCP 不提供 shell、任意 FFmpeg 参数、源文件删除、输出覆盖或引擎更新。
- 目录规则是应用层校验，不是操作系统沙箱；不能防御同一用户恶意进程的竞争修改。
- 媒体在本机处理；路径、媒体信息、状态及按需查询的日志会返回给所连接的 AI 客户端。

Please use GitHub private vulnerability reporting for security issues and synthetic files for reproduction. Do not include private media, paths, or credentials in public reports.
