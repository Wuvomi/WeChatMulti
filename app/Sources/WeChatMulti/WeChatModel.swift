import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class WeChatModel: ObservableObject {
    // 微信路径可配置（默认 /Applications/WeChat.app，找不到时让用户手动选）
    @Published var appPath: String =
        UserDefaults.standard.string(forKey: "wechatPath") ?? "/Applications/WeChat.app" {
        didSet { UserDefaults.standard.set(appPath, forKey: "wechatPath") }
    }

    /// 手动选择微信.app（非默认路径/克隆副本/多个微信时用）
    func chooseWeChatPath() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择微信 App")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            appPath = url.path
            refresh()
        }
    }

    @Published var version: String?
    @Published var build: String?
    @Published var signType: SignType = .unknown
    @Published var isSupported: Bool? = nil
    @Published var isPatched: Bool = false
    @Published var supportedBuilds: [String] = []
    @Published var log: String = ""

    private var configs: [[String: Any]] = []
    private var timer: Timer?
    @Published var instanceCount: Int = 0
    @Published var engineVersion: String?
    @Published var fdaOK = false
    @Published var screenOK = false
    @Published var permsReadable = false   // 能否读到 TCC.db（本工具需有全盘访问才能读）
    @Published var x1a0heInstalled = false
    @Published var x1a0heMultiOpenOn = false
    @Published var installing = false
    @Published var errorMessage: String?   // 仅真报错时弹窗（用户取消密码框不算）

    enum Engine { case none, weChatTweak, x1a0he }
    var activeEngine: Engine {
        if x1a0heInstalled && x1a0heMultiOpenOn { return .x1a0he }
        if isPatched { return .weChatTweak }
        return .none
    }
    var engineName: String {
        switch activeEngine {
        case .x1a0he: return "X1a0He"           // 品牌名，不翻译
        case .weChatTweak: return "WeChatTweak" // 品牌名，不翻译
        case .none: return ""
        }
    }
    var multiOpenActive: Bool { activeEngine != .none }
    let x1a0heVersion = "2.4.7"   // 内置 X1a0He pkg 版本

    /// 插件版本行：左灰标签固定"插件版本"，右值=版本号（方案名只在双开状态行显示）
    var engineRowLabel: String { "双开插件版本" }
    var engineRowValue: String {
        switch activeEngine {
        case .x1a0he: return x1a0heVersion
        case .weChatTweak: return engineVersion ?? "?"
        case .none: return "未安装"
        }
    }

    /// 自动按当前微信版本选最合适的引擎并应用：老版(在 WeChatTweak 支持表内)→byte-patch；否则→X1a0He 注入
    func installBestEngine() {
        guard let b = build else { errorMessage = "未检测到微信版本"; return }
        if supportedBuilds.contains(b) {
            patch()
        } else {
            installX1a0He()
        }
    }

    // MARK: - 版本兼容 / 自动下载替换微信

    /// 内置 X1a0He 2.4.7 支持的目标兼容版本（官方 CDN 链接，来自 X1a0He README）
    let targetVersion = "4.1.11.21"
    let targetBuild = 269077
    let targetDMG = "https://dldir1v6.qq.com/weixin/Universal/Mac/xWeChatMac_universal_4.1.11.21_40446.dmg"
    @Published var showDownloadConfirm = false

    enum Compat { case ok, appStore, tooHigh, notInstalled }
    var compat: Compat {
        if !appInstalled { return .notInstalled }
        if signType == .appStore { return .appStore }
        if let b = Int(build ?? ""), b > targetBuild { return .tooHigh }
        return .ok
    }
    var needsDownload: Bool { compat != .ok }
    var compatReason: String {
        switch compat {
        case .appStore:
            return "你正在用 App Store 版微信，它被 macOS 沙盒限制、插件无法注入，所以多开用不了。\n\n需下载官网版 \(targetVersion)（约 470MB）并替换。安装时会关闭微信，聊天记录不会丢失。"
        case .tooHigh:
            return "当前微信 \(version ?? "?")（\(build ?? "?")）比插件支持的最新版（\(targetVersion)）还新，暂时用不了。\n\n需下载兼容版 \(targetVersion)（约 470MB）并替换。安装时会关闭微信，聊天记录不会丢失。"
        case .notInstalled:
            return "未检测到微信，需下载官网版 \(targetVersion)（约 470MB）安装。聊天记录（若有）不会丢失。"
        case .ok: return ""
        }
    }

    /// 下载兼容版微信（无需密码）→ 关微信 → 覆盖安装（一次管理员密码）
    func downloadAndReplaceWeChat() {
        let url = targetDMG
        installing = true
        Task.detached {
            let tmp = "/tmp/WeChatMulti_wx.dmg"
            let dl = shellRun("/usr/bin/curl", ["-sL", "-m", "1800", "-o", tmp, url])
            guard dl.status == 0, FileManager.default.fileExists(atPath: tmp),
                  (try? FileManager.default.attributesOfItem(atPath: tmp)[.size] as? Int ?? 0) ?? 0 > 10_000_000 else {
                await MainActor.run { self.installing = false; self.errorMessage = "下载失败：\(dl.output)" }
                return
            }
            _ = shellRun("/usr/bin/osascript", ["-e", "tell application \"WeChat\" to quit"])
            _ = shellRun("/usr/bin/pkill", ["-f", "WeChat.app/Contents/MacOS"])
            let sh = """
            #!/bin/bash
            MP=$(hdiutil attach '\(tmp)' -nobrowse -readonly | grep -oE '/Volumes/.*' | tail -1)
            APP=$(ls -d "$MP"/*.app | head -1)
            rm -rf /Applications/WeChat.app
            ditto "$APP" /Applications/WeChat.app
            hdiutil detach "$MP" >/dev/null 2>&1
            rm -f '\(tmp)'
            echo OK
            """
            try? sh.write(toFile: "/tmp/wxinstall.sh", atomically: true, encoding: .utf8)
            let r = shellRun("/usr/bin/osascript",
                ["-e", "do shell script \"/bin/bash /tmp/wxinstall.sh\" with administrator privileges"])
            await MainActor.run {
                self.installing = false
                let cancelled = r.output.contains("-128") || r.output.contains("用户已取消")
                if !r.output.contains("OK") && !cancelled { self.errorMessage = "安装失败：\(r.output)" }
                self.refresh()
            }
        }
    }

    enum SignType: String {
        case unknown = "未知"
        case appStore = "App Store 版（不支持）"
        case developerID = "官网版（Developer ID）"
        case adhoc = "已 patch（ad-hoc 签名）"
    }

    var exePath: String { appPath + "/Contents/MacOS/WeChat" }
    var appInstalled: Bool { FileManager.default.fileExists(atPath: appPath) }

    // MARK: - 自动检测

    /// 启动自动、实时检测（无需手动刷新）
    func startAutoRefresh() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // 实例数变化即时响应：监听 App 启动/退出
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.countInstances() }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.countInstances() }
        }
    }

    func refresh() {
        guard appInstalled else {
            version = nil; build = nil; signType = .unknown; isPatched = false
            return
        }
        readVersion()
        readSign()
        readEngineVersion()
        detectX1a0He()
        countInstances()
        checkPermissions()
        if configs.isEmpty {
            Task { await fetchConfigAndDetect() }
        } else {
            detectPatched()
        }
    }

    private func countInstances() {
        instanceCount = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.tencent.xinWeChat" }.count
    }

    private func readEngineVersion() {
        guard engineVersion == nil else { return }
        let r = shellRun("/bin/ls", ["/opt/homebrew/Cellar/wechattweak"])
        if r.status == 0 {
            engineVersion = r.output.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// 读系统 TCC.db 判断微信是否已授权（本工具需有全盘访问才能读到 → 否则 permsReadable=false）
    private func checkPermissions() {
        let db = "/Library/Application Support/com.apple.TCC/TCC.db"
        let r = shellRun("/usr/bin/sqlite3", ["-readonly", db,
            "SELECT service,auth_value FROM access WHERE client='com.tencent.xinWeChat';"])
        guard r.status == 0 else { permsReadable = false; fdaOK = false; screenOK = false; return }
        permsReadable = true
        var fda = false, scr = false
        for line in r.output.split(separator: "\n") {
            let p = line.split(separator: "|")
            guard p.count >= 2 else { continue }
            let val = Int(p[1].trimmingCharacters(in: .whitespaces)) ?? 0
            if p[0].contains("AllFiles") { fda = val >= 2 }
            if p[0].contains("ScreenCapture") { scr = val >= 2 }
        }
        fdaOK = fda; screenOK = scr
    }

    private func readVersion() {
        if let dict = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") {
            version = dict["CFBundleShortVersionString"] as? String
            build = dict["CFBundleVersion"] as? String
        }
    }

    private func readSign() {
        let out = shellRun("/usr/bin/codesign", ["-dvvv", appPath]).output
        if out.contains("Signature=adhoc") {
            signType = .adhoc
        } else if out.contains("Apple Mac OS Application Signing") {
            signType = .appStore
        } else if out.contains("Developer ID Application") {
            signType = .developerID
        } else {
            signType = .unknown
        }
    }

    private func fetchConfigAndDetect() async {
        guard let url = URL(string: "https://raw.githubusercontent.com/sunnyyoung/WeChatTweak/refs/heads/master/config.json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let arr = (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            configs = arr
            supportedBuilds = arr.compactMap { $0["version"] as? String }
            if let b = build { isSupported = supportedBuilds.contains(b) }
            detectPatched()
        } catch {
            log += "拉取支持列表失败：\(error.localizedDescription)\n"
        }
    }

    private func detectPatched() {
        guard let b = build,
              let cfg = configs.first(where: { ($0["version"] as? String) == b }),
              let targets = cfg["targets"] as? [[String: Any]],
              let mi = targets.first(where: { ($0["identifier"] as? String) == "multiInstance" }),
              let entries = mi["entries"] as? [[String: Any]],
              let e = entries.first(where: { ($0["arch"] as? String) == "arm64" }),
              let addrStr = e["addr"] as? String, let asm = e["asm"] as? String,
              let addr = UInt64(addrStr, radix: 16),
              let sliceOff = arm64SliceOffset(exePath)
        else { isPatched = false; return }

        let fileOff = sliceOff + (addr - 0x1_0000_0000)
        if let bytes = readHexBytes(exePath, offset: fileOff, length: 8) {
            isPatched = bytes.lowercased() == asm.lowercased()
        }
    }

    // MARK: - 动作

    /// 微信官方仅本地化 简中/繁中/英文 → 映射系统语言；其它返回 nil（不强制，走微信默认）
    private func preferredWeChatLocale() -> String? {
        let p = (Locale.preferredLanguages.first ?? "").lowercased()
        if p.hasPrefix("zh-hant") || p.hasPrefix("zh-tw") || p.hasPrefix("zh-hk") || p.hasPrefix("zh-mo") {
            return "zh_TW.UTF-8"
        }
        if p.hasPrefix("zh") { return "zh_CN.UTF-8" }      // 简中及其它中文默认简中
        if p.hasPrefix("en") { return "en_US.UTF-8" }
        return nil
    }

    func openNewInstance() {
        guard appInstalled else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        // 按系统语言选 locale（微信官方仅本地化 简中/繁中/英文，其余不强制走默认）
        if let loc = preferredWeChatLocale() {
            cfg.environment = ["LANG": loc, "LC_ALL": loc]
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath),
                                           configuration: cfg) { _, err in
            if let err { Task { @MainActor in self.log += "开新微信失败：\(err.localizedDescription)\n" } }
        }
    }

    func patch() {
        installing = true
        Task.detached {
            let bin = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/wechattweak")
                ? "/opt/homebrew/bin/wechattweak" : "/usr/local/bin/wechattweak"
            let r = shellRun(bin, ["patch"])
            await MainActor.run {
                self.installing = false
                if r.status != 0 || r.output.contains("Error") { self.errorMessage = r.output }
                self.refresh()
            }
        }
    }

    private func detectX1a0He() {
        x1a0heInstalled =
            FileManager.default.fileExists(atPath: appPath + "/Contents/Resources/wechat.dylib.original")
            || FileManager.default.fileExists(atPath: appPath + "/Contents/Frameworks/X1a0HeWeChatPlugin.dylib")
        if x1a0heInstalled { ensureX1a0HeSettings() } else { x1a0heMultiOpenOn = false }
    }

    /// 自愈：装了 X1a0He 就必须确保「多开开关=开」+「一次性弹窗已埋」，否则显示"已生效"是欺骗用户
    private func ensureX1a0HeSettings() {
        func read(_ k: String) -> String {
            shellRun("/usr/bin/defaults", ["read", "com.tencent.xinWeChat", k])
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if read("X1a0HeWeChatPlugin_MultipleInstance") != "1" {
            _ = shellRun("/usr/bin/defaults", ["write", "com.tencent.xinWeChat",
                "X1a0HeWeChatPlugin_MultipleInstance", "-int", "1"])
        }
        x1a0heMultiOpenOn = true
        if read("X1a0HeWeChatPlugin_com.tencent.xinWeChat_LastHintVersion") != "2.4.7" {
            _ = shellRun("/usr/bin/defaults", ["write", "com.tencent.xinWeChat",
                "X1a0HeWeChatPlugin_com.tencent.xinWeChat_LastHintVersion", "-string", "2.4.7"])
        }
    }

    /// GUI 内一键启用 X1a0He 注入引擎：退微信 → 用内置 pkg 经管理员权限安装（弹原生密码框）
    func installX1a0He() {
        guard let pkg = Bundle.main.path(forResource: "X1a0HeWeChatPlugin", ofType: "pkg") else {
            errorMessage = "未找到内置 X1a0He 安装包"; return
        }
        installing = true
        Task.detached {
            _ = shellRun("/usr/bin/osascript", ["-e", "tell application \"WeChat\" to quit"])
            _ = shellRun("/usr/bin/pkill", ["-f", "WeChat.app/Contents/MacOS"])
            let script = "do shell script \"installer -pkg '\(pkg)' -target /\" with administrator privileges"
            let r = shellRun("/usr/bin/osascript", ["-e", script])
            let cancelled = r.output.contains("-128") || r.output.contains("用户已取消")
            if r.status == 0 {
                // 装完即开多开（主打功能不该默认关），并提前埋掉原作者一次性"已加载"弹窗（GUI 已标注作者）
                _ = shellRun("/usr/bin/defaults", ["write", "com.tencent.xinWeChat",
                    "X1a0HeWeChatPlugin_MultipleInstance", "-int", "1"])
                _ = shellRun("/usr/bin/defaults", ["write", "com.tencent.xinWeChat",
                    "X1a0HeWeChatPlugin_com.tencent.xinWeChat_LastHintVersion", "-string", "2.4.7"])
            }
            await MainActor.run {
                self.installing = false
                if r.status != 0 && !cancelled { self.errorMessage = r.output }
                self.refresh()
            }
        }
    }

    func openFullDiskAccessSettings() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    /// 截图依赖「屏幕录制」权限——提前授好，免得用时才退微信去设置
    func openScreenRecordingSettings() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func openURL(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - 全局工具（非隔离）

func shellRun(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "执行失败：\(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// 解析 fat 二进制，返回 arm64 slice 在文件中的偏移
func arm64SliceOffset(_ path: String) -> UInt64? {
    guard let data = FileManager.default.contents(atPath: path), data.count > 8 else { return nil }
    func be32(_ o: Int) -> UInt32 {
        (UInt32(data[o]) << 24) | (UInt32(data[o+1]) << 16) | (UInt32(data[o+2]) << 8) | UInt32(data[o+3])
    }
    guard be32(0) == 0xCAFE_BABE else { return nil }   // FAT_MAGIC (big-endian)
    let count = Int(be32(4))
    var off = 8
    for _ in 0..<count {
        guard off + 20 <= data.count else { break }
        let cputype = be32(off)
        let offset = be32(off + 8)
        if cputype == 0x0100_000C { return UInt64(offset) }  // CPU_TYPE_ARM64
        off += 20
    }
    return nil
}

func readHexBytes(_ path: String, offset: UInt64, length: Int) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    do {
        try fh.seek(toOffset: offset)
        let d = fh.readData(ofLength: length)
        return d.map { String(format: "%02x", $0) }.joined()
    } catch { return nil }
}
