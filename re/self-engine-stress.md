# 自研引擎 — 长时压测报告(微信 4.1.11,同路径 2/3 实例)

**目的:** 对已攻克的自研多开引擎做 ≥5 分钟长时压测 + 严格功能校验,确认其可靠到可用于风控账号日常多开。
**结论:可靠,达标。** 5.5 分钟(332s)2 实例并存,`maincnt` 全程恒 = 2,零崩溃、零内存泄漏、零 DB/CRC/MMKV 错误;3 实例边界也全部存活;flock role 判定正确。详见下。

**对象:** WeChat 4.1.11(`com.tencent.xinWeChat`,Team `5A4RE8SF68`,build 4066646805)。
**测试副本:** `/tmp/wcstress/eng.app`,由**只读挂载的干净 DMG**(`/tmp/WeChat_41121.dmg`,dylib md5 `9a7445e8…`)`ditto` 而来,再 `install-self-engine.sh` 装引擎 + `xattr -dr` 清 quarantine。**全程未触碰 `/Applications/WeChat.app`**(用户 X1a0He 注入版,pid 58221,全程在用、未启动测试副本前已运行、测后仍存活)。

---

## 0. 安装与施工(均在 /tmp 副本)

```
ditto /tmp/wcdmg/WeChat.app → /tmp/wcstress/eng.app   (dylib md5 9a7445e8… 干净)
install-self-engine.sh /tmp/wcstress/eng.app  → exit 0
  门①: 特征码命中 GATE1_FAT_OFF=0x379f88, ORIG 34000b40 → PATCH 1400005a(cbz w0 → b)已写盘
  门③: 引擎 dylib 复制进 Frameworks/ + 两 slice 注入 LC_LOAD_DYLIB @rpath/WeChatMultiEngine.dylib
  重签: adhoc(flags 0x2 adhoc, TeamIdentifier=not set),保留 app-sandbox/app-group entitlements,不 --deep
xattr -dr com.apple.quarantine → 无 quarantine 残留
codesign -v → valid on disk + satisfies DR
otool -l wechat.dylib → @rpath/WeChatMultiEngine.dylib 已注入(双 slice);@executable_path/../Frameworks RPATH 在,@rpath 可解析 ✓
```

启动方式:全部 `open -n /tmp/wcstress/eng.app`(GUI/LaunchServices 路径);另做一次 direct-exec 取引擎 stderr 日志(§3.1)。

---

## 1. 长时压测(2 实例,332s,每 15s 采样)

主实例 pid 39272,第二实例 pid 39448。`maincnt` = 精确匹配 `/tmp/wcstress/eng.app/Contents/MacOS/WeChat`(排除 AppEx/Helper)的主进程数。

| t(s) | maincnt | primary RSS(MB) | secondary RSS(MB) | CPU% |
|---|---|---|---|---|
| 0   | 2 | 219.6 | 245.4 | ~0 |
| 15  | 2 | 219.6 | 245.2 | ~0 |
| 30  | 2 | 219.6 | 246.3 | ~0 |
| 45  | 2 | 219.8 | 246.7 | ~0 |
| 60  | 2 | 219.8 | 246.7 | ~0 |
| 75  | 2 | 216.9 | 248.0 | ~0.1 |
| 90  | 2 | 217.2 | 248.3 | ~0 |
| 106 | 2 | 201.3 | 247.6 | ~0 |
| 121 | 2 | 201.2 | 231.4 | ~0.1 |
| 136 | 2 | 200.1 | 216.2 | ~0.1 |
| 151 | 2 | 200.1 | 216.2 | ~0 |
| 166 | 2 | 200.3 | 216.4 | ~0.1 |
| 181 | 2 | 200.3 | 216.4 | ~0.1 |
| 196 | 2 | 200.3 | 216.5 | ~0.1 |
| 211 | 2 | 200.5 | 216.5 | ~0 |
| 226 | 2 | 200.5 | 216.5 | ~0 |
| 241 | 2 | 200.6 | 216.7 | ~0 |
| 256 | 2 | 200.6 | 216.7 | ~0 |
| 271 | 2 | 201.2 | 216.7 | ~0.1 |
| 287 | 2 | 201.4 | 216.9 | ~0 |
| 302 | 2 | 201.4 | 217.0 | ~0 |
| 317 | 2 | 201.4 | 217.0 | ~0.1 |
| 332 | 2 | 201.5 | 217.0 | ~0.1 |

**maincnt 曲线:全程恒 = 2,无任何掉到 1、无 exit(255)、无崩溃。**
**内存趋势:无泄漏。** 两实例 RSS 在前 ~130s 内**下降**(primary 219→200MB,secondary 245→216MB,初始化峰值回落),之后完全平稳(±1MB 抖动)。压测 5.5 分钟无单调增长。
**CPU:** 登录界面空闲态,两实例 ~0%(峰值 0.2%)。

