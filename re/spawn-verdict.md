# 同路径多开 spawn 方式裁定 + X1a0He relauncher 机制

**对象:** WeChat 4.1.11(`com.tencent.xinWeChat`,Team `5A4RE8SF68`),build 与 `/tmp/WeChat_41121.dmg` 一致(loader md5 `8a6d92639b939773a0670eccd49fd835`,dylib `9a7445e8f0ddefbb69355855fb6b3654`)。
**全程未写 `/Applications/WeChat.app`**(X1a0He 用户在用,结束态 codesign valid、插件 md5 `9ea5524d90f6e9abecd2df4040529c42` 一致)。所有施工在 `/tmp` 副本。测后 `/tmp/wc*` 全删、测试进程全退、无测试证书入钥匙串(全 adhoc)。

---

## 0. 一句话结论

> **同路径(同 bundleId、同 `/Applications/WeChat.app`)起 2 个并存实例,靠任何"换 spawn 方式"都做不到——拦路的不是 spawn 原语,而是业务体(`wechat.dylib`)内部一道"早于 NSRunningApplication"的单例门。** 实测:`open -n`、`posix_spawn`/直接 exec loader、`NSWorkspace createsNewApplicationInstance`、把 loader 门①单例函数整体 `mov w0,#0;ret`、再叠加 swizzle `NSWorkspace runningApplications`——**第二个同路径实例统统 `exit(255)` 自退**,且都死在框架加载阶段(ilink2/roam_server/Mars 之间),**根本没走到 `runningApplicationsWithBundleIdentifier:`**(我方 swizzle 已就位但从未被调用)。
>
> **X1a0He 能同路径多开,不是因为它的 spawn 命令特别——它的命令就是裸 `system("open -n /Applications/WeChat.app")`(已逆向确证)。** 真正的关键是:X1a0He 的插件在**两个实例里都被加载**,并在进程内用 `mprotect`+写内存对 `wechat.dylib` 做**运行时 byte-patch**,把那道早期单例门当场打掉。所以同路径多开 = 「裸 `open -n`」+「**进程内运行时 patch 业务体早期单例门**」二者缺一不可。我方引擎做了门①(loader 静态)+ 门③(NSRunningApplication swizzle),**唯独缺这道业务体早期门的中和**,所以同路径第二个起不来。
>
> **当前可交付的"2 实例并存"= clone-bundle**(改副本 `CFBundleIdentifier`)。实测我方引擎 2 个不同 id 实例(`com.tencent.xinWeChat` + `…clone2`)并存 **>32s**,各自引擎完整 map。**这是今天就能让 GUI「开新微信」工作的方案。** 真正的"同一个 .app 路径叠开"需要补一个「运行时业务体 patcher」(见 §5),是后续一道独立工程。

---

## 1. X1a0He relauncher 机制(已逆向确证)

### 1.1 spawn 命令 = 裸 `open -n`
逆向 `/tmp/X1a0HeWeChatPlugin/X1a0HeWeChatPlugin.dylib`(arm64,字符串全加密混淆):
- 多开菜单项的 IMP = `-[NSApplication(WeChatPlugin) runNewWeChat]`(r2:`method.NSApplication_WeChatPlugin_.runNewWeChat`,`0x000a6540`)。
- 反汇编见它两处 `bl sym.imp.system`(`0x000a6790`/`0x000a67ec`),命令串运行时解密。
- **动态求证**:写 harness `dlopen` 插件 + 用 `objc_msgSend` 直调 `[NSApp runNewWeChat]`,interpose `system()` 只捕获不执行 → **捕获到明文:**
  ```
  system("open -n /Applications/WeChat.app")
  ```
  就是裸 `open -n`,无任何 `--args`/env/特殊 flag。

### 1.2 真正的多开靠"进程内运行时 patch",不是 spawn
- X1a0He 插件 `nm -u` 导入:**`_mprotect` + `_mach_vm_protect` + `_method_setImplementation`/`_method_exchangeImplementations` + `_flock`/`_fcntl`/`_open`**。
- `mprotect`/`mach_vm_protect` = 它在进程内改 `wechat.dylib` 的代码页权限后**写内存 byte-patch**(WeChatTweak 同款:把单例判定函数前 8 字节改 `mov w0/w?,#imm; ret`)。
- 多开开关存 `NSUserDefaults` 键 `isMultipleInstanceEnabled`(`+[WeChatPlugin isMultipleInstanceEnabled]` 读它)。开启时插件 init 阶段就地 patch 业务体的早期单例门。
- 插件**无 `+load`、无 `mod_init`**,由被注入的 loader/业务体在启动早期调用其入口安装 hook(标准 WeChatTweak 注入形态:LC_LOAD_DYLIB 进 loader/业务体)。
- **闭环**:开关 ON → 进程内 patch 掉早期门 → `runNewWeChat` 跑 `open -n /Applications/WeChat.app` → 新进程也加载同一插件、也 patch 掉自己的早期门 → **两个同路径实例并存**。

> 注:插件里的 `flock`/`fopen`/`unix-flock` 多来自其内置 SQLite(`sqlite3_*` 符号成片),非单例锁 hook;单例门的中和是 `mprotect` 写内存那条线。

