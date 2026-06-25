# 企业微信 (WeCom) Mac 多开可行性调研 — 复用本项目技术做 "WeComMulti"

> **纯研究/只读。** 全程未修改、未启停 `/Applications/企业微信.app`，仅 `defaults read` / `codesign -d` / `otool` / `strings` 只读分析本机已装版本 + 在线调研。不碰本项目 `app/`、`engine/` 代码。

## 0. 一句话结论

> **bundleID 克隆方案（方案②）几乎一定可行，且是做 WeComMulti 最快的路线**——WeCom 与微信同为腾讯出品、同为 App-Sandbox + Developer ID + app-group 容器架构，"改 `CFBundleIdentifier` + team 前缀 entitlement + adhoc 逐文件重签" 这套配方可直接移植。**唯一需要现场坐实的差异点**：WeCom 的 crash 处理器**不是** WeChat 4.x 那个会去 `bootstrap_check_in` 注册 `<team>.<bundleid>.crashpad.*` 的 Chromium Crashpad，而是腾讯自研 **Matrix / WCCrashBlockMonitor**（主进程）+ CEF 自带 crashpad（仅渲染子进程）。所以 clone-verdict 里"裸克隆约 15s 被 Crashpad SIGTRAP 自杀"的**那个具体杀因大概率不复现**；但 team 前缀配方本身无害且应照搬（CEF 渲染子进程那条 crashpad 仍可能踩同一坑，保守起见保留 `88L2Q4487U` 前缀）。
>
> **字节 patch / 注入方案（方案①/③）需要重新逆向**：WeCom 是 **202MB 单体主二进制**（不是 WeChat 4.x 的"小 loader + 大 wechat.dylib"双层结构），门①（loader mach 单例 cbz）这个概念在 WeCom 里**不存在对应物**；单例门改在主二进制内部（找到了 ObjC 选择子 `wew_isMultiInstance` + `NSRunningApplication` 使用证据）。要复刻注入方案得对这个 202MB 二进制重新做一遍门定位，工作量大，**不推荐作为首选**。
>
> **强烈风控提示**：企业微信对"账号多开"有**官方明令禁止 + 实际处罚**，且处罚会**连坐到管理员账号和企业账号**（比个人微信严重得多）。技术上可做，落地用途需自行评估边界。

---

## 1. 本机 WeCom 架构（只读实测，v5.0.8 build 99856）

### 1.1 基本身份
| 项 | 值 |
|---|---|
| 路径 | `/Applications/企业微信.app`（已装） |
| `CFBundleIdentifier` | `com.tencent.WeWorkMac` |
| 版本 | `5.0.8`（build 99856） |
| `CFBundleExecutable` | `企业微信`（中文名可执行文件） |
| 主二进制 | `Contents/MacOS/企业微信`，**thin arm64**（非 universal），**202 MB 单体** |
| Team | **`88L2Q4487U`**（≠ 微信的 `5A4RE8SF68`，是腾讯另一开发者账号） |
| 签名 | `Developer ID Application: Tencent Technology (Shenzhen) Company Limited (88L2Q4487U)`，`flags=0x10000(runtime)`（hardened runtime），`Runtime Version 15.2.0` |
| 数据容器 | `~/Library/Containers/com.tencent.WeWorkMac/`（沙盒容器，已存在，含用户真实数据） |

### 1.2 不是 loader+业务体双层结构（与微信 4.x 的关键差异）
- WeChat 4.x：`MacOS/WeChat`（小 loader，几 MB，单例门①在此）+ `Resources/wechat.dylib`（~300MB 业务体，门②在此）。
- **WeCom：`MacOS/企业微信` 自己就是 202MB 主二进制，业务逻辑直接在主体里**，`Contents/Resources/` 下无 `*.dylib` 业务体。
- 业务能力拆在 `Contents/Frameworks/` 的大量 dylib/framework 里（主体 `otool -L` 直接链接）：`libWeMail.dylib`(37MB)、`libwwkdevices.dylib`(42MB)、`libWwkAVFactory.dylib`、`libwwvoip_engine.dylib`、`libWeVision.dylib` 等 + Flutter（`FlutterMacOS.framework`、`App.framework`、`mm_dart.framework`）+ Qt 全家桶 + CEF（`Chromium Embedded Framework.framework`）。技术栈 = **Native(ObjC/C++) + Flutter + Qt + CEF 混合**，比微信更杂。
- 含 4 个 CEF Helper（`企业微信 Helper(.GPU/.Plugin/.Renderer).app`）、`Mini Program.app`、`wwmapp.app`、`TCDApp.app`、`IPCHelper.app` 等子 app/XPC。

