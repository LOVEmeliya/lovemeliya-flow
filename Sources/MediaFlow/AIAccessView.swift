import SwiftUI
import AppKit
import FlowService

struct AIAccessView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI 接入 · MCP").font(.system(size: 22, weight: .semibold))
                    Text("让 AI 提交任务，在这里查看、确认与接手。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("启用本地 MCP").font(.system(size: 14, weight: .semibold))
                            Text(store.service.policy.enabled ? "已启用 · 仅授权目录可用" : "已关闭 · AI 只能查询服务能力").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Toggle("启用 MCP", isOn: Binding(get: { store.service.policy.enabled }, set: { value in store.updatePolicy { $0.enabled = value } })).labelsHidden().toggleStyle(.switch)
                    }
                    Text("媒体留在本机转换。文件名、路径、媒体信息和按需读取的日志会返回给所连接的 AI 客户端；具体模型服务由该客户端决定。").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("执行方式").font(.system(size: 12, weight: .semibold))
                        Picker("执行方式", selection: Binding(get: { store.service.policy.requireApproval }, set: { value in store.updatePolicy { $0.requireApproval = value } })) {
                            Text("先加入待确认队列").tag(true)
                            Text("授权目录内直接执行").tag(false)
                        }.pickerStyle(.segmented).labelsHidden()
                        Text("关闭 MCP 或撤销目录会取消失去权限的 AI 任务。已完成的文件保留；修改为直接执行不会自动放行已有待确认任务。").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    directorySection(write: false)
                    directorySection(write: true)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("连接配置").font(.system(size: 13, weight: .semibold)); Spacer(); Button(copied ? "已复制" : "复制 JSON 配置") { store.copyMCPConfig(); copied = true } }
                        Text("将下列程序配置为 AI 客户端的本地 stdio MCP 服务。APP 未运行时会自动打开；退出 APP 前会提示处理正在转换的任务。").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        ScrollView(.horizontal) { Text(store.mcpConfig).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(12) }.background(Palette.background, in: RoundedRectangle(cornerRadius: 9))
                        HStack { Button("检查本地连接") { Task { await store.checkMCPBridge() } }; Text(store.bridgeMessage).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2) }
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            let count = store.service.clients.values.filter { context.date.timeIntervalSince($0) < 45 }.count
                            Label("\(count) 个活跃 MCP 连接", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 11)).foregroundStyle(count > 0 ? Palette.accent : Palette.muted)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("开放能力").font(.system(size: 13, weight: .semibold))
                        Text("能力查询 · 媒体检查 · 方案预检 · 提交批次 · 查询进度 · 列出任务 · 取消 AI 任务").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        Text("不开放任意命令、网络媒体、源文件删除、输出覆盖或引擎更新。批次最多 20 个文件，输入必须显式指定；目录授权包含其子目录。").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近调用").font(.system(size: 13, weight: .semibold))
                        if store.service.audit.isEmpty { Text("还没有工具调用记录。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                        ForEach(store.service.audit.suffix(12).reversed()) { entry in
                            HStack(spacing: 10) {
                                Text(entry.date, style: .time).frame(width: 72, alignment: .leading)
                                Text(entry.client).lineLimit(1).frame(width: 100, alignment: .leading)
                                Text(entry.tool).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                                Spacer(); Text(entry.outcome).lineLimit(1).foregroundStyle(entry.outcome == "成功" ? .green : .orange)
                            }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                    }
                }.padding(24)
            }.scrollIndicators(.visible)
        }.frame(width: 740, height: 650).background(Palette.sidebar).tint(Palette.accent)
    }
    private func directorySection(write: Bool) -> some View {
        let paths = write ? store.service.policy.writeDirectories : store.service.policy.readDirectories
        return VStack(alignment: .leading, spacing: 10) {
            HStack { Label(write ? "允许写入结果的目录" : "允许读取媒体的目录", systemImage: write ? "folder.badge.plus" : "folder").font(.system(size: 12, weight: .semibold)); Spacer(); Button("添加目录…") { store.chooseAIDirectory(write: write) } }
            if paths.isEmpty { Text("尚未授权，AI 无法\(write ? "保存输出" : "读取媒体")。").font(.system(size: 11)).foregroundStyle(.orange) }
            ForEach(paths, id: \.self) { path in
                HStack {
                    Text(path).font(.system(size: 10, design: .monospaced)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button { store.updatePolicy { if write { $0.writeDirectories.removeAll { $0 == path } } else { $0.readDirectories.removeAll { $0 == path } } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("撤销此目录授权")
                }.padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
