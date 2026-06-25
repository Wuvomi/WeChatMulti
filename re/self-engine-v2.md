# 自研引擎 v2 — 真·同路径多开(方案 A 完成)实测报告(微信 4.1.11)

**目标:** 同一个 WeChat.app 副本,`open -n` / 直接 exec 起 **2 个同路径实例并存且稳定 >60s**,不靠 clone-bundle、不抄 X1a0He 整套插件,门全是自研代码。
**结论:达成。** 见 §1 实测。

**对象:** WeChat 4.1.11(`com.tencent.xinWeChat`,Team `5A4RE8SF68`,build 269077)。
`wechat.dylib` md5 `9a7445e8f0ddefbb69355855fb6b3654`(= `/Applications/.../wechat.dylib.original` = `/tmp/WeChat_41121.dmg` 内 dylib,三者一致)。
**全程未写 `/Applications/WeChat.app`**(用户 X1a0He 注入版在用,只读;施工/实测全在 `/tmp/wcv2` 副本)。结束态见 §6,`.original` md5 测后仍 `9a7445e8…` 未变。

---

## 0. 一句话结论 + 对前序配方的关键修正

> **真门②不是"把 WeChatMain 的 stp 序言改 b"——那一刀腾讯出厂二进制里已经做好了。** `wechat.dylib` 导出符号 `_WeChatMain`(vmaddr `0x1637c`)的**首条指令在干净 DMG 里就已经是 `b 0x2106bc`(字节 `d0 e8 07 14`)**,init 链(`0x16380` 起的 `stp` 序言)在磁盘上本就被跳过。`body-gate-memdiff.md` §2 把这处标成 `0x16380` 并当成"X1a0He 第二实例才装的 hook",是 **off-by-4 的误读**:`0x1637c` 是符号处的 `b`,`0x16380` 才是被跳过的原 `stp`。引擎对这处**无需任何 patch**。
>
> **真正卡死第二实例、让它 `exit(255)` 的门②,在 `0x2106bc`("放行入口"函数)里的一条 `tbz w20, #0x0, <bail>`**(slice/vmaddr `0x2117e0`,字节 `14 19 00 36`)。`w20` = "可启动"布尔;第二实例里 `bit0=0` → 跳 `bail`(`0x211b00 mov w20,#-1`)→ `WeChatMain` 返回 `-1` → loader 把 `-1` 当退出码 → **`exit(255)`**。**中和 = 把这条 `tbz` 改成 `NOP`**,实测第二实例存活。
>
> **门② 必须只在"第二+实例"装**(首个实例不能动,否则它本身的单例语义被破坏)。第二实例判据**不能用 NSRunningApplication / proc_listpids**:前者数不到非 LS 注册实例,后者被 App Sandbox 挡住看不到别的进程(实测两实例都被判成"首个")。**改用容器内 `flock` 锁文件**(沙盒内可靠,活性由内核保证)。
>
> **门①**(loader mach 单例 cbz)仍按 `locate_gate1.py` 静态 byte-patch。**门③**(NSRunningApplication swizzle)保留,但实测**它单独不足以放行**(装了门①+门③、没门②时第二实例照样 `exit(255)`,§1.2),只用来消 UI 层"已有实例"提示。
>
> **数据隔离:** 实测**不需要额外做**。两实例共用同一容器,WeChat 的 MMKV 以 `InterProcess 1`(多进程模式,自带文件锁)打开,AppEx 子进程按 `--instance-index=N` 区分,75s 实测**零** DB-lock / CRC / 崩溃。真·按账号隔离仍需 clone-bundle(同 X1a0He 的局限),如实记录于 §3。

---

## 1. 实测证据

### 1.1 两实例并存稳定 >70s(铁证)

`/tmp/wcv2/eng.app`(干净副本 + 门①静态 patch + 引擎注入含门②运行时跳转 + adhoc 重签):

```
direct-exec 起 2 实例,逐 5s 采样,maincnt = MacOS/WeChat 主进程计数:
t=0s   maincnt=2     t=36s  maincnt=2
t=5s   maincnt=2     t=41s  maincnt=2
...                  ...
t=66s  maincnt=2     t=71s  maincnt=2
SUCCESS both alive >=70s    ← 全程 maincnt=2,无 exit(255)、无崩溃
```

