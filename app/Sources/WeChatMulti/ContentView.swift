import SwiftUI

struct ContentView: View {
    @ObservedObject var model: WeChatModel
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // 主按钮：未找到微信→灰(选路径)；终极兜底模式(注入全不适用)→紫(新开独立副本)；否则→绿(新开微信)
            Button(action: {
                if !model.appInstalled { model.chooseWeChatPath() }
                else if model.cloneMode { model.openCloneInstance() }
                else { model.openNewInstance() }
            }) {
                Text(mainButtonText)
            }
            .buttonStyle(SolidButton(color: mainButtonColor,
                                     fullWidth: true, minHeight: 46, titleFont: .title3))
            .disabled(mainButtonDisabled)

            // 状态 + 权限（合并为一栏，红/绿）
            VStack(spacing: 6) {
                // 没装任何引擎时只留"双开插件状态(不可用)",其余全隐藏(整洁)；装了才显示完整状态。
                if showFullPanel {
                    openedRow
                    plain(String(localized: "双开方案数量"), schemeValue)
                }
                statusRow
                if showFullPanel {
                    plain(model.engineRowLabel, model.engineRowValue)
                    plain(String(localized: "当前微信版本"), versionValue)
                }
                // FDA 提示只在注入引擎已装时显示(装前微信不会弹"访问其他App"弹窗,不必提示)。
                if showFDASection {
                    fdaRow()
                }
            }

