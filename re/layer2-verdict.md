# 微信 4.1.11 「第②层门」性质裁定 + 纯静态单-app 多开可行性

**对象:** WeChat 4.1.11(`com.tencent.xinWeChat`,Team `5A4RE8SF68`)。
**测试底子:** 干净 `WeChatMac.dmg`(`~/Downloads`,490MB,Safari 下载带 quarantine)整 bundle ditto 到 `/tmp/wctest`。
**全程未写 `/Applications/WeChat.app`(X1a0He 注入版,用户在用,pid 25431 全程只 `open`/只读)。测完 `/tmp/wctest` 已删、测试进程已退、自签测试证书已从钥匙串删除。结束态 X1a0He 完好(md5/codesign 全过,见 §7)。**

---

## 0. 一句话结论(直接推翻前序 second-gate.md §4 对"第②层门"的判断)

> **不存在"loader 拒绝加载业务体"这道门。** patch① + adhoc 重签 loader(**连业务体腾讯签名都不动**)后,loader **照常 `dlopen` 了 `Resources/wechat.dylib`**(实测 1787 次 dlopen,业务体 __TEXT 140.5MB 完整 map 进进程,WCDY/ilink2/mmcronet/andromeda 全加载,SkyLight/UI 初始化都跑起来了)。second-gate.md §4 说的"loader 决定不加载业务体、main 干净返回"是**误判**——它把"后期 `exit(-1)`"错当成"早期不 dlopen"。
>
> **第②层的真实身份 = 既不是假设 A(macOS Library Validation),也不是假设 B(腾讯证书白名单/自检),而是「假设 C」:业务体启动时的 `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]` 单例检测命中了已在运行的 X1a0He 实例 → 业务体让 loader `main` 返回 `-1` → dyld `start` 调 `exit(-1)`。** 这其实就是前序 `byte-patch-4.1.11.md` 里的**第③道门**(NSRunningApplication 谓词)。也就是说:**所谓"三层门"实际只有两层**(① loader mach 单例 + ③ 业务体 NSRunningApplication),中间那层"loader 校验业务体"是不存在的幻影。
>
> **另外实测推翻假设 A:** adhoc(无 team)的宿主进程(无论带不带 hardened runtime、带不带 `disable-library-validation`)**都能** `dlopen` 腾讯 DeveloperID+公证+硬化签名的 `wechat.dylib`。Library Validation 在 adhoc 宿主上根本不强制(LV 只在宿主带 `CS_REQUIRE_LV` 时才拦 team 不匹配的库),所以它从来不是拦路的门。
>
> **纯静态单-app 多开:概念上成立(已实测 2 实例并存常驻),但纯 byte-patch 在本 build 上不可靠。** 真正卡住的是第③门 NSRunningApplication 在 4.1.11 被重构成多处消费 + 可能动态派发,byte-patch 3 个明显谓词点**都试了,仍自退**;而**运行时整体 swizzle 这个选择子(返回空数组)→ 第二实例稳定并存常驻(实测 pid 41042 与 X1a0He pid 25431 同时跑,业务体 map 全、RSS 110MB、存活 >50s)**。所以"单-app 多开"要落地,务实解是 **hook/swizzle 选择子(= X1a0He 路线)**,不是纯字节补丁。另有 group-container 副作用一条(见 §5),但**非致命**。

---

## 1. 复现链 & 关键偏移(本 DMG build)

> ⚠️ 偏移**强依赖具体 build**。本次 DMG(`MD5 loader=81f484e030818166727fc2fcb15345a0`, `MD5 dylib=37673e6fbfd138ddb50fd03a6694c256`)与 second-gate.md / byte-patch-4.1.11.md 分析的 build **不同**(loader arm64 fat 起点本 build=`0x2B8000`,文档假设 `0x2DC000`/`0x2B8000` 都出现过;两份文档间也互不一致)。**正确做法:不要硬抄 fat 偏移,用 `lipo -detailed_info` 现取 arm64 slice 起点 + slice 内偏移**。slice 内偏移随 build 也会变,需按下述特征码重新定位。

### 第①门(loader mach 单例 → relaunch+`_exit`)
- 定位法:`otool -tvV` 找 `bl ...symbol stub for: _mach_port_allocate` 所在函数(单例检查,XOR 解混淆固定 service 名,`cset w0,eq` 返回布尔);该函数 callable entry 被调用处即门。本 build:
  - 单例检查函数 entry `0x100093c34`,调用点 `0x1000890dc`(`mov w0,#1; bl 0x100093c34; str w0,[sp,#0x70]; cbz w0, 0x100089244`)。
  - **门指令 VA `0x1000890f0`**,slice 内偏移 **`0x890f0`**,fat 偏移(本 build)**`0x3410f0`**。
  - 原始 `a0 0a 00 34`(`cbz w0, 0x100089244`)→ patched `55 00 00 14`(`b 0x100089244`)。
  - 实测:打掉后 loader 不再走 relaunch+`_exit(0)`,正常走 main、`dlopen` 业务体。✓