> **含义**：本项目"门①静态 patch loader 的 mach 单例 cbz"在 WeCom 上**没有对应目标**（没有独立 loader）。注入路线要把门①门②合并成"在 202MB 主体内找单例放行门"，等于从零逆一遍。

### 1.3 单例机制初判（strings/otool 只读，未动态调试）
- **找到 ObjC 选择子 `wew_isMultiInstance`** —— 强烈暗示 WeCom **内部本就有"是否多开实例"的判定/分支**（类似微信的 `[CUtility HasWechatInstance]`）。这是注入方案 swizzle 它返回"允许"的**潜在切入点**，但未确认调用点逻辑。
- **`NSRunningApplication` 使用证据**：主体含 `@"NSRunningApplication"`、`_runningApplication`、`activateWithOptions:`、`[dock] isActive`、`_wewIsActive`/`_systemIsActive`/`__WxDriveIpcGetWeworkIsActive` 等 —— 说明有"枚举同 bundleId 运行实例 / 判活"逻辑（与本项目门③ NSRunningApplication swizzle 同源思路）。
- 其他多实例相关串：`MultiInstanceCount`、`launch xpc already running`、`child app is already running, post noti`（后两者更像子进程/XPC 守护，不一定是顶层单例门）。
- **未发现** Windows 版那种命名互斥体 `Tencent.WeWork.ExclusiveObject`（那是 Win 专属内核对象，mac 无对应命名空间）—— 证实 mac 单例必然走 **app 身份 / 容器 / NSRunningApplication / mach 注册** 路线，而非"关句柄"。
- **mach bootstrap 单例服务名**：strings 里有大量 `com.tencent.wework.*` / `com.tencent.WeWork-Helper.*` 服务名，但**未确认**哪个是"顶层单例锁"用途（需动态 `bootstrap_check_in` 跟踪才能坐实；本次只读未做）。

### 1.4 签名 / 沙盒 / entitlements（codesign -d --entitlements 实测）
```
com.apple.security.app-sandbox                 = true        ← 沙盒，同微信
com.apple.security.cs.allow-jit                = true
com.apple.security.cs.allow-unsigned-executable-memory = true ← 利于注入(W^X 已放松)
com.apple.security.application-groups          = [
    88L2Q4487U.WeWorkMac
    88L2Q4487U.com.tencent.WeWorkMac           ← 主 group 容器
    88L2Q4487U.com.tencent.WeWorkMac.dev / .Debug / .UIDev
]
com.apple.security.network.client/server, device.camera/microphone/audio-input,
files.user-selected/downloads/bookmarks.*, personal-information.calendars/location,
assets.pictures.read-write, print
com.apple.security.temporary-exception.mach-lookup.global-name = [
    com.tencent.WeWorkMac-spks
    com.tencent.WeWorkMac-spki                 ← 同微信的 -spks/-spki 内部 XPC 名查
]
```
**与微信 entitlement 形态高度同构**：app-sandbox + team 前缀 application-groups + `cs.allow-*` + 同样的 `-spks/-spki` 临时例外。**clone-verdict 的配方表几乎逐项对应得上**，只是把 `5A4RE8SF68` 换成 `88L2Q4487U`、`xinWeChat` 换成 `WeWorkMac`。

