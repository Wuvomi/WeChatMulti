# `open -n` 同-bundle 叠开验证 —— 决定性结论

**问题:** 给 `/Applications/WeChat.app` 打上多开 byte-patch（fat 偏移 `0x0acbdee8`：`f5079f1a`→`15008052`，钉死 `NSRunningApplication` 单例谓词）+ ad-hoc 重签后，对**同一个 bundle** 用 `open -n` 叠开，能不能产生**两个并存的微信实例**？

**这决定自研 byte-patch 引擎是否必须克隆 .app。**

测试日期 2026-06-24，机器 arm64，微信 4.1.11 (269077)。进程计数口径：`pgrep -f 'WeChat.app/Contents/MacOS/WeChat$'`（排除 crashpad/WeChatAppEx 等子进程）。

---

## 0. 一句话结论

> **不行。** 同-bundle `open -n` 叠开**得不到**两个并存实例。byte-patch 后第二个 `open -n` **确实 fork 出新进程**，但新实例**约 1.5–2 秒后自行退出**（干净退出，非崩溃），稳态永远回到 **1 个**。
>
> **=> 纯 byte-patch 引擎必须克隆 bundle（改 `CFBundleIdentifier`）才能稳定多开。**`open -n` 这条路不通。

---

## 1. 核心测试证据（patched + 重签后）

环境：`/Applications/WeChat.app` 已替换为 clean-original + 1.1 单点 patch 的 dylib，`codesign --force --sign -` dylib + `codesign --force --deep --sign -` 整 app（`--verify --deep` rc=0）。先退掉所有微信（count=0），再连续 `open -n`。

三次连续 `open -n /Applications/WeChat.app`，0.5s 采样：

```
原始存活实例 PID 82436（第一个 open -n 起的，常驻）

--- open#1 -> 新 PID 83421 ---
  +0.5s cnt=2 [82436 83421]
  +2.0s cnt=2 [82436 83421]
  +2.5s cnt=1 [82436]          ← 83421 自退
  ...稳定 cnt=1

--- open#2 -> 新 PID 83693 ---
  +0.5s cnt=2 [82436 83693]
  +1.5s cnt=2 [82436 83693]
  +2.0s cnt=1 [82436]          ← 83693 自退
  ...稳定 cnt=1

--- open#3 -> 新 PID 83967 ---
  +0.5s cnt=2 [82436 83967]
  +1.5s cnt=2 [82436 83967]
  +2.0s cnt=1 [82436]          ← 83967 自退
  ...稳定 cnt=1
```

每次 `open -n` 都给出一个**全新 PID**（83421 / 83693 / 83967，互不相同），证明 LaunchServices **确实拉起了新进程**（不是单纯 activate 已有窗口）。但每个新进程活 ~1.5–2s 即终止，**稳态实例数恒为 1**。

退出性质：新进程死亡后 `~/Library/Logs/DiagnosticReports` **无 WeChat 崩溃报告** => **干净自退**（应用主动 `exit`），不是被杀/崩溃/abort。退出前进程状态 `S`（正常睡眠），无 abort 迹象。

对比文档 §3 里"两个不同 .app（/Applications + /tmp 副本）并存"的实测 —— 那是**跨 bundle**，能并存 2 个；本次**同 bundle** 不行。两者一起把边界钉死了。

---

## 2. 根因：单例门有第二道，在 byte-patch 覆盖范围之外

byte-patch（`func.00ec5e84` 谓词，钉 `count!=0`→0）只覆盖了**消费 `NSRunningApplication` 结果的那一处 ObjC 谓词**。但同-bundle 启动时还存在**另一道更早的单例门**，它**不经过**被 patch 的那条指令，因此第二实例仍被判定为"已有实例运行"而主动退出。

这道门的特征（与文档 §4 一致）：
- **键在 bundle 身份（path + CFBundleIdentifier 相同）**。同 path+id 的去重发生在**应用启动早期 / LaunchServices·loader 协作层**，不在被 patch 的那几个 ObjC 谓词里。
- 文档已记录：patch `0x1cc38c`（另一处 `runningApplicationsWithBundleIdentifier:` xref）对同-bundle 叠开同样**无效**。
- X1a0He 能同-bundle 叠开，靠的是**插件侧 NSTask / `setLaunchPath:` re-launcher**（重新 exec 拉起），而**不是**靠翻这个谓词——这反向印证了 plain `open -n` 走不通。

要把同-bundle `open -n` 也打通，需要静态定位并 patch 这第二道早期门（成本/稳定性未知，且可能涉及 LaunchServices 注册层，未必纯字节可改），**性价比远低于克隆 bundle**。

---

## 3. 对 byte-patch 引擎的决定

**必须克隆 .app（改 BundleID）。** 推荐姿势（文档 §4/§5 已验证原理）：

```
ditto /Applications/WeChat.app /Applications/WeChatB.app
# 改 WeChatB.app/Contents/Info.plist 的 CFBundleIdentifier，如 com.tencent.xinWeChat.b
# 对 WeChatB 的 wechat.dylib 打 0x0acbdee8 patch
codesign --force --sign -        WeChatB.app/Contents/Resources/wechat.dylib
codesign --force --deep --sign - WeChatB.app
open -n /Applications/WeChatB.app   # 与主 WeChat.app 各自一个实例并存
```

不同 bundleId 各自独立单例域，叠几个就克隆几份。每份 patch + ad-hoc 重签即可（无需 Sec hook，见文档 §6.4）。

