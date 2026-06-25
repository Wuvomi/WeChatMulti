# 静态 byte-patch 在微信 4.1.11 上的可行性 — 核查判定

**核查对象版本:** WeChat **4.1.11**(`/Applications/WeChat.app`,`CFBundleShortVersionString=4.1.11`,Team `5A4RE8SF68`,Identifier `com.tencent.xinWeChat`)。全程只读分析,未改动任何微信文件;所有分析在 `lipo -thin arm64` 出来的临时副本上做。

---

## 0. 一句话判定

> **"WCDY.framework 在磁盘上是密文 → 静态 byte-patch 架构性死亡" 的说法是错的(基于错误的前提)。多开判定函数所在的二进制在磁盘上是明文、可反汇编、无任何 LC_ENCRYPTION,纯静态 byte-patch 完全可行。豆包方向更接近事实(偏移变了/转成 C++),但它说的"WCDY 加密"也没必要——根本没加密。**

你的"结构性死亡"结论 = **夸大且前提失实**。真正的业务代码不在你以为的 WCDY 里,而在另一个文件 `Contents/Resources/wechat.dylib`,而那个文件是**明文 Mach-O**。

判定:**静态 byte-patch 在 4.1.11 上「可行」**(只是要找对二进制、找对偏移)。

---

## 1. 关键事实纠正:你把"哪个是 loader、哪个是 body"搞反了,而且 body 不是 WCDY

| 文件 | 大小(fat) | arm64 thin | 角色 | 磁盘加密? |
|---|---|---|---|---|
| `Contents/MacOS/WeChat` | 5.6 MB | 2.6 MB | **明文 loader**(含 `xwechat_load`/`xWeChatLdrIV2024`/`is_wcdy_supported`/`bad decrypt`/`_dlopen`) | 否 |
| `Contents/Frameworks/WCDY.framework/.../WCDY` | 1.69 MB | 0.83 MB | **不是 body**;是个小的 "stub class / WCVM" 类加载器(`PROJECT:WCVM-1`,`ERROR: stub class not supported`) | 否 |
| `Contents/Resources/wechat.dylib` | **320 MB** | **155 MB** | **真正的微信本体**(install name `@rpath/wechat.dylib`,current version `4.27.21`,内含全部业务代码) | **否** |

证据:
```
$ strings MacOS/WeChat | grep -E 'xwechat_load|xWeChatLdrIV2024|is_wcdy_supported|bad decrypt'
WCDYCrshInfoKey!xWeChatLdrIV2024
is_wcdy_supporteloader_completedlibrary_version
bad decrypt
xwechat_load
# → 这些"loader/解密"字样在【主程序 MacOS/WeChat】里,不在 WCDY 里。
#   说明 5MB 主程序本身就是 loader。

$ otool -L MacOS/WeChat | grep WCDY
  @rpath/WCDY.framework/Versions/A/WCDY (compat 1.0.0)

$ otool -D Resources/wechat.dylib
  @rpath/wechat.dylib
$ otool -L Resources/wechat.dylib | head
  @rpath/wechat.dylib (compatibility version 4.1.11, current version 4.27.21)
  /usr/lib/libbsm.0.dylib ...
  /System/Library/Frameworks/Cocoa.framework/... (正常系统框架)
# → 一个普通的、链接系统框架的、可被 dlopen 的 dylib。

$ nm -u MacOS/WeChat | grep dlopen
  _dlopen
$ strings MacOS/WeChat | grep dylib
  %s.dylib / wechat.dylib / dlopen_duration...
# → loader 走标准 _dlopen 把 Resources/wechat.dylib 加载进来,带 dlopen_duration 这种纯耗时遥测,
#   不是"解密到内存再 NSCreateObjectFileImageFromMemory"那种隐藏加载。
```

> 你的题面里"WCDY ~141MB / 业务代码在 WCDY / loader 含 OpenSSL 解密"——141MB 这个数字其实对应的是 `Resources/wechat.dylib` 的 arm64 slice(155MB),不是 WCDY(0.83MB)。情报源把 body 的体积安到了 WCDY 这个名字上,这是整个误判的起点。

---

## 2. 关键问题 1:body 在磁盘上是不是加密的?——**不是,铁证如下**

对 `Resources/wechat.dylib` 的 arm64 thin slice(155 MB):

**(a) 没有 LC_ENCRYPTION_INFO(没有 Apple 风格段加密)**
```
$ otool -l Resources/wechat.dylib | grep -i cryptid
(空)            # 三个文件全部为空:WeChat / WCDY / wechat.dylib 都没有 cryptid
```

**(b) 是合法 Mach-O,头部能正常解析**
```
$ file Resources/wechat.dylib
  Mach-O universal binary ... [arm64: Mach-O 64-bit dynamically linked shared library]
$ otool -h           # 正常 mach header,ncmds=98,合法 filetype
```

