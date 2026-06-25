# 第三方来源与依赖溯源

> 本项目用到的外部项目、文件、工具。换对话接手时先读这里 + PROJECT.md。

## 依附的开源项目

### 1. sunnyyoung/WeChatTweak  （byte-patch 引擎，当前主引擎）
- 仓库：https://github.com/sunnyyoung/WeChatTweak ，许可：MIT
- 用途：通过 `brew install sunnyyoung/tap/wechattweak` 得到 `wechattweak` CLI；它读 `config.json`（各微信 build 的函数偏移）把微信主程序 multiInstance 等函数字节改成定值实现多开/防撤回/禁更新。
- 配置来源：https://raw.githubusercontent.com/sunnyyoung/WeChatTweak/refs/heads/master/config.json
- 现状：**作者已停更**，config.json 最后适配 2026-02-08 的 build 34371。新版（4.1.8/4.1.10）需自行找偏移（见逆向 subagent 产物 re/268831-finding.md）。
- 技术：v2.0 = 静态字节 patch；v1.x = dylib 注入。

### 2. X1a0He/X1a0HeWeChatPlugin  （注入引擎，待集成 = 第二条腿）
- 仓库：https://github.com/X1a0He/X1a0HeWeChatPlugin
- 用途：dylib 注入式，**活跃维护**（2026-06 / v2.4.7+），支持 4.1.10.53(39917)/4.1.11.x/40431/40446 等新版，`.pkg` 一键装。
- 集成方向：作为"注入引擎"接进本 GUI，让新版适配交给它（需对齐微信 build 号；用户 4.1.10 是 CFBundleVersion 268831，与其标的 39917 编号体系待对齐）。

### 备选（多为老/未必维护）
- TKkk-iOSer/WeChatPlugin-MacOS、MustangYM/WeChatExtension-ForMac

## 本项目自有代码
- `app/`：SwiftUI GUI（WeChatMultiApp/WeChatModel/ContentView），原创。
- `app/hook/WeChatMultiHook.m`：自写的注入 hook（给 Dock 加「开新微信」右键菜单），原创。

## 用到的文件/资源
- `app/Resources/icon-source.jpg`：用户提供的 App 图标原图。
- `app/Resources/AppIcon.icns`：由上图经 sips+iconutil 生成。
- `app/Resources/menubar.png`：菜单栏模板图 = 微信原版图标双气泡轮廓 + 挖空大叉（CoreImage/CoreGraphics 生成）。
- `re/bins/WeChat_32288.bin`：微信 4.1.5（参考版，multiInstance VA=0x1001e1a74），来自官方 CDN `WeChatMac_4.1.5.dmg`。
- `re/bins/WeChat_268831.bin`：微信 4.1.10（待适配），来自官方 CDN `WeChatMac.dmg`。
- 官方微信 DMG 直链模式：`https://dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac_<版本>.dmg`（无版本号=最新）。

## 工具链
- `wechattweak`(brew)、`radare2`、`codesign`、`sips`/`iconutil`、`swift build`(无需 Xcode)、`hdiutil`。
- `insert_dylib`：注入 dylib 加 LC_LOAD_DYLIB 需要，**尚未安装**。

## 合规
- 各依赖均开源（多为 MIT）。本项目开源时需在 README 注明以上来源与许可。仅供个人在本机使用。