`open -n`(GUI/LaunchServices 路径,`createsNewApplicationInstance=YES`)同样起 2 实例并存:
```
open -n /tmp/wcv2/eng.app  ×2  → 同时 2 个 /private/tmp/wcv2/eng.app/.../MacOS/WeChat 常驻
maincnt 持续 ≥2(实测到 40s 时被并行测试干扰升到 3,仍 ≥2)
```
> 注:这推翻了 `self-engine.md` §4 "LS 去重把同 bundleId 限制成 1 实例"的旧结论。旧结论是因为当时**没有门②**,`open -n` fork 出的第二实例起来后立刻 `exit(255)`,看起来像"被 LS 去重"。装上门② 后,`open -n` 确实 fork 出第二实例**且它能存活** → 真同路径多开成立。

### 1.2 对照:没门② → 第二实例 `exit(255)`(门②是真门的铁证)

| 配置 | 第二实例结局 |
|---|---|
| 干净副本(原签名,无任何 patch) | `exit` at ~2s(`alive2=0`) |
| 门①patch + 门③swizzle,**无门②** | **`exit(255)` at ~2s**(引擎日志证实业务体调了 `runningApplicationsWithBundleIdentifier:` 且我方 swizzle 返回了 `[]`,**但仍死**)|
| 门①patch + 门③swizzle + **门② NOP** | **存活 >70s**(§1.1)|

⇒ **门③(NSRunningApplication swizzle)单独不足以放行**;`exit(255)` 来自 `WeChatMain` 返回 `-1`(lldb 实测 `WeChatMain` 对第二实例 `finish` 得 `w0=0xffffffff`,loader 把它当退出码),根因是 `0x2117e0` 的 `tbz w20`。门② NOP 掉它,才真放行。

### 1.3 引擎运行日志(第二实例)

```
[WeChatMultiEngine] loaded into pid=73228 (WeChat)
[WeChatMultiEngine] instance role: secondary(第二+)
[WeChatMultiEngine] 门②: 已中和 tbz w20 @vmaddr 0x2117e0 (slide 0x11c8cc000) 0x36001914 -> NOP
                                              ↑ 运行时按特征码定位,非硬编码
```
首个实例日志为 `instance role: primary(首个)`,**不**执行门② patch。

---

## 2. 门② 的运行时定位法(WeChatMain 跳转 / 单例放行判定)

**不硬编码任何偏移**,全在第二实例 constructor 里现算:

1. **找 `wechat.dylib` 镜像 + slide:** 遍历 `_dyld_image_count()`,匹配镜像名后缀 `/Resources/wechat.dylib`,取 `_dyld_get_image_header` + `_dyld_get_image_vmaddr_slide`。
2. **取 `__text` 节:** `getsectiondata(mh, "__TEXT", "__text", &size)`(返回已带 slide 的运行时指针)。
3. **特征码扫门②那条 `tbz w20,#0,<bail>`**(位移 imm14 随 build 变,故掩掉):
   ```
   word & 0xFFF8001F == 0x36000014        ; = tbz w20, #0, <任意目标>
   且其后紧跟:
     word[i+1] >> 26 == 0x25  (bl)
     word[i+2] >> 26 == 0x25  (bl)
     word[i+3]       == 0x52800040  (mov w0, #2)   ← 消歧,锁定唯一命中
   ```
   本 build 命中 slice/vmaddr `0x2117e0`(该 dylib `__text` 节 fileoff==vmaddr,故也是 fat 内偏移基)。原 20 字节窗口(`0x2117dc` 起):
   ```
   bf 76 87 95 | 14 19 00 36 | 64 fc cd 94 | 95 fc cd 94 | 40 00 80 52
   bl __ZdlPvm   tbz w20,#0    bl            bl            mov w0,#2
   ```
4. **改写:** `tbz`(`14 19 00 36`)→ `NOP`(`1f 20 03 d5`)。解页用 `vm_protect(…, VM_PROT_READ|WRITE|COPY)`(可越过页 max_prot 限制),失败再 `mprotect(RWX)` 兜底(X1a0He 同款双保险);写完复原 `RX` + `sys_icache_invalidate` 刷 i-cache。
5. **幂等/自校验:** 命中点若已是 `NOP` → 跳过;若字节不符特征 → 放弃不写(graceful,日志记 "特征码未命中",第二实例此时会自然 `exit(255)`——不会崩,只是多开失效,提示该 build 需重新逆)。