---

## 2. 各 spawn 方式实测(我方引擎,`/tmp` 副本,第一实例在跑)

进程口径:`pgrep -f '<copy>/WeChat.app/Contents/MacOS/WeChat$'`。

| spawn 方式 | 第二个同路径实例 | 证据 |
|---|---|---|
| **CLI `open -n <同路径>`** | ✗ 不并存 | 第二次 `open -n` LaunchServices **不 fork**,把已注册实例提前台(PID 不变);有时表现为"杀掉旧的换新 PID",稳态恒 = 1。 |
| **直接 `posix_spawn`/exec loader** | ✗ 第二个 `exit(255)` | 新进程确实 spawn、引擎 constructor 跑完、门③ swizzle 就位、`perms.json` 写出,但**框架加载阶段(ilink2/roam_server/Mars 间)`exit(255)` 自退**,从没走到 NSRunningApplication 检查。第一个直接 exec 反而能常驻 >12s(推翻早前"直接 exec 必晚期 abort"的判断)。 |
| **门①单例函数整体 `mov w0,#0;ret`**(不只 patch `cbz`) | ✗ 第二个仍 `exit(255)` | loader 门①彻底中和(singleton-check 返回 0)后,业务体仍在框架加载阶段自退 → 杀手在业务体,不在 loader。 |
| **swizzle `+NSRunningApplication runningApplicationsWithBundleIdentifier:` + `-NSWorkspace runningApplications`** | ✗ 第二个仍 `exit(255)` | 两个 ObjC 运行应用 API 都 swizzle 了(日志确认就位),第二个照样早退;**杀手不是任何 NSRunningApplication/NSWorkspace ObjC API**。 |
| **`NSWorkspace.OpenConfiguration.createsNewApplicationInstance=true`** | ✗ 同 `open -n` | 走 LaunchServices,同样受同-bundleId 去重 + 业务体早期门双重拦截。 |
| **clone-bundle(改副本 `CFBundleIdentifier`)** | ✅ **并存 >32s** | 见 §3。不同 id → LS 不去重 + 业务体单例域天然不冲突 + 早期门也不触发(它按 bundle 身份判定)。 |

**杀手定性(lldb 实测):**
- 第二实例 `exit(255)` 来自 `dyld start → main 返回 -1`(loader main 返回业务体入口的 -1),主线程决策。
- 断 `bootstrap_look_up`/`bootstrap_check_in`/`bootstrap_register2`:**第二实例从没按名查/注册任何 `tencent`/`WeChat` mach 服务**就退了 → 早期门**不是** mach bootstrap 命名服务。
- 断 `flock`/`open(O_EXLOCK)` on `lock.ini`:第二实例退前**没碰** `lock.ini` 的 flock/EXLOCK → 不是 `lock.ini` 文件锁。
- 时序:第二实例日志只到 ilink2/roam_server/Mars "implemented in both" 就断(8 行 vs 第一实例 54 行),**死在框架加载早期,远早于 NSRunningApplication UI 检查**。
- ⇒ **早期门是 `wechat.dylib` 内一处 C/C++ 级单例判定**(非 mach 命名服务、非 lock.ini flock、非 NSRunningApplication/NSWorkspace ObjC API),按 bundle 身份判"已有同 app 在跑"→ 让 main 返回 -1。X1a0He 用进程内 `mprotect` byte-patch 把它打掉。

---

## 3. clone-bundle 2 实例并存(铁证,我方引擎)

```
default-id 实例  PID 76770  /tmp/wctest3/WeChat.app  CFBundleIdentifier=com.tencent.xinWeChat
clone-id  实例  PID 76779  /tmp/wcclone/WeChat.app  CFBundleIdentifier=com.tencent.xinWeChat.clone2
t+4s … t+32s   两者持续并存(8 次采样全 2 实例)
vmmap: 两实例各 4 个 WeChatMultiEngine.dylib 段(__TEXT/__DATA_CONST/__DATA/__LINKEDIT)完整 map
```
两实例**同一份二进制**、各带我方引擎、不同 bundleId、**并存 >32s**(超 30s 要求)。`open -n` 对不同 id 各自 fork、各自常驻,互不去重。

> 同账号双开仍受容器内 `lock.ini`(账号级 flock)互斥;clone 各实例共用 `com.tencent.xinWeChat` 容器,**不同账号**直接并存,**同账号**需另做数据目录隔离(另一道工程)。

---

## 4. LaunchServices 那一层(补充)

- `open -n /tmp/wctestX`:实测**确实从该路径起进程**(不会路由到 `/Applications`)。但对**同一 bundleId**,当已有实例在跑时,第二次 `open -n` 受 LS 去重:不再 fork,或重定向到已注册实例 → 稳态 1。
- 同 bundleId 的多处注册(`/Applications` + Sparkle Updater.app + …)由 LS 归一到一个规范实例;`open` 解析 bundleId 时只认这个规范项。
- ⇒ 即便业务体早期门被打掉,**裸 `open -n` 同路径要多开仍需新进程真的 fork**;X1a0He 之所以 `open -n` 能 fork,是因为打掉早期门后业务体不再自退、且 LS 的"new instance"语义对已 patch 的 app 生效(它用 `/Applications` 规范路径)。务实上 GUI 不应依赖 `open -n` 的这层玄学,**直接 `posix_spawn` loader 更可控**(见 §5)。