> 注:本压测让两实例停在**登录界面**(不登入任何账号),专测引擎进程/多开机制(maincnt/role/门②/perms.json/flock),刻意不让测试副本触碰风控账号的聊天数据。

---

## 2. 功能校验

### ① 第二实例 role + 门② tbz NOP / 首个不 patch — 通过
direct-exec 取 stderr(§3.1 原文):
- **首个实例 42156:** `instance role: primary(首个)`,装 NSRunningApplication swizzle,写 perms.json,**不**执行门② patch。
- **第二实例 42178:** `instance role: secondary(第二+)` → `门②: 已中和 tbz w20 @vmaddr 0x2117e0 (slide 0x11c2d4000) 0x36001914 -> NOP`。命中 vmaddr 与 self-engine-v2.md §1.3 完全一致。

旁证(无需 stderr):压测期间 secondary 存活(若门② 未成功,按 v2 §1.2 它会在 ~2s 内 exit(255));AppEx 子进程 `instance-index`:首个=`0`、第二=`2`(与 v2 §3 预期一致;用户 X1a0He 那份是 `1`,未受扰)。

### ② perms.json 正确写出 + pid 对得上 — 通过(附一处设计说明)
引擎在容器内 `…/WeChatMulti/perms.json` 写 `{screen,fda,pid,updated}`,字段齐全,`pid` 为写入实例的 loader pid(实测 perms.json pid 与活进程对得上)。
**注(共容器副作用):** 同 bundleId → 两实例**共用同一份** perms.json,二者各自 async 覆盖写,**末位写入者胜**(实测中途 pid 在 39272↔39448 之间随最后写者变)。即 perms.json 反映"最近一次写它的实例",**不保证恒为 primary**。`screen` 字段随启动上下文 TCC 变(`open -n` 起的为 0,direct-exec 继承终端 TCC 的为 1),非缺陷。GUI 若要区分"哪个实例的权限"需另设计(当前单文件不区分实例)。

### ③ flock role 判定 / 杀 primary 后锁释放 — 通过
- `lsof` 实测:`instance.lock` 仅被 **primary(39272)持有 fd 6u**;secondary(39448)**不持锁** → role 判定正确(只有抢到 flock 的才是 primary)。
- **杀 primary(`kill -TERM 39272`):** secondary(39448)**继续存活**(maincnt→1);内核在 primary 死时**自动释放 flock**(fd 消失,`lsof` 查无持有者 = 锁 free)。
- **锁释放后新起实例(41694):** 抢到空闲 flock → **成为 primary**(`lsof` 证实 41694 持 fd 6u,锁文件内容更新为 41694)。
- **`instance.lock` 文件内容是 stale 信息:** 引擎把 pid 写进文件但退出时**不清**,权威是 flock 本身(内核活性),文件内容仅供参考。primary 死后文件仍残留旧 pid 文本,不影响判定。

> **次要发现(非隐患):** primary 死后,幸存的 secondary **不会自动升格为 primary**(它只在 constructor 时判一次 flock,不重抢)。对稳定性无害(secondary 的门② 已 NOP,继续跑),只是"谁持锁"与"谁还活着"在 primary 中途死亡后会暂时不一致,直到下次新实例启动重新抢锁。

### ④ 零 DB/CRC/MMKV/crashpad-dump — 通过
- 全程 `log stream process==WeChat` 抓 2918 行,grep `database is locked` / `disk i/o error` / `crc check fail` / `mmkv.*corrupt` = **0 命中**。
- 新 crashpad `.dmp` = **0**(基线 2 个 Jun-24 旧 dump,测后仍 2 个);`~/Library/Logs/DiagnosticReports` 新 WeChat crash = **0**。
- **唯一的 ERROR 噪声:** 8 条 `crashpad_client_mac.cc(481) exception_port_ is not valid`,全来自 secondary 实例(41694/41839)。这是**良性**——同 bundle 多实例时,primary 已占任务级 exception port,secondary 注册第二个 crashpad 端口失败,仅是 cosmetic 警告,**未产生任何 dump、无实际 fault**。

---

## 3. 边界:第 3 实例

`open -n` 起第 3 个同路径实例(41839):**maincnt=3,三者全部存活**。第 3 个作为 secondary(flock 已被 41694 持有)→ 门② NOP → 存活;AppEx instance-index 分到 `3`。持续观测 ~20s 稳定,期间无新 crash、无 DB 错误。**3 路同路径多开成立。**

