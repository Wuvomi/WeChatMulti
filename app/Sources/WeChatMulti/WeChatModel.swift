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
    @Published var permsReadable = false   // 能否读到权限（自研引擎在场时读容器内 perms.json）
    @Published var x1a0heInstalled = false
    @Published var x1a0heMultiOpenOn = false
    @Published var ourEngineInstalled = false   // 自研引擎是否已装入当前微信
    @Published var installing = false
    @Published var errorMessage: String?   // 仅真报错时弹窗（用户取消密码框不算）
    @Published var updateMessage: String?  // 检测更新结果（弹窗）
    @Published var updateAvailable = false  // 有新版本可一键更新
    private var latestDMGURL: String?       // 新版本 DMG 直链（资产）

    static let repoURL = "https://github.com/Wuvomi/WeChatMulti"
    static let releasesAPI = "https://api.github.com/repos/Wuvomi/WeChatMulti/releases/latest"

    /// 从 GitHub releases 检测新版本：比对 tag 与本机 CFBundleShortVersionString。
    func checkForUpdate() {
        updateMessage = String(localized: "正在检查更新…")
        updateAvailable = false
        Task { @MainActor in
            guard let url = URL(string: Self.releasesAPI) else { return }
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200,
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    updateMessage = String(localized: "检查更新失败（可能仓库尚未公开）。")
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                if latest.compare(current, options: .numeric) == .orderedDescending {
                    if let assets = obj["assets"] as? [[String: Any]],
                       let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                       let durl = dmg["browser_download_url"] as? String {
                        latestDMGURL = durl
                        updateAvailable = true
                    }
                    updateMessage = String(localized: "发现新版本 \(tag)！可一键更新，或前往主页手动下载。")
                } else {
                    updateMessage = String(localized: "已是最新版本（\(current)）。")
                }
            } catch {
                updateMessage = String(localized: "检查更新失败：\(error.localizedDescription)")
            }
        }
    }

    /// 自主更新：下载新版 DMG → 脱离本进程的脚本等本 app 退出后替换并重启。
    func installUpdate() {
        guard let dmgURL = latestDMGURL else { return }
        let appPath = Bundle.main.bundlePath
        installing = true; updateMessage = nil; updateAvailable = false
        Task.detached {
            let tmp = "/tmp/WeChatMulti_update.dmg"
            let dl = shellRun("/usr/bin/curl", ["-sL", "-m", "600", "-o", tmp, dmgURL])
            guard dl.status == 0, FileManager.default.fileExists(atPath: tmp) else {
                await MainActor.run { self.installing = false
                    self.errorMessage = String(localized: "下载更新失败：\(dl.output)") }
                return
            }
            // 脱离脚本：等本 app 退出 → 挂载 → 替换 .app → 清隔离 → 重启 → 卸载/清理。
            let script = """
            #!/bin/bash
            sleep 1
            while pgrep -f '\(appPath)/Contents/MacOS/' >/dev/null; do sleep 0.5; done
            MP=$(hdiutil attach '\(tmp)' -nobrowse 2>/dev/null | grep -oE '/Volumes/[^[:space:]]+' | tail -1)
            NEW=$(ls -d "$MP"/*.app 2>/dev/null | head -1)
            if [ -n "$NEW" ]; then
              rm -rf '\(appPath)'
              ditto "$NEW" '\(appPath)'
              xattr -dr com.apple.quarantine '\(appPath)' 2>/dev/null
              hdiutil detach "$MP" >/dev/null 2>&1
              open '\(appPath)'
            fi
            rm -f '\(tmp)'
            """
            let sp = "/tmp/WeChatMulti_update.sh"
            try? script.write(toFile: sp, atomically: true, encoding: .utf8)
            _ = shellRun("/bin/chmod", ["+x", sp])
            _ = shellRun("/bin/bash", ["-c", "nohup /bin/bash '\(sp)' >/dev/null 2>&1 &"])
            await MainActor.run { NSApp.terminate(nil) }   // 退出自身,让脚本接管替换+重启
        }
    }

    func openRepoPage() {
        if let url = URL(string: Self.repoURL) { NSWorkspace.shared.open(url) }
    }

    // MARK: - bundleID 终极兜底（克隆）状态
    @Published var existingCloneCount = 0   // 已存在克隆总数(不论是否在跑)，N=1..K
    @Published var runningCloneCount = 0    // 在跑克隆数(pgrep 克隆 exec 路径)
    @Published var showCloneManager = false // 「管理克隆」次级面板开关
    @Published var needFDAForCleanup = false // 清理克隆需 FDA 但未授予 → 引导授权

    enum Engine { case none, weChatTweak, x1a0he, ourOwn, bundleIDClone }
    /// 检测优先级：自研引擎 > X1a0He > WeChatTweak（谁真装了显示谁）。
    /// bundleID 克隆是【终极兜底】——只在没有任何注入引擎生效、但有克隆在跑时才作为
    /// 「当前生效方案」显示，绝不抢注入引擎的显示位（注入正常时仍显注入引擎）。
    var activeEngine: Engine {
        if ourEngineInstalled { return .ourOwn }
        if x1a0heInstalled && x1a0heMultiOpenOn { return .x1a0he }
        if isPatched { return .weChatTweak }
        if runningCloneCount > 0 { return .bundleIDClone }   // 注入全无、但有克隆在跑 → 兜底方案生效中
        return .none
    }
    var engineName: String {
        switch activeEngine {
        case .ourOwn: return String(localized: "自研引擎")
        case .x1a0he: return "X1a0He"           // 品牌名，不翻译
        case .weChatTweak: return "WeChatTweak" // 品牌名，不翻译
        case .bundleIDClone: return String(localized: "BundleID")
        case .none: return ""
        }
    }
    /// 终极兜底模式：所有注入方案都不适用（当前判据=App Store 沙盒版，无法注入）→ 只能用 BundleID 克隆。
    /// 此模式：主按钮变紫「新开一个独立副本」、双开状态显"未生效（BundleID 临时方案）"、
    /// 隐藏权限行、"已打开的微信"行右侧出"清理全部克隆"。
    var cloneMode: Bool { appInstalled && signType == .appStore }
    var multiOpenActive: Bool { activeEngine != .none }
    let x1a0heVersion = "2.4.7"   // 内置 X1a0He pkg 版本
    let selfEngineVersion = "0.9.0"   // 自研引擎随本工具版本

    /// 插件版本行：左灰标签固定"插件版本"，右值=版本号（方案名只在双开状态行显示）
    var engineRowLabel: String { String(localized: "双开插件版本") }
    var engineRowValue: String {
        switch activeEngine {
        case .ourOwn: return selfEngineVersion
        case .x1a0he: return x1a0heVersion
        case .weChatTweak: return engineVersion ?? "?"
        case .bundleIDClone: return selfEngineVersion   // 克隆兜底用本工具自己的克隆引擎
        case .none: return String(localized: "未安装")
        }
    }

    /// 没装任何引擎时的默认动作：优先自研引擎（实验），失败/不适用再回退老链路。
    /// 注意：已装 X1a0He 时此方法不会被当作"替换"入口（UI 在已装时走 reinstall 同款方案，
    /// 改用自研引擎是独立的次级动作 switchToSelfEngine()，避免误替换用户在用的 X1a0He）。
    func installBestEngine() {
        // 已装某引擎 → 维持同款方案重装，不擅自切换。
        switch activeEngine {
        case .ourOwn:  installSelfEngine(); return
        case .x1a0he:  installX1a0He();     return
        case .weChatTweak: patch();         return
        // .bundleIDClone = 只有克隆在跑、无注入引擎；安装按钮意在装注入引擎 → 当全新安装处理。
        case .none, .bundleIDClone: break
        }
        // 全新安装的推荐链：旧版微信 → WeChatTweak（最早的静态注入）；新版 → 自研引擎（主）。
        // （X1a0He 作为手动 fallback，通过独立入口选择，不在自动推荐里。）
        if let b = build, supportedBuilds.contains(b) { patch() }
        else { installSelfEngine() }
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
            return String(localized: "你正在用 App Store 版微信，它被 macOS 沙盒限制、插件无法注入，所以多开用不了。\n\n需下载官网版 \(targetVersion)（约 470MB）并替换。安装时会关闭微信，聊天记录不会丢失。")
        case .tooHigh:
            return String(localized: "当前微信 \(version ?? "?")（\(build ?? "?")）比插件支持的最新版（\(targetVersion)）还新，暂时用不了。\n\n需下载兼容版 \(targetVersion)（约 470MB）并替换。安装时会关闭微信，聊天记录不会丢失。")
        case .notInstalled:
            return String(localized: "未检测到微信，需下载官网版 \(targetVersion)（约 470MB）安装。聊天记录（若有）不会丢失。")
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
                await MainActor.run { self.installing = false; self.errorMessage = String(localized: "下载失败：\(dl.output)") }
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
                if !r.output.contains("OK") && !cancelled { self.errorMessage = String(localized: "安装失败：\(r.output)") }
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
            Task { @MainActor in self?.refreshLive() }
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
        detectSelfEngine()
        detectX1a0He()
        scanClones()
        countInstances()
        checkPermissions()
        if configs.isEmpty {
            Task { await fetchConfigAndDetect() }
        } else {
            detectPatched()
        }
        if onlineReleaseDates.isEmpty {
            Task { await fetchReleaseDates() }
        }
    }

    /// 轻量刷新（定时器每 2 秒）：只更新动态项——版本号(plist)、克隆/实例计数、权限(perms.json)。
    /// 不跑重子进程检测(codesign/otool/defaults)——那些引擎/签名态只在加载和安装动作后由 refresh() 跑，
    /// 各安装方法完成时已调 refresh()，故此处省去即可，避免每 2 秒在主线程串行 spawn 多个子进程卡 UI。
    func refreshLive() {
        guard appInstalled else { return }
        readVersion()
        scanClones()
        countInstances()
        checkPermissions()
    }

    /// 可选增强：异步拉一次在线「版本→发布月」map 覆盖/扩展内置。
    /// 拉不到/解析失败就静默保留内置数据，绝不阻塞 UI、绝不弹错。格式见 VERSION_DATES.md。
    private func fetchReleaseDates() async {
        guard let url = URL(string:
            "https://raw.githubusercontent.com/zsbai/wechat-versions/master/mac-release-dates.json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // 期望形如 { "4.1.11": "2026-06", ... }；非法/空就忽略。
            if let map = try JSONSerialization.jsonObject(with: data) as? [String: String], !map.isEmpty {
                onlineReleaseDates = map
            }
        } catch {
            // 静默：离线/404/格式不对都用内置数据兜底，不打扰用户
        }
    }

    private func countInstances() {
        // N = 在跑实例总数 = 原版微信(含注入多开) + 在跑克隆。克隆 bundleId 各异，
        // 用 pgrep exec 路径数(scanClones 已算好的 runningCloneCount)叠加。
        let orig = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.tencent.xinWeChat" }.count
        instanceCount = orig + runningCloneCount
    }

    // MARK: - bundleID 终极兜底（克隆管理）
    //
    // 克隆=独立 .app + 独立 bundleId(com.tencent.xinCloneN) + 独立沙盒/group 容器，
    // 版本无关、永不失效的终极兜底。所有逻辑仅调 engine/install-clone.sh、cleanup-clone.sh，
    // 不在 GUI 内重复签名/容器逻辑。本入口独立于主多开流程(open -n + 注入)，不替换它。

    /// 克隆存放目录（与 install-clone.sh 默认一致，自动创建）
    var cloneDir: String { NSHomeDirectory() + "/Library/Application Support/WeChatMulti/Clones" }
    private func cloneAppPath(_ n: Int) -> String { cloneDir + "/WeChatClone\(n).app" }
    private func cloneExecPath(_ n: Int) -> String { cloneAppPath(n) + "/Contents/MacOS/WeChat" }

    /// 已存在的克隆尾号集合（glob 扫目录下所有 WeChatCloneN.app，升序）。
    /// 用 glob 而非"连续遇洞即止"：用户在访达手动删了中间某个克隆(留洞)时，
    /// 仍能扫到洞后面的克隆 → 计数准确、清理不漏、不会有删不掉的残留。
    private func existingCloneNumbers() -> [Int] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: cloneDir) else { return [] }
        return entries.compactMap { name -> Int? in
            guard name.hasPrefix("WeChatClone"), name.hasSuffix(".app") else { return nil }
            let mid = name.dropFirst("WeChatClone".count).dropLast(".app".count)
            guard let n = Int(mid), n >= 1 else { return nil }
            return n
        }.sorted()
    }

    /// 某克隆是否在跑：pgrep 其 exec 路径（克隆 bundleId 各异，NSWorkspace 按 bundleId 不好枚举，用进程路径最稳）。
    private func cloneRunning(_ n: Int) -> Bool {
        shellRun("/usr/bin/pgrep", ["-f", cloneExecPath(n)]).status == 0
    }

    /// 扫描克隆，更新 existingCloneCount / runningCloneCount。
    private func scanClones() {
        let nums = existingCloneNumbers()
        existingCloneCount = nums.count
        runningCloneCount = nums.filter { cloneRunning($0) }.count
    }

    /// 尾号复用：启动最小的「存在但没在跑」的克隆；1..K 全在跑才新建 Clone(K+1)。
    /// 尾号只在全占满时 +1，先用完前面的再推进 → 克隆数收敛到历史最大同时实例数，不无限膨胀。
    func openCloneInstance() {
        guard appInstalled else { errorMessage = String(localized: "未检测到微信"); return }
        let nums = existingCloneNumbers()
        // 找最小的「存在但没在跑」
        if let reuse = nums.first(where: { !cloneRunning($0) }) {
            launchClone(reuse)
            return
        }
        // 1..K 全在跑（或一个都没有）→ 新建 K+1
        let next = (nums.max() ?? 0) + 1
        installAndLaunchClone(next)
    }

    /// 直接启动已存在的克隆（复用尾号，无需重建）。
    private func launchClone(_ n: Int) {
        let app = cloneAppPath(n)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        if let loc = preferredWeChatLocale() {
            cfg.environment = ["LANG": loc, "LC_ALL": loc]
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: cfg) { _, err in
            Task { @MainActor in
                if let err { self.log += "启动克隆\(n)失败：\(err.localizedDescription)\n" }
                self.scanClones(); self.countInstances()
            }
        }
    }

    /// 新建克隆（调 install-clone.sh，幂等）→ 启动。施工无需管理员权限（克隆放用户目录、adhoc 重签）。
    private func installAndLaunchClone(_ n: Int) {
        guard let dir = Bundle.main.resourcePath.map({ $0 + "/engine" }),
              FileManager.default.fileExists(atPath: dir + "/install-clone.sh") else {
            errorMessage = String(localized: "未找到内置克隆脚本"); return
        }
        let src = appPath
        let dest = cloneDir
        installing = true
        Task.detached {
            try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
            let r = shellRun("/bin/bash", ["\(dir)/install-clone.sh", "\(n)", src, dest])
            await MainActor.run {
                self.installing = false
                if r.status != 0 {
                    self.errorMessage = String(localized: "创建克隆失败：\(r.output)")
                } else {
                    self.launchClone(n)
                }
                self.scanClones()
            }
        }
    }

    /// 是否已有「完全磁盘访问」——清理克隆数据容器(受 TCC 保护)需要。
    /// 探针：尝试列出 ~/Library/Application Support/com.apple.TCC/（无 FDA 会 Operation not permitted）。
    func hasFullDiskAccess() -> Bool {
        let tcc = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC"
        return (try? FileManager.default.contentsOfDirectory(atPath: tcc)) != nil
    }

    /// 清理全部克隆（.app + 数据容器 + group 容器）。数据容器删除需 FDA：
    /// 无 FDA → 不静默失败，置 needFDAForCleanup 引导用户去授权。
    func cleanupClones() {
        let nums = existingCloneNumbers()
        guard !nums.isEmpty else { return }
        guard hasFullDiskAccess() else {
            needFDAForCleanup = true   // UI 弹「去设置」引导，不静默失败
            return
        }
        needFDAForCleanup = false
        guard let dir = Bundle.main.resourcePath.map({ $0 + "/engine" }),
              FileManager.default.fileExists(atPath: dir + "/cleanup-clone.sh") else {
            errorMessage = String(localized: "未找到内置克隆清理脚本"); return
        }
        let destDir = cloneDir
        installing = true
        Task.detached {
            var failedCount = 0
            for n in nums {
                let r = shellRun("/bin/bash", ["\(dir)/cleanup-clone.sh", "\(n)", destDir])
                if r.status != 0 { failedCount += 1 }
            }
            let anyFailed = failedCount > 0
            await MainActor.run {
                self.installing = false
                // 多为数据容器受 FDA 保护未删净 → 引导授权
                if anyFailed { self.needFDAForCleanup = true }
                self.scanClones(); self.countInstances()
            }
        }
    }

    private func readEngineVersion() {
        guard engineVersion == nil else { return }
        let r = shellRun("/bin/ls", ["/opt/homebrew/Cellar/wechattweak"])
        if r.status == 0 {
            engineVersion = r.output.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// 自研引擎在场时：注入探针把微信自己的授权态（屏幕录制 / 全盘访问）写到容器内 perms.json，
    /// GUI 直接读它判断 fdaOK / screenOK（不再用"工具自身加 FDA 读 TCC.db"那套——已否决）。
    /// 读不到（没装自研引擎 / 探针还没写）→ permsReadable=false，UI 走 fallback（只显"去设置"）。
    private var permsJSONPath: String {
        let home = NSHomeDirectory()
        return home + "/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/WeChatMulti/perms.json"
    }
    private func checkPermissions() {
        guard ourEngineInstalled,
              let data = FileManager.default.contents(atPath: permsJSONPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { permsReadable = false; fdaOK = false; screenOK = false; return }
        permsReadable = true
        fdaOK = (obj["fda"] as? Bool) ?? false
        screenOK = (obj["screen"] as? Bool) ?? false
    }

    private func readVersion() {
        if let dict = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") {
            version = dict["CFBundleShortVersionString"] as? String
            build = dict["CFBundleVersion"] as? String
        }
    }

    // MARK: - 版本 → 近似发布日期
    //
    // 微信 CFBundleShortVersionString 只有 3 段（如 "4.1.11"），对应多个内部 build，
    // 对不准具体哪天，但月级近似可接受（让用户对"版本多旧"有直观感）。
    // 数据来源/更新方式见 app/VERSION_DATES.md。优先级：一定有数据 > 月级近似 > 精确到天。

    /// 内置「marketing version → 近似发布月（YYYY-MM）」。离线一定可用，保证当前版本(4.1.11)有数据。
    /// 取自微信官方更新日志 weixin.qq.com/updates?platform=mac（详见 VERSION_DATES.md）。
    private static let builtinReleaseDates: [String: String] = [
        "4.1.11": "2026-06",
        "4.1.10": "2026-05",
        "4.1.9":  "2026-04",
        "4.1.8":  "2026-03",
        "4.1.7":  "2026-01",
        "4.1.6":  "2025-12",
        "4.1.5":  "2025-11",
        "4.1.4":  "2025-11",
        "4.1.2":  "2025-10",
        "4.1.1":  "2025-09",
        "4.1.0":  "2025-08",
        "4.0.6":  "2025-07",
        "4.0.5":  "2025-05",
        "4.0.3":  "2025-03",
        "3.8.9":  "2024-09",
        "3.8.8":  "2024-05",
        "3.8.7":  "2024-03",
        "3.8.6":  "2023-12",
        "3.8.5":  "2023-11",
        "3.8.4":  "2023-10",
        "3.8.2":  "2023-08",
        "3.8.1":  "2023-07",
        "3.8.0":  "2023-05",
    ]

    /// 启动时异步拉到的在线 map（可覆盖/扩展内置）；拉不到就为空，绝不阻塞 UI、绝不报错。
    @Published private var onlineReleaseDates: [String: String] = [:]

    /// 当前微信版本的近似发布月（YYYY-MM），匹配不到返回 nil → UI 只显版本号（不报错）。
    var releaseDate: String? {
        guard let v = version else { return nil }
        if let d = onlineReleaseDates[v] { return d }            // 在线优先
        if let d = Self.builtinReleaseDates[v] { return d }      // 内置兜底
        return nil
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

    /// 检测自研引擎是否已装入当前微信副本：
    ///   1) Contents/Frameworks/WeChatMultiEngine.dylib 存在；
    ///   2) 业务体 wechat.dylib 的 mach-o 含指向 WeChatMultiEngine.dylib 的 LC_LOAD_DYLIB。
    /// 两者皆满足才判定已装（避免只拷了 dylib、没注入也算）。
    private func detectSelfEngine() {
        let dylib = appPath + "/Contents/Frameworks/WeChatMultiEngine.dylib"
        let body  = appPath + "/Contents/Resources/wechat.dylib"
        guard FileManager.default.fileExists(atPath: dylib),
              FileManager.default.fileExists(atPath: body) else {
            ourEngineInstalled = false; return
        }
        // 读业务体的 LC_LOAD_DYLIB（otool -l），确认注入了 WeChatMultiEngine.dylib。
        let r = shellRun("/usr/bin/otool", ["-l", body])
        ourEngineInstalled = r.status == 0 && r.output.contains("WeChatMultiEngine.dylib")
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
            errorMessage = String(localized: "未找到内置 X1a0He 安装包"); return
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

    /// 用内置 Resources/engine/install-self-engine.sh 对当前微信副本就地施工（门①静态 patch +
    /// 引擎注入 + adhoc 重签），装后去隔离属性防 AppTranslocation。经管理员权限（弹原生密码框）。
    /// 脚本拒绝施工 /Applications/WeChat.app —— 仅对副本生效；本工具不在场自动调用它。
    func installSelfEngine() {
        guard appInstalled else { errorMessage = String(localized: "未检测到微信"); return }
        guard let dir = Bundle.main.resourcePath.map({ $0 + "/engine" }),
              FileManager.default.fileExists(atPath: dir + "/install-self-engine.sh") else {
            errorMessage = String(localized: "未找到内置自研引擎"); return
        }
        let app = appPath
        installing = true
        Task.detached {
            _ = shellRun("/usr/bin/osascript", ["-e", "tell application \"WeChat\" to quit"])
            _ = shellRun("/usr/bin/pkill", ["-f", "WeChat.app/Contents/MacOS"])
            // 安装脚本 + 去隔离，一次管理员密码内完成。路径用单引号包好。
            let inner = "/bin/bash '\(dir)/install-self-engine.sh' '\(app)' && /usr/bin/xattr -dr com.apple.quarantine '\(app)'"
            let script = "do shell script \"\(inner.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            let r = shellRun("/usr/bin/osascript", ["-e", script])
            let cancelled = r.output.contains("-128") || r.output.contains("用户已取消")
            await MainActor.run {
                self.installing = false
                if r.status != 0 && !cancelled { self.errorMessage = r.output }
                self.refresh()
            }
        }
    }

    /// 次级动作：已装 X1a0He 时，用户主动"改用自研引擎（实验）"。与默认安装入口区分，
    /// 避免一键安装误把用户在用的 X1a0He 替换掉。施工本身同 installSelfEngine()。
    func switchToSelfEngine() { installSelfEngine() }

    func openFullDiskAccessSettings() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
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