---

## 5. 给 GUI / 引擎的结论

### 5.1 今天就能用:clone-bundle(推荐落地)
GUI「开新微信」=
1. `ditto /Applications/WeChat.app <副本>`(到用户可写处,如 `~/Library/Application Support/WeChatMulti/Instances/N/WeChat.app`)。
2. 改副本 `Info.plist` 的 `CFBundleIdentifier`(如 `com.tencent.xinWeChat.2`)。
3. `engine/install-self-engine.sh <副本>`(门①+门③+重签全复用)。
4. `xattr -dr com.apple.quarantine <副本>` 防 translocation。
5. `open -n <副本>` 或 `posix_spawn <副本>/Contents/MacOS/WeChat`。
- 各 clone 独立 bundleId → LS 不去重、业务体早期门/门③天然不触发、各自常驻。**实测可并存(§3)。**
- 代价:每副本 ~1.3GB(可只 clone + 符号链接共享 Resources 大文件,后续优化);同账号双开要数据隔离。

### 5.2 真"同一个 .app 路径叠开"需要补:运行时业务体 patcher(= X1a0He 路线)
要满足用户"同一个 `/Applications/WeChat.app` 路径起 2 个"的硬诉求,引擎必须再加一件:**进程内对 `wechat.dylib` 运行时 byte-patch 那道早期单例门**(`mprotect` 改页权限 → 写 `mov w?,#0;ret` → 复原权限),与门③ swizzle 一起在 constructor 里做。
- spawn 用 **`posix_spawn` 直接拉 loader**(比裸 `open -n` 可控,实测能起新进程,只差早期门被打掉就能常驻)。
- **未完成项**:这道早期门在 295MB `wechat.dylib` 里**尚未定位到具体函数**(本轮已排除 mach 命名服务 / lock.ini flock / NSRunningApplication & NSWorkspace ObjC API;确认它是框架加载阶段、按 bundle 身份判定的 C/C++ 级检查)。定位法(留后续):
  1. lldb 断 `dyld start`/loader main 返回点,反向单步定位业务体入口里写 `-1` 的分支;或
  2. 用能稳定加载的 constructor 注入(**关键:tracer dylib 必须带 `-mmacosx-version-min=11.0` 才会生成 `__mod_init_func`、其 constructor 才会被业务体 dyld 跑** —— 不带则落 `__init_offsets`、注入后构造器不执行,本轮踩坑已确认),逐函数二分 hook 找到返回 -1 的判定;或
  3. 取一个 X1a0He patch 生效后的内存快照,diff `wechat.dylib` 原始字节,直接得到 patch 点(最快)。

### 5.3 引擎现状不需改、但安装器加一个 hook 点
- 现引擎(门①静态 + 门③ swizzle)对 **clone-bundle 完全够用**,§3 已证。**GUI 先走 clone-bundle 即可交付。**
- 若要做同路径叠开,后续在 `WeChatMultiEngine.m` 的 constructor 里加 `patch_body_early_gate()`(`mprotect`+写),patch 点由 §5.2 定位后填入(随 build 变,需特征码化)。spawn 改 `posix_spawn` loader。

---

## 6. 安全 / 结束态

| 检查项 | 期望 | 实测 |
|---|---|---|
| 全程未写 `/Applications/WeChat.app` | 是 | 是(仅只读/`md5`/`codesign --verify`/dlopen 插件副本;施工全在 `/tmp/wctest*`、`/tmp/wcclone`、`/tmp/wcx`、`/tmp/wcsame`) |
| `/Applications` codesign | valid | `satisfies its Designated Requirement` ✓ |
| X1a0He 插件 md5 | `9ea5524d90f6e9abecd2df4040529c42` | 一致 ✓ |
| `/tmp/wc*` 副本 | 清空 | 已删(`/tmp/wc*` none) |
| 测试进程 | 全退 | 0 |
| 测试证书 | 无 | 全 adhoc(`--sign -`),钥匙串无 wechat 证书 ✓ |
| 容器内测试残留 | 清 | `Data/tmp/*.log`、`WeChatMulti/perms.json`、`isMultipleInstanceEnabled` 默认值已清 |

**工具:** r2(逆向 `runNewWeChat`/`isMultipleInstanceEnabled`、定位门①单例函数 `0x1000a8160`)、自写 ObjC harness + `system()` interpose(明文求 X1a0He 命令)、lldb(断 `exit`/`bootstrap_*`/`flock`/门①、读单例返回值、backtrace 定位 main 返回 -1)、自写 `mprotect`/`flock`/`open` interpose tracer(注:需 `-mmacosx-version-min` 才生效)、`insert_dylib.py`(注入)、`codesign`(adhoc 重签 + entitlements 回灌)、`lsregister`/`vmmap`/`pgrep`。