### 第③门(业务体 NSRunningApplication 单例谓词)
- 定位法:在 `wechat.dylib` arm64 slice 里搜选择子串 `runningApplicationsWithBundleIdentifier:`(本 build slice 文件偏移 `0x8ab1e23`),其 selref 指针(chained-fixup,本 build 在 slice `0x90a6530`,VA `0x90a6530`),扫所有 `adrp+ldr [x8,#0x530]` 消费点。本 build 共 **3 处**:
  - `0x1d6f44`:`count; cmp w0,#2; cset w20,hs`("≥2 实例就激活旧窗口"UI 路径)。
  - **`0xec92e8`**:`count; cmp x0,#0; cset w21,ne`(最干净的布尔谓词;门指令 `0xec9314`=`f5 07 9f 1a` `cset w21,ne`,fat `0xad65314`,patch→`15 00 80 52` `mov w21,#0`)。**这正是 byte-patch-4.1.11.md 给的同型点(它那 build 在 `0xec5ee8`)。**
  - `0x45068f0`:`count` 流入 w20 的复杂 getter(返回 w20,对应文档 `0x44e1fb4` 变体)。
- ⚠️ **实测:3 个点都 byte-patch(`mov w21/w20,#0` 强制"0 实例")仍不足以消门——第二实例照样 `exit(-1)`。** 见 §3、§4。

---

## 2. 实证:第②层不是 A 也不是 B(反汇编 + 日志 + 隔离实验)

### 2.1 隔离实验否定假设 A(Library Validation)
自写 `dltest`(`dlopen(RTLD_NOW)` 一个 dylib)在多种签名配置下加载**腾讯 DeveloperID+公证+硬化**的 `wechat.dylib`:

| 宿主签名 | 加载腾讯签 dylib | 结论 |
|---|---|---|
| adhoc,无 hardened runtime(= X1a0He loader 形态) | **通过**(过签名检查,卡在缺 @rpath 依赖而非 LV) | LV 不拦 |
| adhoc + hardened runtime | **通过** | LV 不拦 |
| adhoc + hardened runtime + `disable-library-validation` | **通过** | — |

> 机理:Library Validation 只在宿主进程带 `CS_REQUIRE_LV`(硬化运行时**且**未 `disable-library-validation`,**或**平台/MAS 二进制)时才强制"被加载库 team==宿主 team"。**adhoc 宿主 team=空,不进入 LV 强制路径**,所以能加载任意有效签名(含腾讯签)的库。→ **假设 A 证伪:LV 从来不是第②层门。** (注:首次对一个从未见过的路径 dlopen 偶发一次 `library load disallowed by system policy`,是 amfid 首触发的瞬态,系统登记后即消失,非稳定门。)