            if model.signType == .appStore {
                Text("⚠️ App Store 沙盒版不被支持，请改用官网版")
                    .font(.caption).padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if showFDASection {
                Text("⚠️ 不开微信会反复弹「想访问其他 App 的数据」；若开了仍弹，把微信用「−」删掉再「+」重新添加（macOS 老 bug）。")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    // 默认不勾 → 装 X1a0He(生产安全);勾上 → 装自研引擎(实验,可能有兼容问题如视频)。
                    Toggle(String(localized: "自研引擎（实验）"), isOn: $model.useSelfEngine)
                        .toggleStyle(.checkbox).controlSize(.small).font(.callout)
                    Toggle("在顶部菜单栏显示图标", isOn: $showMenuBarIcon)
                        .toggleStyle(.checkbox).controlSize(.small).font(.callout)
                }
                Spacer(minLength: 10)
                if showActionButton {
                    Button(buttonLabel) {
                        if model.needsDownload { model.showDownloadConfirm = true }
                        else if model.multiOpenActive && !model.engineOutdated { model.uninstallEngine() }
                        else { model.installBestEngine() }
                    }
                    .buttonStyle(SolidButton(color: installButtonColor, minHeight: 30))
                    .disabled(model.installing)
                }
            }
        }
        .padding(12)
        .alert("下载并替换微信", isPresented: Binding(
            get: { model.showDownloadConfirm },
            set: { model.showDownloadConfirm = $0 }
        )) {
            Button("取消", role: .cancel) {}
            Button("下载并替换") { model.downloadAndReplaceWeChat() }
        } message: {
            Text(model.compatReason)
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("需要完全磁盘访问", isPresented: Binding(
            get: { model.needFDAForCleanup },
            set: { if !$0 { model.needFDAForCleanup = false } }
        )) {
            Button("去设置") {
                model.openFullDiskAccessSettings()
                model.needFDAForCleanup = false
            }
            Button("取消", role: .cancel) { model.needFDAForCleanup = false }
        } message: {
            Text("删除克隆的数据容器受 macOS 保护，需要先在「系统设置 > 隐私与安全性 > 完全磁盘访问」中勾选本工具，然后再清理。")
        }
        .alert("检测更新", isPresented: Binding(
            get: { model.updateMessage != nil },
            set: { if !$0 { model.updateMessage = nil } }
        )) {
            if model.updateAvailable {
                Button("立即更新") { model.installUpdate() }
            }
            Button("前往主页") { model.openRepoPage(); model.updateMessage = nil }
            Button("好", role: .cancel) { model.updateMessage = nil }
        } message: {
            Text(model.updateMessage ?? "")
        }
    }

    // 主按钮文案/颜色：未找到→灰(选路径)；终极兜底→紫(独立副本)；否则→绿(新开微信)。
    private var mainButtonText: String {
        if !model.appInstalled { return String(localized: "未找到微信 · 点此选择位置") }
        if model.cloneMode { return String(localized: "新开一个独立副本") }
        return String(localized: "新开一个微信")
    }
    private var mainButtonColor: Color {
        if !model.appInstalled { return .gray }
        if model.cloneMode { return .indigo }
        if model.multiOpenActive { return .green }
        return .gray   // 装了微信但没装引擎/不可用 → 灰
    }
    // 装了微信却没可用引擎(不可用)→ 禁用(点不动);未找到微信时仍可点(去选路径)。
    private var mainButtonDisabled: Bool {
        model.installing || (model.appInstalled && !model.multiOpenActive && !model.cloneMode)
    }
    // 装了引擎(或克隆兜底)才显示完整状态行;没装任何引擎时只留"双开插件状态(不可用)",其余隐藏(整洁)。
    private var showFullPanel: Bool {
        model.multiOpenActive || model.cloneMode
    }
    // FDA 区(权限行+橙提示)只在注入引擎已装时显示(装前微信不弹"访问其他App",不必提示);
    // 检测到 FDA 正常则隐藏(整洁)。克隆模式无探针不显。
    private var showFDASection: Bool {
        model.multiOpenActive && !model.cloneMode && !(model.permsFresh && model.fdaOK)
    }

    // 安装按钮色：下载=蓝；引擎过时=橙(醒目引导更新)；已生效=红(卸载)；未装=蓝。
    private var installButtonColor: Color {
        if model.needsDownload { return .blue }
        if model.engineOutdated { return .orange }
        return model.multiOpenActive ? .red : .blue
    }

    // "双开方案数量"右值：共 N 个 · 当前方案 X(只显数量和编号,名字在状态行)。
    private var schemeValue: String {
        let n = model.currentSchemeNumber
        if n == 0 { return String(localized: "共 \(model.totalSchemes) 个 · 暂未启用") }
        return String(localized: "共 \(model.totalSchemes) 个 · 当前方案 \(n) · \(model.currentSchemeTech)")
    }

    // "已打开的微信"右值：N（已克隆 X 个）。N=在跑实例总数；X=已存在克隆总数。X>0 才显括号。
    private var openCountValue: String {
        let n = model.instanceCount
        if model.existingCloneCount > 0 {
            return String(localized: "\(n) 个（已克隆 \(model.existingCloneCount) 个）")
        }
        return String(localized: "\(n) 个")
    }

    // "已打开的微信"行：值=N（已克隆 X 个）；仅终极兜底模式右侧出"清理全部克隆"按钮。
    private var openedRow: some View {
        HStack(spacing: 6) {
            Text(String(localized: "已打开的微信")).font(.callout).foregroundStyle(.secondary)
                .frame(width: labelW, alignment: .leading)
            dotSlot(nil)
            Text(openCountValue).font(.callout)
            Spacer()
            if model.cloneMode {
                Button(String(localized: "清理全部克隆")) { model.cleanupClones() }
                    .controlSize(.small)
                    .disabled(model.installing || model.existingCloneCount == 0)
            }
        }
    }

    // "双开插件状态"行：终极兜底=红；引擎过时=橙"引擎需更新"；自研引擎不带"方案"；其它带。
    @ViewBuilder private var statusRow: some View {
        if model.cloneMode {
            dot(String(localized: "双开插件状态"),
                String(localized: "未生效（BundleID 临时方案）"), ok: false)
        } else if !model.multiOpenActive {
            dot(String(localized: "双开插件状态"), String(localized: "不可用"), ok: false)
        } else if model.engineOutdated {
            HStack(spacing: 6) {
                Text(String(localized: "双开插件状态")).font(.callout).foregroundStyle(.secondary)
                    .frame(width: labelW, alignment: .leading)
                dotSlot(.orange)
                Text(String(localized: "引擎需更新（请点下方更新）")).font(.callout).foregroundStyle(.orange)
                Spacer()
            }
        } else if model.activeEngine == .ourOwn {
            dot(String(localized: "双开插件状态"), String(localized: "已可用（自研引擎）"), ok: true)
        } else {
            dot(String(localized: "双开插件状态"),
                String(localized: "已可用（\(model.engineName) 方案）"), ok: true)
        }
    }

    // 当前微信版本行的值："4.1.11 (269077)"；若能匹配到近似发布月再追加 "· 发布于 2026-06"。
    // 匹配不到 → 只显版本号（不报错），保持现状。
    private var versionValue: String {
        guard let v = model.version else { return "—" }
        let base = "\(v) (\(model.build ?? "?"))"
        if let date = model.releaseDate {
            return base + " · " + String(localized: "发布于 \(date)")
        }
        return base
    }

    // 底部动作按钮：仅在"有事可做"时显示——版本搞不定→下载换版本；引擎过时→更新；未装→安装。
    // 一切正常工作时不显示(去掉无意义的"重新安装")。
    // 底部按钮：装了微信就显示(总有动作);纯BundleID克隆兜底模式下无装/卸动作(清理在行内)→隐藏。
    private var showActionButton: Bool {
        guard model.appInstalled else { return false }
        return model.needsDownload || model.activeEngine != .bundleIDClone
    }
    // 文案随状态:处理中/下载换版本/更新引擎/卸载引擎(装好且正常)/安装引擎(未装)。
    private var buttonLabel: String {
        if model.installing { return String(localized: "处理中…") }
        if model.needsDownload { return String(localized: "下载并替换为兼容版微信") }
        if model.engineOutdated { return String(localized: "更新双开引擎") }
        if model.multiOpenActive { return String(localized: "卸载双开引擎") }   // 装好且正常 → 卸载
        return String(localized: "安装双开引擎")   // 未装
    }

    // 英文标签更长 → 加宽标签列(利用右边空白)；中文保持 84 不变
    static var isEnglishUI: Bool { Bundle.main.preferredLocalizations.first == "en" }
    private var labelW: CGFloat { Self.isEnglishUI ? 120 : 84 }

    // 圆点槽（固定宽，让所有值从同一列左对齐）
    @ViewBuilder private func dotSlot(_ color: Color?) -> some View {
        if let c = color { Circle().fill(c).frame(width: 7, height: 7) }
        else { Color.clear.frame(width: 7, height: 7) }
    }

    // 普通信息行：标题固定列 + 值左对齐
    private func plain(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: labelW, alignment: .leading)
            dotSlot(nil)
            Text(value).font(.callout)
            Spacer()
        }
    }

    // 带红/绿圆点的状态行：值与普通行同列左对齐（点在值左侧的槽里）
    private func dot(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: labelW, alignment: .leading)
            dotSlot(ok ? .green : .red)
            Text(value).font(.callout).foregroundStyle(ok ? Color.green : Color.red)
            Spacer()
        }
    }

    // 全盘访问行：探针检测到未授权 → 标红「权限未设置」(与双开状态绿色相反) + 去设置；
    // 检测不到(没装探针/没跑过)→ 灰底引导。已授权时整行由外层条件隐藏，不在此渲染。
    private func fdaRow() -> some View {
        HStack(spacing: 6) {
            Text("全盘访问权限").font(.callout).foregroundStyle(.secondary)
                .frame(width: labelW, alignment: .leading)
            if model.permsFresh && !model.fdaOK {
                dotSlot(.red)
                Text("权限未设置").font(.callout).foregroundStyle(Color.red)
            } else {
                dotSlot(nil)
            }
            Spacer()
            Button("去设置") { model.openFullDiskAccessSettings() }.controlSize(.small)
        }
    }
}

// 实心按钮：始终显示颜色（不随窗口失焦变灰）
struct SolidButton: ButtonStyle {
    let color: Color
    var fullWidth: Bool = false
    var minHeight: CGFloat = 28
    var titleFont: Font = .callout
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(titleFont).bold()
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight)
            .background(color.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: fullWidth ? 14 : 8))
            .contentShape(Rectangle())
    }
}
