# bundleID 终极兜底 — 纯克隆稳定签名配方裁定（坐实）

**对象:** WeChat 4.1.11（build 269077，来自 `/tmp/WeChat_41121.dmg`：官方签名、`flags=0x10000(runtime)`、`TeamIdentifier=5A4RE8SF68`）。
**全程未写 `/Applications/WeChat.app`**（X1a0He 用户在用，结束态 codesign valid、`wechat.dylib.original` 备份完好 320605168B、无测试证书入钥匙串、全 adhoc）。施工全在 `/tmp/wcclone_fix`（已删）+ 只读挂载 DMG（已卸载）。

---

## 0. 一句话结论

> **纯克隆（零注入、零 byte-patch、版本无关）的微信能稳定存活**，关键签名配方 = **`application-identifier` / `application-groups` 保留 `5A4RE8SF68` team 前缀、只把 bundle 后缀换成新 id（`5A4RE8SF68.com.tencent.xinCloneN`），`app-sandbox` 保留，adhoc 逐文件重签、绝不 `--deep`**。
>
> 此前裸克隆"约 15s 被杀"的真凶**不是系统宽限期杀**，而是微信内置的 **Crashpad** 崩溃处理器启动时 `bootstrap_check_in` 一个名为 `5A4RE8SF68.<bundleId>.crashpad.*` 的 mach 服务——沙盒只放行进程注册【自己 `application-identifier` 的 team 段】为前缀的 mach 名。adhoc 把 app-identifier 写成无 team 前缀（`com.tencent.xinClone1`）→ 注册 `5A4RE8SF68.*` 被 `deny(1100)` → 进程 **SIGTRAP 自退（exit 133）**。补回 team 前缀 → Crashpad 注册成功 → 不再自退。
>
> **实测：脚本产出的克隆经 `open -n` 启动，存活 >92s 全程不被杀；两个不同 id 克隆并存 95s 全程双活**，各自独立数据容器 + 独立 group 容器 + 独立登录窗口（QR 登录界面，未真登录）。

---

## 1. 被杀根因（日志铁证）

裸克隆改 `application-identifier=com.tencent.xinClone1`（**无 team 前缀**，变体 B），直接 exec，约 5s 死。`wait $PID` 捕获 **exit code = 133 = 128+5 = SIGTRAP**。stderr 首条致命错误：

```
[ERROR:bootstrap.cc(65)] bootstrap_check_in
  5A4RE8SF68.com.tencent.xinClone1.crashpad.child_port_handshake.32242.6453462.LTHIBAFDJZDSBNFF:
  Permission denied (1100)
[ERROR:file_io.cc(94)] ReadExactly: expected 4, observed 0
[ERROR:crashpad_client_mac.cc(481)] exception_port_ is not valid
```

- 注意 mach 服务名前缀 **`5A4RE8SF68`**（team）是 Crashpad/Chromium 按 `<team>.<bundleid>.crashpad…` 拼的，写死在二进制行为里。
- 沙盒 mach-register 命名空间 = 进程 `application-identifier` 的 team 段。app-identifier 无 team → 注册 `5A4RE8SF68.*` 越权 → deny(1100) → Crashpad `exception_port_` 失效 → 进程 SIGTRAP。
- **不是宽限期杀**：无 crash report 落 DiagnosticReports（自身 SIGTRAP 退，非系统 `kill`）；`containermanagerd` 此时已成功建好容器（日志 `Successfully updated schema (0)→(44)` + `Wrote …metadata.plist`）。所以"容器建得起、进程却 5~15s 死"正是 Crashpad 这条线，与容器/沙盒授权无关。

> 修正 PROJECT.md 旧判断"app-group 绑腾讯 team 不匹配 → 宽限被杀 / 删掉 → app-sandbox 起不来"：真凶是 **Crashpad mach 注册前缀**，根治办法是 team 前缀，而非删 app-group。

---

## 2. 签名配方（逐项裁定）