### 2.2 真实 launch 否定"loader 不加载业务体"
patch① + adhoc 重签 loader(**保留业务体腾讯签名**)+ loader 带 `disable-library-validation`/`allow-dyld-environment-variables` ent + 注入 dlopen/exit tracer,`open -n` 实测:
```
[dlopen] wechat.dylib (mode=2) -> OK            ← 业务体被成功 dlopen
[dlopen] .../Resources/wechat.dylib -> OK
... 1787 次 dlopen,ilink2/roam_server/WCDY/andromeda/mmcronet 全 OK ...
[dlopen] ImageIO / CFNetwork / AVFAudio / CoreGraphics ...   ← 已进 UI/图形初始化
[_exit] code=-1                                  ← 业务体跑了一大段后才退
exit backtrace: dyld`start → LibSystemHelpersWrapper::exit → main 返回 -1
```
→ **业务体 100% 被加载并初始化了**,"第②层 = loader 拒载业务体"**不成立**。`exit(-1)` 来自 dyld `start`(= loader `main` 返回 -1),是**后期**业务逻辑判定失败,不是早期不 dlopen。

### 2.3 定位真凶 = NSRunningApplication(第③门)
把 tracer 换成 ObjC swizzle:`+[NSRunningApplication runningApplicationsWithBundleIdentifier:]` 强制返回 `@[]`(空)。其余完全不变(patch①+adhoc+保留业务体腾讯签):
```
[hook] swizzled NSRunningApplication runningApplicationsWithBundleIdentifier:
[hook] runningApplicationsWithBundleIdentifier:com.tencent.xinWeChat -> [] (forced empty)
（无 [exit]）→ 进程存活
```
**实测:第二实例 pid 41042 与 X1a0He pid 25431 同时常驻**,业务体 `Resources/wechat.dylib` __TEXT 140.5MB 完整 map,RSS 110MB,存活 >50s。→ **致命点就是这个选择子的单例检测命中了 X1a0He 已在运行的实例。** 干净未 patch 的业务体跑第二实例时,它查到"已有 com.tencent.xinWeChat 在跑"→ 让 main 返回 -1 自退。这就是第②层"自退"的真相 = **第③门**。

---

## 3. 纯静态单-app 多开:实测裁定

| 配置(都在 /tmp 副本,X1a0He 在跑做"已有实例") | 业务体是否加载 | 第二实例结局 |
|---|---|---|
| patch① + adhoc 重签 loader,**业务体不动(腾讯签)** | **加载** | `exit(-1)` 自退(第③门命中) |
| ↑ + 业务体 byte-patch 第③门 3 个谓词点(`mov w21/w20,#0` / count 强制 0)+ 全 adhoc 重签 | **加载** | **仍 `exit(-1)` 自退** ✗ |
| patch① + **运行时 swizzle `runningApplicationsWithBundleIdentifier:`→空** + adhoc | **加载** | **存活常驻,2 实例并存** ✓ |

**裁定:**
- **概念上单-app 多开成立**(swizzle 版实测 2 实例并存常驻是铁证)——门只有 ①(loader,已能静态 patch)和 ③(业务体 NSRunningApplication),无中间"loader 校验业务体"那层。
- **但纯 byte-patch 在本 4.1.11 build 上不可靠**:第③门被重构成**多处消费 + 极可能存在动态派发的调用点**(selector 经 `sel_registerName`/`NSSelectorFromString` 或不在 `__objc_selrefs` 静态 xref 覆盖的调用路径),所以静态打掉那 3 个明显谓词点**不够**,第二实例照样自退。而**整体 swizzle 这个选择子能 100% 拦住所有派发路径**,故有效。
- **务实落地解 = hook/swizzle `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]`(返回空数组)**,即 **X1a0He 路线**(它正是 swizzle/inline-hook 这个系统选择子)。loader 的第①门可继续用纯静态 byte-patch(`cbz`→`b`),业务体的第③门改用注入式 hook 选择子。**纯静态(只字节补丁、零注入)做单-app 多开 = 本 build 实测不通**,卡在第③门的静态覆盖不全。

> 若坚持零注入:**clone bundle(改 `CFBundleIdentifier` + app-group)**仍是最稳路线——不同 bundle id,NSRunningApplication 查不到"同 id 已在跑",第③门天然不触发(且各自独立 mach 单例域、独立 group container,§5 副作用也一并消失)。这是性价比最高的落地路线,只是它不是"同一个 app bundle 叠开",而是"克隆出第二个 app"。

---

## 4. 为什么 byte-patch 第③门失败、swizzle 成功(诚实分析)

- 3 个静态 selref 消费点(`0x1d6f44`/`0xec92e8`/`0x45068f0`)都 patch 后第二实例仍 `exit(-1)`,说明**启动时实际生效的单例判定不在这 3 个静态点上**,或同一逻辑还有 C++/动态派发的并行入口(4.1.11 业务体大量 Qt/C++ 重写 + 选择子可能运行时拼)。
- swizzle 是**方法实现级**替换:无论调用方怎么拿到/派发该选择子,最终 `objc_msgSend` 都落到被换的 IMP → 全覆盖。这解释了"swizzle 通、静态点不通"。
- 结论:**对 4.1.11,NSRunningApplication 单例门的可靠中和手段是选择子级 hook,不是逐点 byte-patch**。要纯静态搞定,需进一步动态(lldb 断 `objc_msgSend` 过滤 `runningApplicationsWithBundleIdentifier:`,回溯真正的启动判定调用栈)定位那个**唯一致命的调用点**再 patch——本次未做到该粒度,故对"纯静态"给否定结论。

---

## 5. group container / 弹窗副作用

- adhoc 重签抹掉 team `5A4RE8SF68` → containermanagerd 对 app-group `5A4RE8SF68.com.tencent.xinWeChat` 报:
  ```
  REJECTED. Requestor's signature does not allow it to access a TCC-protected group container.
  Group containers identifiers should be prefixed by requestor's team ID...
  test = team ID prefix ... error
  ```
  实测**自签证书也无解**(自签无 Apple 颁发的 team id,strict scrutiny 仍 REJECTED);只有腾讯私钥签的二进制能访问该 group container。
