# WeChatMulti · 微信多开工具

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![arch](https://img.shields.io/badge/arch-Apple%20Silicon-lightgrey)
![lang](https://img.shields.io/badge/Swift-6%2B-orange)
![ui](https://img.shields.io/badge/UI-SwiftUI-green)
![version](https://img.shields.io/badge/version-0.9.0-informational)
![license](https://img.shields.io/badge/own%20code-MIT-success)

A native macOS (SwiftUI) tool for running **multiple instances of WeChat 4.x** — with **three independent multi-instance strategies** and a **byte-level reverse-engineering dossier** of how WeChat's single-instance gates actually work.

一个原生 macOS（SwiftUI）的**微信 4.x 多开**工具 —— 提供**三套互相独立的多开方案**，并附带一份关于微信单实例门机制的**字节级逆向档案**。

> **This project does NOT bundle, crack, or modify the WeChat binary for distribution.** It contains no WeChat code, no paywall bypass, and ships no Tencent binaries. It is a launcher/manager that operates on a copy of WeChat that *you* already have installed. See the [Disclaimer](#disclaimer--免责声明).
>
> 本项目**不打包、不破解、不分发微信二进制**，不含任何微信代码，不含付费绕过。它是一个启动器/管理器，只在你本机**已安装**的微信上操作。详见[免责声明](#disclaimer--免责声明)。

---

## Table of Contents · 目录

- [Features · 特性](#features--特性)
- [The three strategies · 三套方案对比](#the-three-strategies--三套方案对比)
- [Screenshots · 截图](#screenshots--截图)
- [Install & Use · 安装与使用](#install--use--安装与使用)
- [Build from source · 从源码构建](#build-from-source--从源码构建)
- [How it works · 技术原理](#how-it-works--技术原理)
- [Credits · 致谢](#credits--致谢)
- [Disclaimer · 免责声明](#disclaimer--免责声明)
- [License · 许可证](#license--许可证)

---

## Features · 特性

**English**

- **Three multi-instance strategies** (see table below): a third-party injector, an original self-built injection engine, and a zero-injection bundle-clone fallback.
- **Native SwiftUI GUI** — a single "Open a new WeChat" action plus a menu-bar item (⌘N). No Terminal required.
- **Environment panel** — shows WeChat path / version / build / signature type (App Store vs. official-site vs. ad-hoc) and which engine is active.
- **Version age display** — shows the approximate release month of the installed WeChat ("4.1.11 · released 2026-06") so you can tell how old it is.
- **Version gatekeeper** — App Store builds (or builds newer than the bundled engine target) are flagged; a guided one-click flow can download and replace them with a compatible official-site build, **without losing chat history**.
- **Native permission self-check** (self-engine only) — the injected engine probes Screen-Recording / Full-Disk-Access *as WeChat itself* and writes `perms.json` for the GUI to read.
- **Bilingual (中 / EN)** UI that follows the system language, plus an About panel with open-source credits.

**中文**

- **三套多开方案**（见下表）：第三方注入引擎、自研注入引擎、零注入的 bundleID 克隆兜底。
- **原生 SwiftUI GUI** —— 一个「多开一个新微信」主按钮 + 菜单栏图标（⌘N），全程不碰终端。
- **环境检测面板** —— 显示微信路径 / 版本 / build / 签名类型（App Store / 官网 / adhoc），以及当前生效的引擎。
- **版本发布日期** —— 显示已装微信的近似发布月（如「4.1.11 · 发布于 2026-06」），让你直观感知版本多旧。
- **版本守门员** —— App Store 版（或高于内置引擎目标的 build）会被标记；可一键引导下载并替换为兼容的官网版，**聊天记录不丢失**。
- **原生权限自检**（仅自研引擎）—— 注入引擎以「微信自己」的身份探测屏幕录制 / 全盘访问权限，写出 `perms.json` 供 GUI 读取。
- **中英双语**界面，随系统语言自动切换；关于面板含开源致谢。

---

## The three strategies · 三套方案对比

WeChat 4.x guards against multiple instances with **two gates** (a loader-side mach bootstrap single-instance lock, and a body-side gate inside `wechat.dylib`). There are exactly three physical ways around them, each with different trade-offs:

微信 4.x 用**两道门**（loader 侧的 mach bootstrap 单例锁 + 业务体 `wechat.dylib` 内的判定门）防止多开。绕过它们物理上只有三条路，各有取舍：

| | ① X1a0He injection<br>X1a0He 注入 | ② Self-built engine<br>自研引擎注入 | ③ BundleID clone<br>BundleID 克隆兜底 |
|---|---|---|---|
| **Mechanism · 机制** | Third-party `.dylib`, Dobby inline hooks · 第三方 dylib，Dobby 内联 hook | Original tiny `.dylib`, runtime signature-located gate neutralization · 自研极小 dylib，运行时特征码定位中和 | No injection — clone `.app` + new `CFBundleIdentifier` · 零注入，克隆 .app + 改 BundleID |
| **Third-party dep · 第三方依赖** | Yes (X1a0HeWeChatPlugin) · 有 | **None** · **无** | **None** · **无** |
| **Hardcoded offsets · 硬编码偏移** | n/a | **None** (runtime signatures) · **无**（全运行时特征码） | n/a |
| **Version resilience · 版本韧性** | Maintained per-build by upstream · 靠上游逐 build 维护 | High (signature-located) · 高（特征码定位） | **Version-independent / never expires** · **版本无关 / 永不失效** |
| **Data / account · 数据账号** | Shares the WeChat container · 共享原版容器 | Shares the WeChat container · 共享原版容器 | **Independent container = separate login** · **独立容器 = 独立账号登录** |
| **Same-account multi-window · 同账号多窗口** | Yes · 支持 | Yes · 支持 | No (separate accounts) · 否（独立账号） |
| **Extra `.app` copies · 额外 .app** | No · 无 | No · 无 | Yes (one per clone) · 有（每克隆一个） |
| **Re-sign required · 是否重签** | Yes (ad-hoc) · 是 | Yes (ad-hoc) · 是 | Yes (ad-hoc) · 是 |
| **Role · 定位** | Mature, ready-to-use · 成熟现成 | Original, low-entropy, single-app · 原创、低熵、单 app | Ultimate fallback · 终极兜底 |

**Which to pick · 怎么选**

- Want it working **today** with the least fuss, and you already use X1a0He → **①**.
- Want a **single app, no third-party dependency, multiple windows of the same account** → **②** (this project's original engine).
- Want something that **never breaks across WeChat updates** and you're fine with **separate logins / one `.app` per account** → **③**.

- 想**今天就能用**、最省事、且已在用 X1a0He → **①**。
- 想要**单一 App、零第三方依赖、同账号多窗口** → **②**（本项目原创引擎）。
- 想要**永不随微信更新失效**、能接受**独立登录 / 每账号一个 .app** → **③**。

> Strategy ② and the reverse-engineering dossier behind it are **this project's own original work**. Strategy ① relies on the third-party [X1a0He/X1a0HeWeChatPlugin](https://github.com/X1a0He/X1a0HeWeChatPlugin) (credited below).
>
> 方案 ② 及其背后的逆向档案是**本项目的原创成果**。方案 ① 依赖第三方 [X1a0He/X1a0HeWeChatPlugin](https://github.com/X1a0He/X1a0HeWeChatPlugin)（已在下方致谢）。

---

## Screenshots · 截图

> _Screenshots TBD — placeholders below. 截图待补，下方为占位。_

| Main window · 主窗口 | Menu bar · 菜单栏 | About · 关于 |
|---|---|---|
| _`docs/screenshot-main.png`_ | _`docs/screenshot-menubar.png`_ | _`docs/screenshot-about.png`_ |

---

## Install & Use · 安装与使用

**Requirements · 环境要求**

- macOS 14+ (Sonoma or later) · macOS 14 及以上
- Apple Silicon (the self-built engine and the reverse-engineering work target arm64) · Apple Silicon（自研引擎与逆向均针对 arm64）
- WeChat installed from the **official site** (`weixin.qq.com`), not the Mac App Store — sandboxed App Store builds can be detected and the GUI will guide you to a compatible build · 从**官网**安装的微信（非 App Store 版）；App Store 沙盒版会被检测，GUI 会引导你换到兼容版

**Usage · 使用**

1. Build the app (see below) or grab a release, and launch `WeChatMulti.app`.
2. The main window detects your WeChat version, build, signature type and active engine.
3. Pick a strategy and let the GUI install/enable it (admin password is prompted natively, in-app).
4. Click **"Open a new WeChat" / 「多开一个新微信」** (or use the ⌘N menu-bar item) to spawn additional instances.

注：多开必须由本工具的「多开一个新微信」按钮（等价于 `open -n`）拉起；从 Dock/启动台点图标只会聚焦已有窗口、不开新进程，这与补丁/权限无关。

---

## Build from source · 从源码构建

No Xcode required — just the Swift toolchain.

无需 Xcode，只要 Swift 工具链：

```bash
cd app
./build.sh
```

This runs `swift build -c release`, assembles `WeChatMulti.app` by hand (Info.plist, icon, localized `.lproj` resources, and the engine assets from `engine/`), and ad-hoc signs the bundle. Output: `app/WeChatMulti.app`.

`build.sh` 会执行 `swift build -c release`、手动组装 `WeChatMulti.app`（Info.plist、图标、本地化 `.lproj`、来自 `engine/` 的引擎资产），并对 bundle 做 adhoc 签名。产物：`app/WeChatMulti.app`。

- **Toolchain · 工具链**: Swift 6+, macOS 14+ SDK.
- **App sources · App 源码**: `app/Sources/WeChatMulti/` (`WeChatMultiApp` / `WeChatModel` / `ContentView`).
- **Engine · 引擎**: `engine/` — `WeChatMultiEngine.m` (+ built `.dylib`), `insert_dylib.py`, `locate_gate1.py`, `install-self-engine.sh`, `install-clone.sh`, `cleanup-clone.sh`.

---

## How it works · 技术原理

The heart of this project is the **reverse-engineering dossier in [`re/`](./re/)** — a record of how WeChat 4.x's single-instance gates were located down to the byte, and why each strategy works. Highlights:

本项目的硬核在于 **[`re/`](./re/) 下的逆向档案** —— 记录了微信 4.x 单实例门如何被逐字节定位、以及每套方案为何成立。要点：

- **Two gates, not one** (`re/layer2-verdict.md`, `re/second-gate.md`) — Gate ① is a mach bootstrap single-instance lock in the loader (`Contents/MacOS/WeChat`); Gate ② lives inside the plaintext `wechat.dylib`. An earlier "third gate" hypothesis was disproven by isolation testing.
- **The real gate ② = `tbz w20, #0` @ `0x2117e0`** (`re/self-engine-v2.md`) — for WeChat 4.1.11, the second instance bails here (`w20.bit0 == 0` → `WeChatMain` returns `-1` → loader `exit(255)`). The self-built engine NOPs this `tbz`, located at runtime by signature (zero hardcoded offsets), and **only in the second-or-later instance** (instance role decided via a container `flock`).
- **X1a0He decoded to the byte** (`re/body-gate-memdiff.md`) — a memory diff revealed X1a0He uses **Dobby inline hooks** (not `mov w0,#0;ret` patches, not `NSRunningApplication` swizzling): 19 steady-state hooks (5 disable auto-update, 1 Qt dock menu, 13 Cronet/Mars network-stack file functions for path isolation) plus a 20th hook installed only in second instances.
- **Why the clone fallback never dies** (`re/clone-verdict.md`) — changing `CFBundleIdentifier` sidesteps every bundle-identity gate. The root cause of clones being killed (~15s) was traced to WeChat's built-in **Crashpad** registering a mach name `5A4RE8SF68.<bundleId>.crashpad.*` that the sandbox `deny(1100)`s; the fix is keeping the Tencent team prefix (`5A4RE8SF68.com.tencent.xinCloneN`) in the `application-identifier` / `application-groups` entitlements.
- **Self-built injection engine** (`re/self-engine.md`, `re/self-engine-v2.md`) — a tiny universal `.dylib` injected via a pure-Python `LC_LOAD_DYLIB` inserter; its constructor decides instance role (flock), neutralizes gate ② (signature-located NOP), keeps a gate ③ swizzle for the UI prompt, and runs the permission probe.

> Every claim above is backed by on-device testing logged in `re/`. The reports are honest about dead ends (e.g. the byte-patch-only approach was tested-to-failure and abandoned for 4.1.x).
>
> 以上每条结论都有 `re/` 里的实测记录支撑。报告对走过的死路也如实记载（如纯字节补丁方案被实测问死、对 4.1.x 放弃）。

---

## Credits · 致谢

This tool builds on the work of others and is careful to keep attribution clean. Full details in **[CREDITS.md](./CREDITS.md)**. In short:

本工具站在前人肩上，并力求署名清晰。完整内容见 **[CREDITS.md](./CREDITS.md)**。简言之：

- **[X1a0He/X1a0HeWeChatPlugin](https://github.com/X1a0He/X1a0HeWeChatPlugin)** — Strategy ①'s injection engine. · 方案 ① 的注入引擎。
- **[sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak)** (MIT) — early byte-patch approach for older builds. · 老版本字节补丁思路来源。
- **Tencent WeChat** — the official DMG is the only binary source; this project never redistributes it. · 官方 DMG 是唯一二进制来源，本项目从不分发。
- Version/date data, the Dobby project, and standard Apple reverse-engineering tools (`lldb` / `otool` / `nm` / `lipo` / `codesign`). · 版本日期数据、Dobby 项目、Apple 标准逆向工具。

**Strategy ② (the self-built engine) and the entire `re/` dossier are this project's own original reverse-engineering work.**

**方案 ②（自研引擎）与整套 `re/` 逆向档案是本项目的原创逆向成果。**

---

## Disclaimer · 免责声明

**English**

- This project is **for learning, research, and reverse-engineering exchange only**. It is a multi-instance launcher/manager for software you already own and run locally.
- It **does not bundle, redistribute, crack, or modify-for-distribution** the WeChat binary, and contains **no Tencent code**. It downloads WeChat (when needed) only from Tencent's official CDN, on your machine, for your own use.
- It contains **no paywall bypass and no payment circumvention** of any kind. Its scope is strictly "multiple windows of WeChat on one machine" — no automation, group-control, or batch-account operations.
- Running multiple instances and re-signing the app **may violate WeChat's Terms of Service** and could carry account or security risks. **You use this tool entirely at your own risk** and are responsible for complying with WeChat's Terms of Service and applicable laws.
- WeChat / 微信 is a trademark of Tencent. This project is not affiliated with, endorsed by, or sponsored by Tencent.
- Provided "as is", without warranty of any kind.

**中文**

- 本项目**仅供学习、研究与逆向技术交流**。它是对你**自己已安装**的软件做本机多窗口的启动器/管理器。
- 本项目**不打包、不分发、不破解、不为分发而修改**微信二进制，**不含任何腾讯代码**。需要时仅从腾讯**官方 CDN** 在你本机为你自己下载微信。
- 本项目**不含任何付费绕过 / 收费规避**。范围严格限于「同机多个微信窗口」—— 不做自动化、群控、批量账号操作。
- 多开与重签名**可能违反微信服务条款**，并可能带来账号或安全风险。**使用本工具的一切风险由使用者自负**，使用者须遵守微信服务条款及适用法律。
- 微信 / WeChat 是腾讯的商标。本项目与腾讯无任何隶属、背书或赞助关系。
- 本项目按「现状」提供，不附带任何明示或暗示的担保。

---

## License · 许可证

- **This project's own code** (the SwiftUI app in `app/`, the self-built engine in `engine/`, and the `re/` dossier) is released under the **MIT License** — see [`LICENSE`](./LICENSE) if present, or treat the badge above as authoritative until one is added.
- **Third-party components keep their own licenses** — e.g. WeChatTweak is MIT; X1a0HeWeChatPlugin and the Dobby project under their respective upstream licenses. See [CREDITS.md](./CREDITS.md).
- The WeChat binary and Tencent's assets are **not** covered by this license and are **not** distributed here.

- **本项目自有代码**（`app/` 的 SwiftUI App、`engine/` 的自研引擎、`re/` 逆向档案）以 **MIT 许可证**发布。
- **第三方组件各自保留其许可证**（WeChatTweak 为 MIT；X1a0HeWeChatPlugin、Dobby 等遵循各自上游许可）。详见 [CREDITS.md](./CREDITS.md)。
- 微信二进制及腾讯资产**不**在本许可证覆盖范围内，本项目**不**分发它们。

---

> Repo: [github.com/Wuvomi/WeChatMulti](https://github.com/Wuvomi/WeChatMulti) · v0.9.0
