import SwiftUI
import AppKit

@main
struct MediaFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore.shared
    var body: some Scene {
        WindowGroup(AppBrand.name) {
            ContentView().environmentObject(store)
                .frame(minWidth: 1040, minHeight: 700)
                .preferredColorScheme(.dark)
                .task { await store.bootstrap() }
                .onOpenURL { store.addURLs([$0]) }
        }
        .defaultSize(width: 1180, height: 790)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加文件…") { store.chooseFiles() }.keyboardShortcut("o")
            }
            CommandMenu("转换") {
                Button("开始转换") { store.startQueue() }.keyboardShortcut(.return, modifiers: .command).disabled(!store.canStart)
                Button("停止队列") { store.stopQueue() }.disabled(!store.isRunning)
                Divider()
                Button("引擎管理…") { store.showEngine = true }.keyboardShortcut(",")
                Button("AI 接入 · MCP…") { store.showAI = true }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) { AppStore.shared.addURLs(urls) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = AppStore.shared
        if store.maintenanceRunning {
            let alert = NSAlert(); alert.messageText = "FFmpeg 正在安装或更新"
            alert.informativeText = "请等待引擎维护结束后退出。"; alert.addButton(withTitle: "返回应用"); alert.runModal()
            return .terminateCancel
        }
        guard store.isRunning else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "转换还在进行"
        alert.informativeText = "停止后，已完成的文件会保留，未开始的任务会保存在队列中。"
        alert.addButton(withTitle: "继续转换"); alert.addButton(withTitle: "停止并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        store.stopQueue()
        Task {
            while store.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