- **但该 REJECT 非致命**:swizzle 版第二实例在 group-container 被 REJECT 的情况下**照样常驻**(REJECT 只挡 TCC-strict 的那次 group 访问,业务继续跑;networkd/SkyLight/UI 都正常起)。所以 group-container 不是多开的拦路门,只是个噪声 + 可能让"App 间共享数据(小程序/文件中转)"功能受限。
- **app-sandbox entitlement 必须保留**:实测去掉 `app-sandbox` 后 loader 早期(dlopen 业务体之前)就 `main` 返回 -1 自退——loader 要求自己处于沙盒态。所以重签 entitlements 要保 `app-sandbox` + app-group(即使 group 会被 REJECT)+ 原有 `allow-jit` 等,**不能 `--deep` 乱签**。
- 未观测到"访问其他 App 数据"用户弹窗;未观测到任何腾讯应用层自检 log(无 SecCodeCheckValidity 拒绝、无完整性自爆)。adhoc 重签业务体 + loader 在 4.1.11 上不触发应用层签名自检(印证 byte-patch-4.1.11.md §2 的判断)。

---

## 6. 三层门修正后的全景

| 门 | 位置 | 机制 | 静态可 patch? | 本 build 偏移(用 lipo 现取 arm64 起点 + 下列 slice 偏移) |
|---|---|---|---|---|
| ① | `Contents/MacOS/WeChat` loader | mach bootstrap 单例 → relaunch+`_exit` | **是** | slice `0x890f0`(`cbz w0`→`b`,`a00a0034`→`55000014`) |
| ~~②~~ | ~~loader 校验业务体~~ | **不存在**(loader 正常 dlopen 业务体;LV 对 adhoc 宿主不强制) | — | — |
| ③ | `Contents/Resources/wechat.dylib` 业务体 | `NSRunningApplication runningApplicationsWithBundleIdentifier:` 单例 | **理论是,实测纯字节补丁覆盖不全**;**选择子 hook 才稳** | 谓词点 slice `0xec9314`(`cset w21,ne`→`mov w21,#0`)等 3 处,**不足以消门** |

**给引擎的直接启示:**
1. "纯静态单-app 多开"在 4.1.11 上 = **半成立**:第①门可纯静态 byte-patch;第②门是伪命题(不存在);**第③门是真正的 hard 部分,纯字节补丁本 build 实测打不穿,必须用选择子级 hook(X1a0He 路线)**。
2. 想要"零注入"稳定多开,选 **clone bundle**(改 id+group,三门全不触发,group-container 副作用也消失)。
3. Library Validation / 腾讯证书自检都**不是**门 —— 不必为它们加 `disable-library-validation` 或找腾讯私钥;adhoc 重签足矣。

---

## 7. 安全 / 结束态(硬要求达成)

| 检查项 | 期望 | 实测 |
|---|---|---|
| 全程未写 `/Applications/WeChat.app` | 是 | **是**(仅 `open`/只读;所有 patch/签名/launch 在 `/tmp/wctest` DMG 副本) |
| `/Applications/.../MacOS/WeChat` md5 | `196f76de1fea387f055967301fda90d2` | **一致** ✓ |
| `/Applications/.../Resources/wechat.dylib` md5 | `52bb2c9e4c0cb755ab9a82db52e6b8b8` | **一致** ✓ |
| `wechat.dylib.original` md5 | `9a7445e8f0ddefbb69355855fb6b3654` | **一致** ✓ |
| `codesign --verify /Applications/WeChat.app` | 通过 | **PASS** ✓ |
| 测试进程清理 | 全退 | **0**(`/tmp/wctest` 已删、DMG 已卸载、tracer 日志已清、自签测试证书已从钥匙串删除) |
| X1a0He 实例 | 1 个干净 | **1**(pid 25431 全程未受扰) ✓ |

**工具:** `radare2`/`otool`/`lipo`(反汇编、slice 定位)、自写 arm64 微解码器(谓词点定位)、自写 `insert_dylib.py`(LC_LOAD_DYLIB 注 tracer)、`clang`(dltest/tracer/swizzle)、`codesign`(adhoc/自签重签 + 提取 entitlements)、`log stream`/`log show`(amfid/sandboxd/containermanagerd 抓证)、`vmmap`/`ps`/`pgrep`(实例与镜像核验)。
