import SwiftUI
import AppKit

@main
struct WeChatMultiApp: App {
    @StateObject private var model = WeChatModel()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        Window(Text("微信多开工具"), id: "main") {
            ContentView(model: model)
                .frame(width: 360)
                .onAppear { model.startAutoRefresh() }
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContent(model: model)
        } label: {
            Image(nsImage: Self.menuBarImage)
        }
    }

    static var menuBarImage: NSImage {
        // 用数字图标(语言中立)，多语言泛用
        let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let img = (NSImage(systemSymbolName: "3.square.fill", accessibilityDescription: "多开")?
            .withSymbolConfiguration(cfg)) ?? NSImage()
        img.isTemplate = true
        return img
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: WeChatModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("➕ 多开一个新微信") { model.openNewInstance() }
            .keyboardShortcut("n")
            .disabled(!model.appInstalled)

        Divider()

        if let v = model.version {
            Text(String(localized: "微信 \(v) · build \(model.build ?? "?") · 运行中 \(model.instanceCount)"))
            Text(model.multiOpenActive
                 ? String(localized: "✅ 多开已启用")
                 : String(localized: "⚠️ 多开未启用"))
        } else {
            Text("未检测到微信")
        }

        Divider()

        Button("主界面") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("退出") { NSApp.terminate(nil) }
    }
}
