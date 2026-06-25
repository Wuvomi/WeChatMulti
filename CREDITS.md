# Credits & Attribution · 第三方来源与依赖溯源

> Outside projects, files, and tools this project depends on, plus a clear statement of what is original. When picking the project back up, read this together with `PROJECT.md`.
>
> 本项目用到的外部项目、文件、工具，以及对「哪些是原创」的清晰声明。接手时请连同 `PROJECT.md` 一起读。

---

## Open-source projects we depend on · 依附的开源项目

### 1. X1a0He/X1a0HeWeChatPlugin — Strategy ① injection engine · 方案 ① 注入引擎

- Repo: https://github.com/X1a0He/X1a0HeWeChatPlugin
- Role: an **actively maintained** dylib-injection plugin (v2.4.7+, 2026-06) that supports WeChat 4.1.10.53 (39917) / 4.1.11.x / 40431 / 40446 via a one-click `.pkg`. This project bundles its `.pkg` so the GUI can install it as Strategy ①.
- Mechanism (as reverse-engineered in `re/body-gate-memdiff.md`): Dobby inline hooks — 19 steady-state hooks (5 disable WeChat auto-update, 1 Qt dock menu, 13 Cronet/Mars network-stack file functions for path isolation) plus a 20th hook installed only in second-or-later instances to neutralize the early single-instance gate.
- License: as per the upstream repository — please consult it directly.
- 角色：**活跃维护**的 dylib 注入插件，`.pkg` 一键装；本项目内置其 pkg 供 GUI 作方案 ① 安装。其许可以上游仓库为准。

### 2. sunnyyoung/WeChatTweak — early byte-patch approach · 早期字节补丁思路

- Repo: https://github.com/sunnyyoung/WeChatTweak · License: **MIT**
- Config source: https://raw.githubusercontent.com/sunnyyoung/WeChatTweak/refs/heads/master/config.json
- Role: the `wechattweak` CLI (`brew install sunnyyoung/tap/wechattweak`) reads `config.json` (per-build function offsets) and byte-patches WeChat's `multiInstance` etc. functions to constant return values. v2.0 = static byte patch; v1.x = dylib injection.
- Status: **author has stopped updating** — `config.json` last adapted build 34371 (2026-02-08). Newer 4.1.x builds moved the multi-instance code into the 295MB `wechat.dylib`, which the tool doesn't patch — this is why it can't adapt to 4.1.8+. This informed (but is not used at runtime by) the self-built engine; our GUI still detects WeChatTweak for older builds.
- 角色：`wechattweak` CLI 按 `config.json` 偏移字节补丁微信函数。**作者已停更**（最后适配 build 34371）；新版多开代码搬进 `wechat.dylib` 致其失效——此发现启发了自研引擎。GUI 仍会检测它用于老版本。

### Alternatives (mostly older / unmaintained) · 备选（多为老/未必维护）

- TKkk-iOSer/WeChatPlugin-MacOS
- MustangYM/WeChatExtension-ForMac

---

## WeChat binary source · 微信二进制来源

- **Tencent WeChat official DMG** is the **only** source of any WeChat binary used here. This project **never redistributes** the WeChat binary.
- Official CDN URL pattern (no version = latest): `https://dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac_<version>.dmg` (Tencent serves 3-segment versions like `4.1.5`; 4-segment URLs 404).
- The GUI's "download a compatible build" flow fetches from this official CDN, on the user's own machine, for their own use only.
- 微信二进制**唯一来源**=腾讯官方 DMG；本项目**从不分发**微信二进制。GUI 的「下载兼容版」仅从官方 CDN、在用户本机、供用户自用。

---

## Version / release-date data sources · 版本发布日期数据源

- **WeChat official changelog** (authoritative): https://weixin.qq.com/updates?platform=mac (e.g. 4.1.11 page confirms 2026-06-24).
- **zsbai/wechat-versions**: https://github.com/zsbai/wechat-versions — 4-segment build → date tracking, used as a refinement reference.
- **Rodert/wechat-mac-versions** — historical version coverage + CDN URL pattern reference.
- Note: WeChat's 6-digit `CFBundleVersion` (e.g. `269077`) isn't tracked by public sites; this project maps marketing versions to **month-level** approximate release dates (see `app/VERSION_DATES.md`).
- 主来源=微信官方更新日志（权威）；build 级细化参考 zsbai/wechat-versions、Rodert/wechat-mac-versions。仅做月级近似（见 `app/VERSION_DATES.md`）。