| entitlement | 取舍 | 理由 |
|---|---|---|
| `com.apple.security.app-sandbox` | **保留 `true`** | 删掉则容器/能力体系不建、且偏离原 app 行为。保留即可正常起（配 team 前缀后不被杀）。 |
| `com.apple.application-identifier` | **`5A4RE8SF68.com.tencent.xinCloneN`**（team 前缀 + 新后缀） | **决定沙盒 mach 注册前缀**，放行 Crashpad `5A4RE8SF68.*.crashpad.*`。无 team 前缀 = 被杀根因。 |
| `com.apple.security.application-groups` | **`5A4RE8SF68.com.tencent.xinCloneN`**（team 前缀 + 新后缀） | 跟随 app-identifier。新后缀 → 各克隆**独立 group 容器**（`~/Library/Group Containers/5A4RE8SF68.com.tencent.xinCloneN`），不与原版/彼此串数据。保留腾讯原 `…xinWeChat` 也能起，但会共享 group 容器（不利隔离），故换后缀。 |
| `com.apple.security.cs.allow-jit` 等 `cs.*` | 保留 | 微信用 JIT（小程序/WebKit）。 |
| `device.camera/audio-input/usb`、`personal-information.*`、`files.*`、`network.*`、`print` | 保留原值 | 功能能力，缺则对应功能受限；不影响存活，照搬原 entitlements 即可。 |
| `temporary-exception.mach-lookup.global-name`（`com.tencent.xinWeChat-spks/spki`）| 保留 | 微信内部 XPC 名查，保留无害。 |
| `temporary-exception.sbpl`（usbmuxd）| 可留可删 | 与存活无关；脚本未带也稳。 |
| 签名方式 | **adhoc（`codesign --sign -`），逐文件，绝不 `--deep`** | `--deep` 会把嵌套原厂签也 adhoc 化并打乱顺序。正解：嵌套 bundle（按路径长度**深→浅**）先各自 adhoc 签，**顶层可执行 + bundle 带 entitlements 最后签**。 |
| quarantine | `xattr -dr com.apple.quarantine` | 防 App Translocation（adhoc 重签后移除不影响签名有效性）。 |

embedded entitlements 实测正确写入；`codesign --verify --verbose=2` 通过（`valid on disk` + `satisfies its Designated Requirement`）。`flags=0x2(adhoc)`、`TeamIdentifier=not set`（adhoc 本就无真 team；team 前缀只活在 entitlement 字符串里供沙盒命名用）。

---

## 3. 并存 / 存活实测证据

**A. 单克隆经脚本产出 + `open -n` 启动，>92s 不被杀：**
```
open -n WeChatClone3.app  (脚本 install-clone.sh 3 产出，源=干净 DMG)
[t+15s..t+90s] alive pid=34618  (每 15s 采样全 alive)
RESULT: ALIVE past 92s ✓
container: ~/Library/Containers/com.tencent.xinClone3 (独立, 2.8M)
group:     ~/Library/Group Containers/5A4RE8SF68.com.tencent.xinClone3 (独立)
log 复核: 无 "xinClone3.crashpad … denied"（被杀根因已消除）
```

**B. 两克隆并存 95s 全程双活（多实例铁证）：**
```
clone1 (com.tencent.xinClone1) PID 32554
clone2 (com.tencent.xinClone2) PID 32555
[t+1s..t+90s] 两者全 alive（10 次采样全双活），both-alive 达 95s
各自独立容器: xinClone1 4.0M / xinClone2 2.4M（数据各异 = 真隔离）
各自独立 group 容器: 5A4RE8SF68.com.tencent.xinClone{1,2}
CGWindowList: clone1/clone2 各 1 个窗口，标题 "Weixin"（QR 登录界面，未真登录）
```

两实例同一份二进制、不同 bundleId、各自独立容器，**并存 >90s 远超要求**。换 id 即绕开微信所有按 bundle 身份判定的单实例门——**零注入、零 patch、版本无关**，故微信升级后零适配。

---

## 4. `engine/install-clone.sh` 用法 + 局限

### 用法
```
install-clone.sh <N> [源app] [目标目录]
  N        克隆尾号(字母数字) → bundleId=com.tencent.xinCloneN
  源app     默认 /Applications/WeChat.app（只读克隆，不改原版）
  目标目录   默认 ~/Library/Application Support/WeChatMulti/Clones
输出: 稳定可用的 <目标目录>/WeChatCloneN.app（stdout 末行打印其绝对路径）
```
脚本做的事（幂等，重复同 N 会重建）：
1. `ditto` 源 → 目标；
2. **还原干净业务体**：若克隆内有 `wechat.dylib.original` 则 `mv` 回 `wechat.dylib`，并删 `Frameworks/X1a0HeWeChatPlugin.dylib` → 保证是**纯克隆**（剥离 X1a0He 注入）；
3. 改顶层 `CFBundleIdentifier=com.tencent.xinCloneN`；
4. 生成 §2 配方 entitlements（team 前缀 app-identifier/group + app-sandbox + 能力位）；
5. 逐文件 adhoc 重签（嵌套深→浅，顶层最后带 entitlements），**无 `--deep`**；
6. `xattr -dr com.apple.quarantine`；
7. `codesign --verify` 校验。