> **WeChatMain 那条 `b 0x2106bc`(`0x1637c`)无需运行时算 imm26** —— 它出厂即在。引擎只算门② 的 `tbz` 定位,不动 `WeChatMain`。若未来某 build 退回到"`WeChatMain` 首条是 `stp`、init 链含单例 exit",再按 `body-gate-memdiff.md` §5 (A) 补 `WeChatMain`→`b` 那一刀(imm26 = `(0x2106bc等价点 - WeChatMain)>>2`,同样特征码现算)。

**第二实例判据(为何用 flock):**
- `NSRunningApplication runningApplicationsWithBundleIdentifier:` → `open -n`/exec 起的实例不一定 LS 注册,数不到(实测两实例都判 primary)。
- `proc_listpids`+`proc_pidpath` → 独立进程可用,但**注入进沙盒微信里被 App Sandbox 挡住**,枚举不到同路径别的进程(实测同样判 primary)。
- ✅ **容器内 `flock` 锁文件**:`open(容器/.../WeChatMulti/instance.lock)` → `flock(LOCK_EX|LOCK_NB)`。抢到=primary(持锁 fd 到进程退出不放,内核在进程死时自动释放);`EWOULDBLOCK`=已有 primary 活着=secondary。容器目录同 bundleId 所有实例共享、沙盒内可写,活性判定可靠无残留。

---

## 3. 数据/缓存路径隔离 — 评估与做法

**实测结论:同路径多开层面无需额外隔离,共用容器即稳定。**

证据(2 实例跑 75s,scan 两侧日志):
- **MMKV 以 `InterProcess 1`(多进程模式)打开** `…/Data/Documents/app_data/radium/mmkv/*`,这是 MMKV 专为并发多进程设计的文件锁模式,**零** "database is locked" / CRC / 损坏。
- **AppEx(小程序/xweb)子进程按 `--instance-index=N` 区分**(inst1=`0`,第二实例=`2`),mojo channel 各自独立 → 网络栈/渲染子进程天然不互踩。
- 75s 内**无新 crashpad dump、无新崩溃报告**,两实例全程存活。
- `body-gate-memdiff.md` §1 那 13 处 Cronet/Mars 文件函数 hook:**X1a0He 装它们更多是为"关更新 + 把第二实例的网络栈/日志写到不打架的地方"**,但本 build 的 MMKV/AppEx 已自带 InterProcess + instance-index 隔离,**不 hook 也不抢崩**。故引擎**不复刻这 13 处**,以最小改动换稳定。

**局限(如实记录):** 共用容器 = 共用**同一份登录态/聊天 DB**。两实例若登录**同一账号**,会并发写同一 `db_storage` 等 → 行为未定义(同 X1a0He 局限,X1a0He 也不真隔离账号数据)。**真·按实例隔离数据(各自独立账号/容器)只能靠 clone-bundle**:副本改 `CFBundleIdentifier`(如 `com.tencent.xinWeChat.2`)→ 独立沙盒容器 → 数据天然隔开;此时连门②都可不装(LS 视为不同 app,单例不触发)。本引擎门①/门②/注入/重签/探针对 clone-bundle 全套复用。
> **取舍:** 当前方案 A 交付的是"**同一 app、多个窗口/会话并存**"(适合扫码登录不同账号到不同实例的常见用法,各实例 runtime 内存态独立,持久化共容器)。要"每个实例完全独立的数据沙盒"用 clone-bundle(方案 B)。

---

## 4. 引擎 constructor 三步(`WeChatMultiEngine.m`)

```
__attribute__((constructor)) wechat_multi_engine_init:    // -mmacosx-version-min=11.0 否则不跑
  0) is_secondary_instance()  // flock 判据,必须早于门③ swizzle(swizzle 会把判据弄失真)
  1) if secondary: patch_body_early_gate()   // 门②:特征码定位 tbz w20 → NOP(仅第二+实例)
  2) install_gate3_swizzle()  // 门③:swizzle +[NSRunningApplication runningApps…:]→[](辅助)
  3) async write_perms_json() // 权限探针(屏幕录制 + FDA)→ 容器内 perms.json,供 GUI
```
- 注入手段不变(`insert_dylib.py` 给 `wechat.dylib` 每 slice 追加 `LC_LOAD_DYLIB @rpath/WeChatMultiEngine.dylib`;`wechat.dylib` 自带 `@executable_path/../Frameworks` RPATH,`@rpath` 解析到 `Contents/Frameworks/WeChatMultiEngine.dylib`,实测 4 slice 全注入成功、dylib 完整 map 进进程)。
- universal(arm64+x86_64),`minos 11.0` 双 slice 实测就绪(否则 constructor 在低 min 版下不触发)。