**(c) 熵 = 明文级别,不是密文**
- 全 155MB 按 4MB 分块,熵稳定在 **6.5 – 6.95**。
- 加密/压缩数据应当是 **~7.99 平直**。6.5 是 ARM64 原生代码的典型熵。
```
chunk 0 6.511 / chunk 5 6.539 / chunk 10 6.817 / chunk 20 6.943 ...   (无一接近 8.0)
```

**(d) __text 直接反汇编出正常指令**(不是垃圾):
```
$ r2 ... 's section..__TEXT.__text; pd'
0x00016000  stp x20, x19, [sp, -0x20]!
0x00016004  stp x29, x30, [sp, 0x10]
0x00016008  add x29, sp, 0x10
0x0001600c  mov x19, x0
0x00016010  adrp x8, 0x8760000 ...
# 标准函数序言,完美的 arm64。
```

**(e) 还原出真实业务符号/字符串**:`lock.ini`、`IsRunning`、`InitMMKVInstance`、`AsyncSingletonInvoke`、SQLite 关键字表、Qt 字符串(`QCoreApplication::exec`)等。Qt/C++ 重写属实(`__objc_methname` 仅 0xbb53,比 3.x 单体小很多),但 ObjC 段仍在。

> **结论 1:body(`Resources/wechat.dylib`)在磁盘上是明文 Mach-O,不是密文。** 顺带:WCDY 本体同样是明文(__text 反出 `cbz x1; ldr x8,[x1]; br x2; ret` 等正常指令)。"磁盘上是密文"这一条对 4.1.11 的任何一个相关二进制都不成立。

`xWeChatLdrIV2024` / `bad decrypt` 这些串确实存在于 loader,说明 loader **具备**解密能力——但那是给**热更新下载包**(`loaderFolderMirrorInBundle/InDownload`、`is_wcdy_supported`、`loader_completed`)用的校验/解密路径;**随包出厂的 `Resources/wechat.dylib` 本身没有被加密**(上面 a–e 五条)。具备解密代码 ≠ 这个文件是密文。

---

## 3. 关键问题 2:多开/单例判定函数在哪?——**在明文 body 里,且已定位到偏移**

单实例机制 = 经典的 **flock(`lock.ini`)**。`_flock`/`_fcntl` 被 `Resources/wechat.dylib` import;`lock.ini` 字符串在该 dylib 内(VA `0x7a455f7`)。

用自写的 adrp+add Mach-O 扫描器(精确解析段映射)找到对 `lock.ini` 的全部代码交叉引用:
```
adrp+add xrefs to "lock.ini": 0x4339150, 0x433d45c, 0x433d95c   (均在 __text 内)
```
反汇编 `0x4339150` / `0x433d45c` 处:构造 `…/lock.ini` 路径 → 取锁 → **`cbz w0, …` 按"锁是否被占用"分支**:
```
0x04339150  adrp x1, 0x7a45000      ; = "lock.ini"
0x04339154  add  x1, x1, 0x5f7
...                                  ; 拼路径 + 取锁
0x043391a0  bl   func.0002af08      ; 锁/单例检查
0x043391a4  cbz  w0, 0x4339208      ; ← 决策分支(可翻转点)
...
0x0433d4bc  cbz  w0, 0x433d4d4      ; ← 第二处同构决策
0x0433d4d0  cbz  w0, 0x433d6ac
```
这些 `cbz w0` 就是"已有实例 → 走拒绝/激活旧窗口 / 否则继续启动"的网关,正是 byte-patch 要动的地方(把分支永远走"允许新实例"方向,或把单例检查函数 stub 成返回 0/1)。

> **结论 2:多开判定函数在 *明文* 的 `Resources/wechat.dylib` 里**(不在 loader,也不在你以为的 WCDY)。
> 由于它是磁盘明文,**纯静态 byte-patch 这个函数完全成立** —— 这直接否定了"改的是密文"的说法。
> (前序 `268831-finding.md` 把"业务代码在 WCDY"的方向给错了:它正确指出 268831/官方 .bin 是壳,但没意识到真 body 是 `Resources/wechat.dylib`。本次独立验证予以修正。)

---

## 4. 关键问题 4:有没有 `__TEXT,__lockdown` 或完整性校验?

- **段级:无 `__lockdown`、无 integrity/guard/sign 命名段**(三文件 `otool -l | grep -iE 'lockdown|integr|guard'` 全空)。
- **Apple 加密:无 LC_ENCRYPTION_INFO**(见 §2a)。
- **代码签名:** 整个 .app 是 Tencent 签名(`flags=0x10000 runtime` 硬化运行时,`Sealed Resources rules=13 files=206`)。这意味着:
  - 一旦你改 `Resources/wechat.dylib` 的任意字节,**该文件的 cdhash 与 bundle 封签都会失配** → 系统会拒绝加载/启动(amfi)。
  - 但这**不是微信自己的"完整性自校验",而是 macOS 代码签名机制**。绕过方式是标准的:patch 完字节后 **`codesign --force --sign - --deep`(ad-hoc 重签)** 或用你自己的证书重签整个 bundle。重签后即可运行。
  - 因此"有完整性校验"在**应用层**没看到证据,但在**OS 代码签名层**客观存在 → 任何静态 patch 都必须配套重签。这点豆包的"可能有完整性校验"算半对(机制猜错了,但"改完不能直接跑"这个结论对)。