启动（GUI 用 `open -n` 即可，实测稳定）：`open -n <…/WeChatCloneN.app>`。

### 局限
- **独立容器 = 独立登录态**：每个 `com.tencent.xinCloneN` 有自己的 `~/Library/Containers/…` 和 group 容器，与原版（X1a0He 用的 `com.tencent.xinWeChat` 容器）**数据完全隔离**——克隆里要重新扫码登录，看不到原版聊天记录。这正是"按账号隔离"的取舍：想要独立账号 → 用克隆（天然隔离）；想共享原版数据 → 用注入方案（X1a0He/自研引擎，共用同一容器）。
- 每个克隆占盘 ~1.3GB（.app 全量副本）。后续可优化为符号链接共享大资源，但会增加复杂度/熵。
- adhoc 克隆**无法过 App Store 收据校验**（本就不需要）；微信应用层签名自检实测未拦（与注入方案同结论）。
- 源若为注入版且**无 `.original` 备份**，脚本无法还原干净业务体 → 会告警，建议改用官方 DMG 干净源克隆。

---

## 5. 容器清理（供 GUI 删克隆 / 重置调用）—— `engine/cleanup-clone.sh`

删一个克隆要删三处：① `.app` 本体 ② 数据容器 `~/Library/Containers/com.tencent.xinCloneN` ③ group 容器 `~/Library/Group Containers/5A4RE8SF68.com.tencent.xinCloneN`。

```
cleanup-clone.sh <N> [克隆目录]
```
脚本：先 `pkill` 在跑的该克隆 → 删 .app → 删 group 容器 → 删数据容器 → 校验。

### ★ 关键限制（实测，必须让 GUI 知道）
**数据容器里的 `.com.apple.containermanagerd.metadata.plist`（约 36KB）受 macOS「完全磁盘访问(FDA)」TCC 保护**（非 SIP/rootless——目录无 `restricted` flag）：
- **不带 FDA 的进程** `rm` 它 → `Operation not permitted`，整个数据容器目录删不掉（剩个 36KB 空壳）。实测连 Finder（`osascript tell Finder to delete`）在无交互授权下也删不掉。
- `.app` 本体 + group 容器**不受此限**，任何进程都能删。
- **GUI 落地建议**：
  1. "清理克隆"前**检测 FDA**（试读 `~/Library/Application Support/com.apple.TCC/`，失败=未授予）；
  2. 未授予则引导用户到 **系统设置 > 隐私与安全性 > 完全磁盘访问** 勾选本 App，再执行清理；
  3. 授予 FDA 后 `rm -rf ~/Library/Containers/com.tencent.xinCloneN` 即可彻底删除（含受保护 metadata）。
- 删 .app 时连带删容器，确保不留残留占空间（FDA 到位时 36KB 空壳也会一并清掉）。

---

## 6. 安全 / 结束态

| 检查项 | 期望 | 实测 |
|---|---|---|
| 未写 `/Applications/WeChat.app` | 是 | 是（只读克隆源；codesign `valid on disk` + DR 满足；`wechat.dylib.original` 320605168B 完好） |
| 测试克隆进程 | 全退 | `pgrep WeChatClone` = 0 |
| `/tmp/wcclone_fix` | 删 | 已删 |
| 挂载的 DMG | 卸载 | `disk4 ejected` ✓ |
| 测试证书 | 无（全 adhoc） | 钥匙串无 wechat/clone 身份 ✓ |
| 测试克隆 group/数据容器（可删部分） | 删 | group 容器全删；数据容器删到只剩 36KB TCC 保护壳（×3=108KB），**需用户授 FDA 或 Finder 交互删除**才能清掉最后的 metadata 壳——本 shell 无 FDA 删不动（已尽力，残留极小且无数据）。 |

> 残留说明：`~/Library/Containers/com.tencent.xinClone{1,2,3}` 各剩 36KB 的 `.com.apple.containermanagerd.metadata.plist` 空壳（数据/group 容器/.app 全清）。受 FDA TCC 保护，无 FDA 的进程（含本测试 shell、Finder 非交互）删不掉。用户彻底清除：给 Terminal/本工具授【完全磁盘访问】后执行
> `rm -rf ~/Library/Containers/com.tencent.xinClone1 ~/Library/Containers/com.tencent.xinClone2 ~/Library/Containers/com.tencent.xinClone3`
> 或在访达里删除这三个目录（会弹一次授权）。