### 1.5 Crash 处理器差异（决定裸克隆是否被秒杀）—— ★ 关键
- WeChat 4.x 裸克隆被秒杀的真凶（clone-verdict §1）= **Chromium Crashpad** 启动时 `bootstrap_check_in` 注册 `5A4RE8SF68.<bundleid>.crashpad.*`，adhoc 去掉 team 前缀 → 沙盒 deny(1100) → SIGTRAP exit(133)。
- **WeCom 主进程 crash 处理走的是腾讯自研 Matrix**：strings 实证主体含 `WCCrashBlockMonitor` / `WCCrashBlockFileHandler` / `/Users/wie/code/matrix_for_ww/Matrix/...` 路径，且独立 `catcher.framework`（`org.cocoapods.catcher`，KSCrash 系）。**这些是文件落盘式 crash 上报，不依赖注册 `<team>.<bundleid>.crashpad` mach 服务** → **WeChat 那个具体 SIGTRAP 杀因在 WeCom 主进程上大概率不复现**。
- **但** WeCom 仍带 `Chromium Embedded Framework.framework` + CEF Helper（`88L2Q4487U.com.tencent.wework.helper`，hardened runtime）—— CEF **渲染子进程**自带 Crashpad，仍可能注册 `88L2Q4487U.*.crashpad.*`。所以**保守做法 = 照搬 team 前缀配方**（保留 `88L2Q4487U` 前缀），既覆盖潜在 CEF crashpad 坑，又无副作用。

---

## 2. 市面现状（在线调研，附 URL）

### 2.1 是否已有现成 WeCom Mac 多开
- **有一个专用工具，但小众/疑似停更**：`wangliangliang2/WeWorkMacPlugin`（~59★），README 明确列 "防撤回 / 去水印 / **多开（工作需要，大家不要滥用）**"，针对 macOS 企业微信，Xcode 工程 `make`/⌘B 构建。注入手法 README 未写明。 https://github.com/wangliangliang2/WeWorkMacPlugin
- **通用克隆+重签法**（app 无关）：copy .app → 改 `CFBundleIdentifier` → adhoc 重签 → `xattr` 去隔离 → `open -n`。教程多写给个人微信，但二进制无关、可指向 WeCom。**社区无人发过"对当前 WeCom build 亲测"**。 https://jimmysong.io/zh/blog/multiple-wechat-instances-on-mac/
- **`open -n` 单招**：2019 老文写过 `open -n /Applications/企业微信.app/...`，但 `open -n` 只绕 Launch Services 合并、**不破 app 自身单例自检**，对当前 build 不保证有效。 https://blog.csdn.net/qinglianchen0851/article/details/102657083

### 2.2 关键 GitHub 生态结论
| 仓库 | 针对 WeCom? | 多开? | 备注 |
|---|---|---|---|
| **wangliangliang2/WeWorkMacPlugin** | 是(mac) | **是** | 唯一专用 mac WeCom 多开工具，~59★ |
| X140Yu/WEWTweak | 是(mac) | 否 | 仅去水印/外链浏览器，`insert_dylib` 注入，~88★ |
| ivothgle/WeChatWork-MacOS | 是(mac) | 否 | 防撤回/去水印，`insert_dylib`+`fishhook`，2020 已归档(可能失效) |
| sunnyyoung/WeChatTweak-macOS | **否**(个人微信) | 是 | 最火微信 tweak，不延伸到 WeCom |
| X1a0He/X1a0HeWeChatPlugin | **否**(个人微信) | 是 | ~1.1k★，**确认不支持企业微信** |
| 0x0E24/WxWork | 是但 **Windows** | 是 | C# DLL hook，非 mac |

> **重要**：知名注入器（WeChatTweak、X1a0He）**只支持个人微信，不覆盖 WeCom**。针对 mac WeCom 的 tweak 大多**省掉多开**，只有 WeWorkMacPlugin 含多开 → 印证"WeCom mac 多开的注入路线，社区现成可抄的不多"。

### 2.3 逆向 writeup 现状
- **mac RE writeup 只有个人微信**：sunnyyoung 把微信门定位为 ObjC `[CUtility HasWechatInstance]`（`if (r12 >= 0x2)` 限 2 开），swizzle 返回 0 + `open -n`。**无 WeCom mac 等价 writeup 公开**。 https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-wu-xian-duo-kai-gong-neng-shi-jian/
- 看雪有"[原创] 企业微信多开"帖但 CAPTCHA 锁，内容无法核实。 https://bbs.kanxue.com/thread-275092.htm
- WeCom RE writeup 几乎都是 **Windows**（互斥体逆向）。