---

## 5. 豆包三条路线逐条评分

记号:可行性 0–10(10=最稳)。

### ① 纯机器码 byte-patch(改 `Resources/wechat.dylib` 的 `cbz`/单例函数) — **8/10,可行**
- 目标文件磁盘明文、可反汇编、偏移已定位(`0x43391a4` 等 `cbz w0`)。技术上就是把分支/函数 stub 掉,和 3.x 的 `mov w0,#1; ret` 同性质。
- 扣分项:(a) 改完**必须 ad-hoc 重签**整个 bundle(硬化运行时 + 封签),否则不启动;(b) 偏移每版变,需重新定位;(c) Qt/C++ 化后是普通函数而非 ObjC 选择子,定位靠 `lock.ini` xref 而非 method name(本报告已给方法)。
- 结论:**豆包对,你错**。这不是"架构性死亡",是"换文件 + 换偏移 + 重签"的常规活。

### ② insert_dylib 注入(改 loader 的 LC_LOAD_DYLIB + 运行时 hook) — **7/10,可行但有签名摩擦**
- 往 `MacOS/WeChat`(或更靠近的 `Resources/wechat.dylib`)插一条 `LC_LOAD_DYLIB` 指向你的 hook dylib,运行时 hook 单例函数/`flock`。`insert_dylib` 没装但不必依赖它——可手工加 load command 或用 `optool`/python 脚本。
- 扣分项:同样要重签;硬化运行时下注入第三方 dylib 需要 **library validation 不开**或自签。查 entitlements:存在 `com.apple.security.cs.allow-jit`,**未见 disable-library-validation**——所以注入未签名 dylib 时,要么对整 bundle 用你自己的证书重签让 cdhash 自洽,要么 ad-hoc 全签。能做,但比纯 patch 多一步。
- 结论:可行,豆包对。

### ③ patch "完整性校验" — **N/A → 2/10(不适用 / 没必要)**
- 没找到**应用层**自校验段/逻辑可供 patch(§4)。真正挡路的是 **OS 代码签名**,那不是"patch 一个 if"能绕的,正解是**重签**(`codesign --force --deep`),不是改字节。
- 所以这条路线**前提基本不成立**;若指的是"绕过签名",那答案是重签而非 patch。

> 补充更稳的非 patch 路线(社区在 4.x 常用):**App 克隆**——`ditto` 复制 WeChat.app → 改 `CFBundleIdentifier` → `codesign --force --deep` 重签 → 多个 bundle 各自持有独立 `lock.ini`,天然多开,完全绕过 in-binary 判定。稳定性 **9/10**。

---

## 6. 终判

| 命题 | 裁定 |
|---|---|
| "WCDY.framework 磁盘上是密文" | **假**(WCDY 是明文小 stub;且真 body 也是明文) |
| "业务/多开判定代码在 WCDY 里" | **假**(在 `Contents/Resources/wechat.dylib`) |
| "因为是密文 → 静态 byte-patch 架构性死亡" | **假 / 夸大**(前提失实;目标明文可 patch) |
| 豆包"偏移变了 / 转成 C++ / 可能有完整性校验" | **大体对**(C++/Qt 确实;偏移确实变;"完整性校验"实为 OS 签名,改完需重签) |
| **静态 byte-patch 在 4.1.11 上是否可行** | **可行**(评分 8/10,需配套 ad-hoc 重签) |

**你需要纠正的认知:** 不是"加密让 patch 死了",而是"你之前在错的二进制(268831 壳 / WCDY)里找函数,真函数在明文的 `Resources/wechat.dylib`"。换对文件,patch 路立刻活。

---

## 附:复现命令与产物

- thin 副本(只读,原文件未动):
  - body: `…/scratchpad/slices/biz_wechat_arm64.macho`(155MB,来自 `Resources/wechat.dylib`)
  - loader: `…/scratchpad/slices/WeChat_arm64.macho`
  - WCDY: `…/scratchpad/slices/WCDY_arm64.macho`
- 关键命令:`otool -l|-L|-D`、`lipo -thin/-info`、`file`、`nm -u`、`strings -a`、`codesign -dv/-d --entitlements`、Python 熵统计、自写 adrp+add xref 扫描器(精确解析 LC_SEGMENT_64 映射,定位 `lock.ini` 三处 xref `0x4339150/0x433d45c/0x433d95c`)。
- 多开决策分支 VA(arm64,`Resources/wechat.dylib`):`0x43391a4`、`0x433d4bc`、`0x433d4d0`(`cbz w0`),围绕 `lock.ini`(VA `0x7a455f7`)的 flock 单例逻辑。
