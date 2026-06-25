import SwiftUI

struct ContentView: View {
    @ObservedObject var model: WeChatModel
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // 主功能：大号"开新微信"按钮
            Button(action: {
                if model.appInstalled { model.openNewInstance() }
                else { model.chooseWeChatPath() }
            }) {
                Text(model.appInstalled
                     ? String(localized: "新开一个微信")
                     : String(localized: "未找到微信 · 点此选择位置"))
            }
            .buttonStyle(SolidButton(color: model.appInstalled ? .green : .gray,
                                     fullWidth: true, minHeight: 46, titleFont: .title3))

            // 状态 + 权限（合并为一栏，红/绿）
            VStack(spacing: 6) {
                plain(String(localized: "已打开的微信"),
                      String(localized: "\(model.instanceCount) 个"))
                dot(String(localized: "双开插件状态"),
                    model.multiOpenActive
                      ? String(localized: "已可用（\(model.engineName) 方案）")
                      : String(localized: "不可用"),
                    ok: model.multiOpenActive)
                plain(model.engineRowLabel, model.engineRowValue)
                plain(String(localized: "当前微信版本"), versionValue)
                // 检测到全盘权限正常 → 整行隐藏(进一步精简)；检测不到/未授权 → 显示(fallback)
                if !(model.permsReadable && model.fdaOK) {
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

            if !(model.permsReadable && model.fdaOK) {
                Text("⚠️ 不开微信会反复弹「想访问其他 App 的数据」；若开了仍弹，把微信用「−」删掉再「+」重新添加（macOS 老 bug）。")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Toggle("在顶部菜单栏显示图标", isOn: $showMenuBarIcon)
                    .toggleStyle(.checkbox).controlSize(.small).font(.callout)
                Spacer(minLength: 10)
                Button(buttonLabel) {
                    if model.needsDownload { model.showDownloadConfirm = true }
                    else { model.installBestEngine() }
                }
                .buttonStyle(SolidButton(
                    color: model.needsDownload ? .blue : (model.multiOpenActive ? .red : .blue),
                    minHeight: 30))
                .disabled(model.installing)
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

    private var buttonLabel: String {
        if model.installing { return String(localized: "处理中…") }
        if model.needsDownload { return String(localized: "下载并替换为兼容版微信") }
        return model.multiOpenActive
            ? String(localized: "重新安装双开插件")
            : String(localized: "安装双开插件")
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

    // 全盘访问：已授权显绿(与值同列)；否则「去设置」按钮贴右
    private func fdaRow() -> some View {
        HStack(spacing: 6) {
            Text("全盘访问权限").font(.callout).foregroundStyle(.secondary)
                .frame(width: labelW, alignment: .leading)
            if model.permsReadable && model.fdaOK {
                dotSlot(.green)
                Text("已授权").font(.callout).foregroundStyle(Color.green)
                Spacer()
            } else {
                dotSlot(nil)
                Spacer()
                Button("去设置") { model.openFullDiskAccessSettings() }.controlSize(.small)
            }
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