---

## Tools used · 用到的工具链

- **Reverse engineering · 逆向**: `lldb`, `otool`, `nm`, `lipo`, `radare2`, plus a small hand-written arm64 micro-decoder for signature matching.
- **Signing / packaging · 签名与打包**: `codesign` (ad-hoc, per-file, never `--deep`), `hdiutil`, `xattr`.
- **Build · 构建**: Swift toolchain (`swift build`, no Xcode required), `sips` / `iconutil` (icon generation).
- **Injection · 注入**: `engine/insert_dylib.py` (pure-Python `LC_LOAD_DYLIB` inserter — no external `insert_dylib` binary needed), `engine/locate_gate1.py` (runtime gate-① signature locator).
- **Third-party · 第三方**: `wechattweak` (Homebrew), the **Dobby** inline-hook library (as used by X1a0He, under its upstream license).

---

## What is original to this project · 本项目自有 / 原创部分

- **`app/`** — the SwiftUI GUI (`WeChatMultiApp` / `WeChatModel` / `ContentView`), localization, version gatekeeper, and version-date display. Original.
- **`engine/`** — the **self-built injection engine** (`WeChatMultiEngine.m` + built universal `.dylib`), `insert_dylib.py`, `locate_gate1.py`, `install-self-engine.sh`, and the **bundleID-clone fallback** (`install-clone.sh` / `cleanup-clone.sh`). Original.
- **`app/hook/WeChatMultiHook.m`** — the original Dock "open new WeChat" right-click hook (early experiment).
- **`re/`** — the entire reverse-engineering dossier: gate ① / gate ② / gate ③ location, the X1a0He memory-diff decode, the Crashpad clone-kill root cause, and all on-device verdicts. This is **original reverse-engineering work** and is the project's flagship value.
- The self-built engine **does not copy X1a0He's code**; it re-derives the gate mechanics independently (it even takes a *different* path for gate ③ — `NSRunningApplication` swizzle vs. X1a0He's Dobby hooks).
- `app/` 的 SwiftUI GUI、`engine/` 的自研注入引擎与 bundleID 克隆兜底、`app/hook/` 的 Dock hook、整套 `re/` 逆向档案，均为**本项目原创**。自研引擎不抄 X1a0He 代码，独立逆向重建门机制。

### Project-supplied resources · 项目内资源

- `app/Resources/icon-source.jpg` — user-provided app icon original.
- `app/Resources/AppIcon.icns` — generated from the above via `sips` + `iconutil`.
- `app/Resources/menubar.png` — menu-bar template icon (generated via CoreImage/CoreGraphics).

---

## Licensing recommendation · 许可证建议

- **This project's own code** (`app/`, `engine/`, `re/`) → **MIT License** (recommended; permissive, matches the upstream tone). Add a top-level `LICENSE` file when going public.
- **Third-party components keep their own licenses** — WeChatTweak is MIT; X1a0HeWeChatPlugin and Dobby under their respective upstream licenses. When redistributing or building on them, follow each project's terms.
- **The WeChat binary and Tencent assets are NOT covered** by this project's license and are **never** distributed here.
- 自有代码建议 **MIT**；第三方各自保留许可；微信二进制与腾讯资产**不**在本许可范围、**从不**分发。

---

## Compliance · 合规

All dependencies are open source (most MIT). This is a learning/research multi-instance tool that operates only on software the user already has, on the user's own machine. It bundles, cracks, and redistributes **nothing** of WeChat's. When open-sourcing, keep the attributions above and the disclaimer in `README.md` intact.

各依赖均开源（多为 MIT）。本项目是学习/研究性质的多开工具，只在用户本机、用户自有的软件上操作，对微信**不打包、不破解、不分发**。开源时请保留以上署名与 `README.md` 中的免责声明。