### 2.4 Windows 多开技法（对比，反推 mac 机制）
- Win 单例 = **命名内核互斥体** `BaseNamedObjects\Tencent.WeWork.ExclusiveObject`（注意内部品牌是 "WeWork"），多开 = 用 `handle.exe`/Process Explorer **关掉运行中 `WXWork.exe` 的该句柄** 再重启；三开关 `...ExclusiveObjectInstance1/N`。或注册表 `HKCU\Software\Tencent\WXWork` 设 `multi_instances=2+`。 https://blog.csdn.net/zhumengkang123/article/details/141932059
- **反推 mac**：Win 那套是**纯本地、无状态的互斥体存在性检查**，不涉服务端/硬件校验 → 单例决策是纯本地的。但 mac **无命名互斥体命名空间**，"关句柄"无对应物 → mac 必然走**应用身份/容器/NSRunningApplication/mach 注册**判定 → 这正是"**给每个副本不同身份**(克隆+改 bundleId+独立容器+重签)" 比"杀句柄"更对路的根因。

### 2.5 原生多账号 & 风控
- **原生不支持同端同时两个账号**：一个账号可加入多企业并在 app 内切换，但**一个设备不能同时在线两企业**（逐个切）；换底层账号要登出登入。同账号最多 2 端（手机+PC 类组合），同类型第二端会踢掉前一个。 https://open.work.weixin.qq.com/help2/pc/cat?doc_id=13108
- **★ 风控（比个人微信严重）**：企业微信 2024-06-12 官方明令把 **账号多开** 列为违规（与群发滥用、RPA/云手机自动化并列）。处罚**分级且连坐**：首次→功能限制(常见 24–72h)；重复/严重→**永久封禁可同时打到成员账号 + 管理员账号 + 企业账号**。即多开是**全组织风险**，远高于个人微信"后果只在个人"。SCRM 厂商口径称同设备同 WiFi 多开封号率高(方向性、非官方)。 https://www.weibanzhushou.com/blog/25896 · https://www.wescrm.com/helpcenter/730.html

---

## 3. 三套方案对 WeCom 的可行性结论

| 本项目方案 | 微信上的做法 | 移植 WeCom 可行性 | 工作量 | 备注 |
|---|---|---|---|---|
| **② bundleID 克隆**（零注入、版本无关） | 改 `CFBundleIdentifier` + team 前缀 app-id/group + app-sandbox + adhoc 逐文件重签(无 `--deep`) | **几乎一定可行**（架构同构：app-sandbox + Developer ID + app-group 容器 + `-spks/-spki`） | **小** | 配方逐项对得上，只换 `5A4RE8SF68→88L2Q4487U`、`xinWeChat→WeWorkMac`。**裸克隆可能不会被秒杀**（主进程非 Crashpad，是 Matrix），但仍照搬 team 前缀配方覆盖 CEF crashpad 潜在坑。**需现场坐实**：克隆后存活时长 + CEF 子进程是否报 crashpad mach deny。 |
| **① 字节 patch（loader mach 单例）** | 静态 patch 小 loader 的 mach 单例 cbz | **无直接对应物**（WeCom 无独立 loader，是 202MB 单体主二进制） | 不适用 | 概念失效，门不在独立 loader 里。 |
| **① 字节 patch / ③ 注入（业务体单例门）** | 注入 dylib，运行时 NOP `tbz w20`(门②) + swizzle NSRunningApplication(门③) | **理论可行但需重新逆向**：已发现 `wew_isMultiInstance` 选择子 + `NSRunningApplication` 使用证据(切入点)，但门具体位置/字节特征要在 202MB 主体里从零定位 | **大** | 主体非 universal(thin arm64)、Flutter+Qt+CEF 混合，符号/控制流更杂。`cs.allow-unsigned-executable-memory=true` 对注入有利。可参考 WeWorkMacPlugin/WEWTweak 的 `insert_dylib` 注入壳。 |
| **数据隔离** | 同容器多开(MMKV InterProcess) 或克隆独立容器 | 克隆方案**天然独立容器**(`~/Library/Containers/88L2Q4487U.com.tencent.WeWorkMac.cloneN` 形态)，数据/登录态隔离 = **正合企业 IM"不同账号要彻底隔离"刚需** | — | WeCom 同账号本就 2 端限制 + 风控，克隆独立容器跑不同账号最干净。 |
| **风控差异** | 个人微信后果在个人 | **企业微信连坐管理员+企业账号**，处罚分级、官方明令 | — | 技术外的最大约束，落地前须评估。 |