---

## 5. 对接 GUI 的接口

**安装(GUI 复用,幂等、自校验、自重签):**
```bash
engine/install-self-engine.sh /path/to/WeChat.app副本
```
做:门① 特征码静态 patch + 门② 引擎注入(门② 的 tbz NOP 是**运行时**做的,安装阶段不动)+ adhoc 重签(保 app-sandbox/app-group entitlements,不 `--deep`)。`exit 0`=成功。安装后 GUI 应 `xattr -dr com.apple.quarantine <app>` 防 AppTranslocation。

**起多开(GUI 现有 `openNewInstance()` 即可,无需改):**
```
NSWorkspace openApplication … createsNewApplicationInstance = YES   // = open -n
```
对装好引擎的副本,`open -n` 起的第二实例靠门② 存活,无需 clone-bundle。

**门①单独定位(GUI 想自己 patch):** `python3 engine/locate_gate1.py /path/to/MacOS/WeChat`(输出 `GATE1_FAT_OFF` 等)。

**门② 无 GUI 接口** —— 它是引擎 constructor 在第二实例进程里运行时自做的,GUI 不参与、不需偏移。

**权限读取(GUI 显示授权):** 读**容器内**路径:
```
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/WeChatMulti/perms.json
# { "screen": bool, "fda": bool, "pid": int, "updated": unixtime }
```
**实例锁文件**(同目录 `instance.lock`)由引擎自管,GUI 无需读写。

---

## 6. 安全 / 结束态

| 检查项 | 期望 | 实测 |
|---|---|---|
| 全程未写 `/Applications/WeChat.app` | 是 | 是(仅只读 `.original`;施工/实测全在 `/tmp/wcv2` 副本;clean DMG `/tmp/WeChat_41121.dmg` 只读挂载) |
| `.original` md5 | `9a7445e8…` | 测后仍 `9a7445e8f0ddefbb69355855fb6b3654`,未变 |
| X1a0He 实例 | 不受扰 | `/Applications` 那份(X1a0He 注入版)全程未启动、未改 |
| 测试进程 | 全退 | `pkill -9 -f /tmp/wcv2` + `pkill lldb`,无残留 |
| 测试证书 | 无 | 全 adhoc `--sign -`,未往钥匙串装任何证书 |
| /tmp 副本 | 调用方清理 | `rm -rf /tmp/wcv2`(测后) |

**工具:** lldb(只读 attach、断 `exit`/`WeChatMain` 取返回值与 backtrace、定位 `tbz w20` 决策点并实测 NOP)、otool/nm/lipo(节布局/符号/slice 偏移)、自写 arm64 微解码(特征码匹配 tbz+bl+mov)、`insert_dylib.py`/`locate_gate1.py`、codesign(adhoc 重签)、vmmap/pgrep/proc_*。

---

## 7. 版本脆弱性

| 项 | 依赖 | 新 build 失效条件 | 降级方案 |
|---|---|---|---|
| 门② 特征码 | `0x2106bc` 函数里 `tbz w20,#0` 后紧跟 `bl;bl;mov w0,#2` | 编译器重排该序列 / 换 `cbz` 形态 / `w20` 换寄存器 | 放宽到"扫所有 `tbz/cbz w20,#0`,回溯目标块是否 `mov w20,#-1`";或 lldb 断 `WeChatMain` 找返回 `-1` 的决策分支 |
| 门② NOP 写入 | 页可经 vm_protect/mprotect 改 RWX | 强 W^X 或 hardened-runtime 拦 | 走 Dobby/substrate 的 code-patch API |
| 第二实例判据 | flock 容器锁 | 容器路径被沙盒进一步收紧 | 退回"mach 命名端口注册/探测" |
| 门① / 注入 / @rpath | 见 `self-engine.md` §7 | 同 | 同 |

**对 build 依赖已最小化:** 门①门② 偏移全运行时现取(`lipo`+特征码 / `_dyld_*`+特征码),零写死。门② 那处 `WeChatMain→b 0x2106bc` 出厂自带,引擎不依赖去算它。