> 注意：克隆多开时多实例共用同一容器 `~/Library/Containers/com.tencent.xinWeChat`，受账号级 `lock.ini`（flock）天然互斥 —— **同账号双开**仍需额外做数据目录/容器隔离（另一道工程）；**不同账号**各实例直接并存。

---

## 4. ⚠️ X1a0He 恢复完好性确认（硬要求 —— 已完整恢复）

测试全程对 `/Applications/WeChat.app` 做了写操作（替换 dylib + 重签）。**测试后已完整恢复 X1a0He 版并实测可用**，最终结束态：

| 检查项 | 期望（X1a0He 版） | 实测结束态 |
|---|---|---|
| `Contents/Resources/wechat.dylib` md5 | `52bb2c9e4c0cb755ab9a82db52e6b8b8` | **一致** ✓ |
| `Contents/Frameworks/X1a0HeWeChatPlugin.dylib` md5 | `9ea5524d90f6e9abecd2df4040529c42` | **一致** ✓ |
| `wechat.dylib.original`（干净底子）md5 | `9a7445e8f0ddefbb69355855fb6b3654` | **一致** ✓ |
| 活体 dylib 内 X1a0He `LC_LOAD_DYLIB` 引用 | 2 | **2** ✓ |
| `codesign --verify`（顶层 + 资源封签）| 通过 | **rc=0** ✓ |
| 嵌套 bundle（WeChatAppEx.app 等）TeamIdentifier | `5A4RE8SF68`（腾讯原签）| **保留腾讯原签** ✓ |
| entitlements（app-sandbox / application-groups …）| 保留 | **保留**（adhoc 顶层 + 完整 entitlements）✓ |
| 启动 1 个实例并常驻 | 可启动且 X1a0He 插件加载 | **PID 88984 常驻 >15s；`vmmap` 确认 `X1a0HeWeChatPlugin.dylib` `__TEXT` 已映射入内存** ✓ |

> `Contents/MacOS/WeChat`（loader stub）md5 与备份不同（`196f76de…` vs 备份 `7dd1cebd…`）——**这是正确预期**：恢复时对顶层可执行做了 adhoc + entitlements 重签会改变其字节，但仍带 X1a0He 加载命令（LC refs=2 已确认）且实测正常加载插件。

### ⚠️ 关键踩坑 + 正确恢复法（重要，记录给引擎复用）

**坑：`codesign --force --deep --sign -` 会把嵌套 bundle/framework 的腾讯团队签名也 adhoc 重签掉，导致丢失 TeamIdentifier `5A4RE8SF68`。** 一旦顶层或嵌套失去团队身份，`containermanagerd` 会拒绝该 app 访问团队前缀的 **group container** `5A4RE8SF68.com.tencent.xinWeChat`（日志：`REJECTED. Group containers identifiers should be prefixed by requestor's team ID`），微信启动后 **~4 秒干净自退**（无崩溃报告，sandbox 拒绝）。第一次恢复就栽在这——`--deep` adhoc 重签后微信起不来。

**正确恢复法（已验证可用）：**
1. 从干净 DMG `/tmp/WeChat_41121.dmg` `ditto` 装回**原版腾讯签名** WeChat.app（嵌套 bundle 全部保留 `5A4RE8SF68` 团队签）。
2. 只替换 3 个 X1a0He 文件：`Contents/Resources/wechat.dylib`、`Contents/Frameworks/X1a0HeWeChatPlugin.dylib`、`Contents/MacOS/WeChat`（从 scratchpad `backup_x1a0he/`，md5 逐字节一致）。
3. 单独 adhoc 签这两个 dylib：`codesign --force --sign - wechat.dylib` / `... X1a0HeWeChatPlugin.dylib`。
4. **只签顶层、不加 `--deep`**，并带 entitlements 重新封资源：
   `codesign --force --sign - --entitlements entitlements.xml /Applications/WeChat.app`
   —— 这样嵌套 bundle 的腾讯团队签**保持不动**，group container 访问不被拒，微信常驻。

> 对自研 byte-patch / 克隆引擎的直接启示：**重签时绝不能对整个 app 用 `--deep` adhoc**，否则破坏沙盒/group-container 访问。正确做法 = 只 adhoc 签被改动的 mach-o（dylib/plugin）+ 顶层可执行（带 entitlements）重新封 CodeResources，**保留嵌套 bundle 的原厂团队签名**。

**结论：X1a0He 已完整恢复、签名有效、插件实测加载入内存、实例常驻可正常用。** 备份 `backup_x1a0he/` 与干净 DMG（`/tmp/WeChat_41121.dmg`，可重复 `ditto` 重装）仍在。

---

## 附:patch 参数（复用文档 §1.1，本次已二次实测原始字节）

| 项 | 值 |
|---|---|
| fat 文件偏移 | `0x0acbdee8` |
| 原始 4 字节 | `f5 07 9f 1a`（`cset w21, ne`）— 本次 patch 前已 assert 确认 |
| patched 4 字节 | `15 00 80 52`（`mov w21, #0`）|
| 重签（patch 测试时）| `codesign --force --sign -` dylib → `codesign --force --deep --sign -` app |

> 注：上面 patch 测试用的 `--deep` 重签对**纯净克隆 .app**（无沙盒 group-container 依赖的简单场景）能 verify 通过；但若 app 依赖团队前缀的 group container（微信正是如此），`--deep` adhoc 会破坏访问 —— 见 §4 关键踩坑。引擎落地克隆多开时建议沿用 §4 的"只签顶层 + 保留嵌套原签"策略更稳。