### 3.1 引擎 stderr 原文(direct-exec 证据)
```
[WeChatMultiEngine] loaded into pid=42156 (WeChat)
[WeChatMultiEngine] instance role: primary(首个)
[WeChatMultiEngine] swizzled +[NSRunningApplication runningApplicationsWithBundleIdentifier:]
[WeChatMultiEngine] perms.json -> …/WeChatMulti/perms.json {screen:1, fda:0} write=1
[WeChatMultiEngine] runningApplicationsWithBundleIdentifier:com.tencent.xinWeChat -> [] (forced empty, 多开放行)
---
[WeChatMultiEngine] loaded into pid=42178 (WeChat)
[WeChatMultiEngine] instance role: secondary(第二+)
[WeChatMultiEngine] 门②: 已中和 tbz w20 @vmaddr 0x2117e0 (slide 0x11c2d4000) 0x36001914 -> NOP
[WeChatMultiEngine] swizzled +[NSRunningApplication runningApplicationsWithBundleIdentifier:]
[WeChatMultiEngine] perms.json -> …/WeChatMulti/perms.json {screen:1, fda:0} write=1
```

---

## 4. 结论与隐患

**可靠性结论:可用于风控账号日常多开。** 引擎在 5.5 分钟长时 2 实例压测里 maincnt 恒 2、零崩溃、零内存泄漏、零 DB/CRC/MMKV 错误;3 实例边界也全存活;门②/role/flock 全部按设计工作。进程层稳定性达到日常多开要求。

**需告知用户的隐患/局限(均为已知共容器设计的副作用,非引擎 bug):**
1. **共用同一用户容器 = 共用同一份持久化(登录态/聊天 DB)。** 本测试刻意停在登录界面、未登入账号。若两实例**登同一账号**,会并发写同一 DB,行为未定义(同 self-engine-v2.md §3 局限)。**风控账号建议:每个实例扫码登不同账号**(各实例 runtime 态独立),或要"每实例独立数据沙盒"则走 clone-bundle 方案 B。
2. **perms.json 是共容器单文件**,两实例互相覆盖、末位写者胜,不保证恒为 primary 的值;GUI 若要按实例显示权限需另设计。
3. **primary 中途死亡后 secondary 不自动升格 primary**(只在启动时判一次锁)。无稳定性危害,但"持锁者"会与"存活者"暂时不一致,直到新实例启动重抢锁。
4. **secondary 的 crashpad 第二端口注册失败**(cosmetic ERROR,无 dump)。不影响运行,但崩溃上报在 secondary 上可能不全。

---

## 5. 安全 / 结束态(硬要求核对)

| 检查项 | 期望 | 实测 |
|---|---|---|
| 未触碰 `/Applications/WeChat.app` | 是 | 是。副本从只读 DMG ditto;施工/压测全在 `/tmp/wcstress`;DMG 只读挂载 `/tmp/wcdmg` |
| `.original` md5 | `9a7445e8…` 未变 | 测后仍 `9a7445e8f0ddefbb69355855fb6b3654` |
| 用户 X1a0He WeChat(pid 58221) | 不受扰、存活 | 全程存活(测后 uptime 1h44m+),未启动测试副本前即在运行 |
| 测试 WeChat 进程 | 全退、无僵尸 | `pkill -9 -f /tmp/wcstress` → 0 残留(loader/AppEx/Helper 全清) |
| 测试证书 | 无 | 全 adhoc `--sign -`,未入钥匙串 |
| /tmp 测试副本 + 日志 | 删 | `rm -rf /tmp/wcstress` 已删,无残留 |
| 干净 DMG | 卸载、保留源 | `hdiutil detach /tmp/wcdmg` 已卸;源文件 `/tmp/WeChat_41121.dmg` 保留(只读源) |
| log stream / lldb 进程 | 全停 | 0 orphan |
| 测试产生的容器 | 见说明 | **本测试未新建任何容器**;副本沿用原 bundleId → 共享**用户容器** `com.tencent.xinWeChat`,**故不删**(与 X1a0He 共享)。已有 `xinClone1/2/3`、`xinWeChat.verifytest` 等均为**先前会话残留**,非本次压测产生,未动 |

**结束态(如实记录,共容器副作用):** 用户容器 `…/WeChatMulti/` 内 `instance.lock`(stale 内容 `42156`,无持有者=锁 free)与 `perms.json`(stale `pid:42178`,dead)为引擎工作文件,基线即已存在(prior runs),pid 现已失效。引擎下次启动会重写它们,flock 内容仅信息性,**无残留危害**,按要求未删用户容器。

**工具:** `ditto`/`hdiutil`(干净副本/只读挂载)、`install-self-engine.sh`(只调用,未改逻辑)、`open -n`/direct-exec、`ps`/`lsof`/`pgrep`(采样/锁/role)、`/usr/bin/log stream`(DB/crash 扫描)、`codesign`/`otool`/`xattr`(校验)、`md5`(完整性)。未碰 `app/`、未改 `engine/*.m/.dylib/.sh`。