---

## 4. 推荐路线（最快做出 WeComMulti）

**首选：方案② bundleID 克隆**（直接复用 `engine/install-clone.sh` 思路，改三处常量）。
1. 把脚本里的 team 前缀 `5A4RE8SF68` → **`88L2Q4487U`**，bundle 前缀 `com.tencent.xinClone` → **`com.tencent.WeWorkMac.cloneN`**（或新后缀），group 同步换前缀。
2. entitlements 照 §1.4 实测那份生成（app-sandbox + `88L2Q4487U.com.tencent.WeWorkMac.cloneN` 的 app-id/group + `cs.allow-jit`/`allow-unsigned-executable-memory` + 能力位 + `-spks/-spki` 临时例外）。
3. **去掉 WeChat 专属处理**：WeCom 无 `wechat.dylib.original`/`X1a0HeWeChatPlugin.dylib` 还原步骤；但要处理**嵌套子 app**（CEF Helper×4 / Mini Program.app / wwmapp.app / TCDApp.app / IPCHelper.app）—— adhoc 逐文件重签时按路径**深→浅**，每个嵌套 .app 内的可执行各自签，顶层最后带 entitlements 签，**绝不 `--deep`**（同 clone-verdict §2）。
4. `xattr -dr com.apple.quarantine`，`codesign --verify` 校验，`open -n` 启动，采样存活时长（重点看是否复现 Crashpad/CEF 的 mach deny，应不复现或被 team 前缀放行）。

**坐实清单（落地前必做的 3 个只读/沙箱实验，本次未做，因约定不施工 WeCom）**：
- (a) 克隆一份到非 `/Applications` 临时目录，按上述重签，`open -n` 测存活 >90s（验证无秒杀）。
- (b) 跑起后 scan log 看 CEF 渲染子进程有无 `88L2Q4487U.*.crashpad.* … denied(1100)`（决定 team 前缀是否真的必需 / 是否还要给 Helper 子 app 也带前缀 entitlement）。
- (c) 确认克隆独立容器 `~/Library/Containers/88L2Q4487U.com.tencent.WeWorkMac.cloneN` 建立、与原版数据隔离、可独立扫码登录。

**不推荐作为首选：注入/字节 patch（方案①/③）。** WeCom 是单体 202MB 二进制、无 loader 层、Flutter+Qt+CEF 混合，门定位成本远高于微信，且收益（共享原容器多开）对企业 IM 意义不大（企业场景更要"不同账号彻底隔离"，正是克隆方案的强项）。若未来确需"共享同一账号容器开多窗口"，再以 `wew_isMultiInstance` 选择子为入口逆向（参考 WeWorkMacPlugin）。

---

## 5. 待核实 / 未做（如实声明）
- 本次**只读静态分析**（strings/otool/codesign/defaults），**未动态调试、未实际克隆 WeCom**（遵守"不施工 WeCom"约定）。§4 的克隆存活、CEF crashpad 是否报 deny、容器隔离三项**需后续在临时副本上实测坐实**（绝不写 `/Applications/企业微信.app`）。
- `wew_isMultiInstance` 的**调用点逻辑/是否就是顶层单例门**未确认（需 lldb 或 IDA）。
- WeCom mac **顶层单例 mach 服务名**未坐实（strings 有大量 `com.tencent.wework.*` 服务名，未定位哪个是单例锁）。
- WeWorkMacPlugin 的**具体注入原语**README 未写明（推测 `insert_dylib`，未确认）。
- 看雪 275092 帖内容（CAPTCHA 锁）、"5 设备"等说法未能核实。

> **未 git commit**（按要求由主会话统一提交）。
