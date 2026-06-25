# 业务体早期门 内存 diff 裁定 — X1a0He 在 `wechat.dylib` 里到底改了哪些字节

**方法:** 内存 diff。把 X1a0He 插件已加载、多开已开启(`isMultipleInstanceEnabled=1` / `X1a0HeWeChatPlugin_MultipleInstance=1`)的运行实例的 `wechat.dylib __TEXT` 与**原始磁盘字节**(`/Applications/WeChat.app/Contents/Resources/wechat.dylib.original`,arm64 slice)按相同 vmaddr 对齐 diff。
**安全:** 全程未写 `/Applications/WeChat.app`(仅只读取插件 + `.original`)。施工全在 `/tmp/wcmem`、`/tmp/wcnoplug`(从 `/tmp/WeChat_41121.dmg` ditto 出的副本,dylib md5 `9a7445e8...` == `.original`)。测后清理见 §6。
**对象:** WeChat 4.1.11,`wechat.dylib` arm64 slice(fat 内偏移 **165642240 = 0x9DEC000**),`__TEXT` vmaddr 0,`__text` 节 vmaddr `0x16000`..`0x63ebf54`。X1a0He 插件 md5 `9ea5524d90f6e9abecd2df4040529c42`(= `/Applications/.../Frameworks/X1a0HeWeChatPlugin.dylib`)。

---

## 0. 一句话结论(修正前序假设)

> **X1a0He 不是 WeChatTweak 式的「`mov w0,#0;ret` 单例函数补丁」,也不 swizzle `NSRunningApplication`/`NSWorkspace`。** 它在 `wechat.dylib __text` 里装的是 **Dobby 内联 hook**(`adrp x17,<plugin>; add x17; br x17` 跳板覆盖函数序言)。
>
> 稳态(运行中)能 diff 到 **19 处** Dobby hook,性质三类:**① 关自动更新(5 处 `XAppUpdateManager` 方法)、② Qt dock 菜单注入(1 处 `QCocoaApplicationDelegate dockMenu`)、③ Cronet/Mars 网络栈文件函数(13 处,数据/日志路径隔离)**。
>
> **真正的「早期单例门中和」是第 20 处 hook:把 `WeChatMain`(vmaddr `0x16380`)的第一条指令改成 `b func.002106bc`,让进程跳过 `WeChatMain` 正常的 init 链(其中含单例-`exit` 判定)。这处 hook 只在「第 2 个及以后实例」里安装**——所以**只在第二实例的内存快照里能 diff 到,第一实例里 `WeChatMain` 是原样的**(这正是它早前没被定位到的原因:大家都在看第一实例)。
>
> **实证闭环:** 同副本、gate① 已 patch、直接 exec 起第二个同路径实例 —— **无插件 → `exit(255)`**(§4 铁证);**有插件 → 第二实例存活、两实例并存 >10s**(§3)。

---

## 1. 19 处稳态 Dobby hook(第一/第二实例都有)

全部形如 `adrp x17,<plugin页>; add x17,x17,#imm; br x17`(12 字节,覆盖原函数序言前 3 条指令),`br x17` 跳进 `X1a0HeWeChatPlugin.dylib`(lldb 实测 13 个 C++ hook target 全部 resolve 到插件镜像内)。

| # | slice/vmaddr | fat fileoff(`.original`) | 原序言前 12B | 命中函数 / 性质 |
|---|---|---|---|---|
| 1 | 0x1d393c | 0x9fcb93c | `fc6fbba9 f85f01a9 f65702a9` | `-[XAppUpdateManager startUpdater]` — 关更新 |
| 2 | 0x1d5a74 | 0x9fcda74 | `ffc305d1 fc6f14a9 f44f15a9` | `-[XAppUpdateManager checkForUpdates:]` — 关更新 |
| 3 | 0x1d5d38 | 0x9fcdd38 | `ff4301d1 f44f03a9 fd7b04a9` | `-[XAppUpdateManager startBackgroundUpdatesCheck:]` — 关更新 |
| 4 | 0x1db9b4 | 0x9fd39b4 | `fa67bba9 f85f01a9 f65702a9` | `-[XAppUpdateManager quitAndInstallIfNeeded:]` — 关更新 |
| 5 | 0x1df298 | 0x9fd7298 | `ff4302d1 fc6f03a9 fa6704a9` | `-[XAppUpdateManager doReport:errorCode:domain:extInfo:]` — 关更新上报 |
| 6 | 0x1fcb18 | 0x9ff4b18 | `fc6fbaa9 fa6701a9 f85f02a9` | C++ `func.001fcb18`(Cronet 区,拦截) |
| 7 | 0x2851b58 | 0xc649b58 | `fc6fbaa9 fa6701a9 f85f02a9` | C++ `func.02851b58`(Cronet,7740B init) |
| 8 | 0x2857b88 | 0xc64fb88 | `f85fbca9 f65701a9 f44f02a9` | C++ `func.02857b88`(Cronet) |
| 9 | 0x286bcd4 | 0xc663cd4 | `ff8301d1 f44f04a9 fd7b05a9` | C++ `func.0286bcd4`(Cronet) |
| 10 | 0x286ece8 | 0xc666ce8 | `fa67bba9 f85f01a9 f65702a9` | C++ `func.0286ece8`(Cronet) |
| 11 | 0x2888da0 | 0xc680da0 | `f657bda9 f44f01a9 fd7b02a9` | C++ `func.02888da0`(Cronet) |
| 12 | 0x2897d48 | 0xc68fd48 | `f85fbca9 f65701a9 f44f02a9` | C++ `func.02897d48`(`CronetFileTaskRunner`,路径/日志隔离) |
| 13 | 0x2bb6a00 | 0xc9aea00 | `ff8301d1 f65703a9 f44f04a9` | C++ `func.02bb6a00`(Cronet) |
| 14 | 0x2c1dcd8 | 0xca15cd8 | `f85fbca9 f65701a9 f44f02a9` | C++ `func.02c1dcd8`(Cronet) |
| 15 | 0x433d3ec | 0xe1353ec | `ffc305d1 f44f15a9 fd7b16a9` | C++ `func.0433d3ec`(Cronet) |
| 16 | 0x4c3810c | 0xea3010c | `ff8300d1 fd7b01a9 fd430091` | C++ `func.04c3810c`(`CCKeyDerivationPBKDF`,crypto/keychain) |
| 17 | 0x506efd0 | 0xee66fd0 | `e923b96d fc6f01a9 fa6702a9` | C++ `func.0506efd0`(`CronetFileTaskRunner`,路径/日志隔离) |
| 18 | 0x507895c | 0xee7095c | `fc6fbaa9 fa6701a9 f85f02a9` | C++ `func.0507895c`(Mars/Cronet `pwrite`,路径/日志隔离) |
| 19 | 0x635dc08 | 0x10155c08 | `000c40f9 c0035fd6 03038052` | `-[QCocoaApplicationDelegate dockMenu]`(Qt 菜单注入) |

> 这 19 处**都不是单例门**。①②是更新/菜单;③(6–18)整片在 Cronet(Chromium 网络栈,静态链接进业务体)+ Mars,X1a0He hook 它们是为**两实例不抢同一网络栈/日志/缓存文件**(多开数据隔离),不是判"已有实例在跑"。
> 实测排除:`+[NSRunningApplication runningApplicationsWithBundleIdentifier:]` 与 `-[NSWorkspace runningApplications]` 在已 patch 实例里 **IMP 仍指向 AppKit**(未被 swizzle);插件 ObjC 分类只有 `NSApplication(WeChatPlugin) runNewWeChat`(加菜单项,非门)。**所以 layer2-verdict 假设的「X1a0He swizzle NSRunningApplication」与真实 X1a0He 不符**(我方引擎现在走的就是那条,见 §5)。

---

## 2. 第 20 处 hook = 早期单例门中和(**仅第二实例有**)

**只有在第 2 个及以后的同路径实例里**,插件会额外把 `WeChatMain` 的入口改掉:

```
函数      WeChatMain
vmaddr    0x16380
fat off   0x9e0e380   (在 .original 里)
原始(磁盘)  fd 7b bf a9          ; stp x29, x30, [sp, #-0x10]!   (正常序言)
patched   d0 e8 07 14          ; b   0x2106bc  (= func.002106bc, 位移 +0x1fa340)
```

- `WeChatMain`(0x16380,仅 52 字节)是个调度壳:依次 `bl` 5 个 init(`func.05c760b0 / 05c76bdc / 05c7ab28 / 05c781a8 / 0632d7a4`),每个后跟 `func.06273ecc`。**这条 init 链里就埋着"已有同 app 实例→自退"的单例判定。**
- patched 后第二实例**从 `WeChatMain` 第一条就 `b` 进 `func.002106bc`**(业务体内另一处真实函数,lldb 实测 target 落在 `wechat.dylib __TEXT` 区内,vmaddr `0x2106bc`,**不是** Dobby island),**整段跳过**原 init 链中的单例-exit 分支,直接进"实例已放行"的启动路径。
- **判定依据(为什么这处是门、其它 19 处不是):**
  1. **只在第二实例出现**:第一实例(pid 直起)dump 到的 `WeChatMain` 是原样 `fd7bbfa9`;第二实例 dump / lldb 断点处是 `d0e80714`。单例门按定义只对"第二个"生效 —— 这处 hook 的"按实例序号条件安装"行为与单例门一一对应。
  2. **位置吻合**:它改的是 `WeChatMain` 的启动 init 链入口,正是 spawn-verdict 定位的"框架加载早期(ilink2/Mars 间)、远早于 NSRunningApplication UI 检查"的时点。
  3. **功能闭环**:无插件时第二实例死在这条链上(`exit(255)`,§4);插件装上这处跳转后第二实例存活(§3)。

> 备注:单纯在运行中把这处 `WeChatMain` 字节 revert 回 `fd7bbfa9` 后,第二实例**未必立刻复活 exit**——因为 §1 里那批 Cronet/网络栈 hook(始终安装)已经把"两实例抢同一文件"等会导致早退的副作用一并消掉了。所以 X1a0He 的「门中和」是**「WeChatMain 入口重定向(跳过单例 init)」+「Cronet/Mars 文件函数 hook(数据隔离)」组合**,二者协同才让同路径第二实例稳定存活。`WeChatMain` 重定向是其中最直接、可单独定位的"单例门"那一刀。

---

## 3. 有插件:同路径两实例并存(铁证)

`/tmp/wcmem/WeChat.app`(plugin 注入 + gate① patch + adhoc 重签,多开 ON):
```
1st  pid 20290   /tmp/wcmem/.../MacOS/WeChat   RSS 282MB,存活
2nd  pid 26173   /tmp/wcmem/.../MacOS/WeChat   RSS 426MB,存活(直接 exec 起,无 open -n)
pgrep 主进程计数 = 2,>10s 并存,2nd 无 exit(255)
2nd 内存:Resources/wechat.dylib __TEXT 138.8M 全 map + X1a0HeWeChatPlugin.dylib __TEXT map
```

## 4. 无插件:同路径第二实例 `exit(255)`(对照)

`/tmp/wcnoplug/WeChat.app`(**干净业务体、无插件**、gate① 已 patch、adhoc 重签、直接 exec):
```
1st 起来存活;
2nd 同路径直起 → exit code = 255   (前台 wait 实测 $? == 255)
```
⇒ **门确实在业务体内、确实会让第二实例 `exit(255)`,且 gate①(loader 单例)patch 掉也救不了**(印证 spawn-verdict);把 X1a0He 插件装回去才放行 ⇒ **门的中和就在插件对 `wechat.dylib` 的这套内存 patch 里**(§1+§2)。

---

## 5. 给我方引擎的落地建议(constructor 里运行时 patch)

现引擎(`engine/WeChatMultiEngine.m`)走的是 **swizzle `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]→@[]`**。本轮实测:**X1a0He 根本不 swizzle 这个**(其 IMP 在已 patch 实例里仍是 AppKit 原版),真正生效的是上面的内联字节 patch。两条路线都能让第二实例存活(我方 swizzle 在 layer2-verdict 里实测也能并存),**但要"复刻 X1a0He / 不依赖 ObjC swizzle"就按下面做。**

**最小、最直接的一刀(等价 §2 那处门中和),在业务体 constructor 里:**

```c
// 仅当本进程是"第二个及以后同路径实例"时执行(自己用 NSRunningApplication 数一下
// 同 bundleId 同可执行路径的实例数,>=2 才 patch;第一实例不要动 WeChatMain)。
// 1) 用特征码定位 WeChatMain(别硬编 0x16380,随 build 变):
//    它是 __mh_execute 的 WeChatMain 导出符号;在 wechat.dylib 里 nm 取 _WeChatMain 的 slice 偏移,
//    或扫 "stp x29,x30,[sp,#-0x10]!; mov x29,sp; bl …; bl …(成对 bl init/06273ecc)" 的壳特征。
// 2) 定位它跳过单例 init 后应落入的"放行入口"(= 本 build 的 func.002106bc 对应点;
//    务实做法:不必复刻 X1a0He 的目标,直接把单例判定那一步打哑——见下面 (B) 更稳)。

uintptr_t base = /* wechat.dylib 在本进程的加载基址(_dyld_get_image_vmaddr_slide / dlopen handle) */;
uintptr_t wechatMain = base + WECHATMAIN_SLICE_OFF;        // 特征码定位
size_t page = sysconf(_SC_PAGESIZE);
void *p = (void*)(wechatMain & ~(page-1));
mprotect(p, page*2, PROT_READ|PROT_WRITE|PROT_EXEC);       // 失败则 mach_vm_protect 兜底(X1a0He 同款双保险)
// (A) 复刻 X1a0He:写一条 b 到"放行入口":
//     uint32_t br = 0x14000000 | (((target - wechatMain) >> 2) & 0x03FFFFFF);
//     *(uint32_t*)wechatMain = br;
// (B) 更稳、跨 build 友好:别跳 WeChatMain,改成 hook 那 5 个 init 里"做单例判定并 exit"的那一个,
//     把它的判定结果强制成"无其它实例"(找到其 `cbz/tbz -> 调 exit/return -1` 的分支,
//     patch 成无条件走"放行"路径,或把该 init 函数整体 `mov w0,#0; ret`)。
mprotect(p, page*2, PROT_READ|PROT_EXEC);                  // 复原权限
__builtin___clear_cache((char*)p,(char*)p+page*2);         // 刷 i-cache
```

**配套(数据隔离,否则第二实例会因抢 Cronet/MMKV/网络栈文件而不稳):** 复刻 §1 的效果,把第二实例的 **数据目录 / Cronet 缓存 / 日志路径** 指到独立目录(改 `HOME`/容器或 hook 文件打开路径),避免两实例写同一组文件。**或** 直接走 clone-bundle(改 `CFBundleIdentifier` + 独立容器),门和数据隔离一并消失(spawn-verdict §5.1,今天就能交付)。

**mprotect 范围 / 写什么(给 (A) 这一刀):**
- 范围:`WeChatMain` 所在页起 2 页,`PROT_READ|PROT_WRITE|PROT_EXEC`,写完复原 `PROT_READ|PROT_EXEC` + `clear_cache`。
- 写入:`WeChatMain` 首 4 字节 `fd7bbfa9` → 一条 `b`(`0x14000000 | imm26`)到放行入口。本 build 实测 X1a0He 写的是 `d0 e8 07 14`(`b +0x1fa340 → 0x2106bc`)。**imm26 随 build 变,务必特征码动态算,别抄死。**

---

## 6. 安全 / 结束态

| 检查项 | 期望 | 实测 |
|---|---|---|
| 全程未写 `/Applications/WeChat.app` | 是 | 是(仅只读 `.original` + 插件;只读 lldb attach 后干净 detach;施工全在 `/tmp/wcmem`、`/tmp/wcnoplug`) |
| `.original` md5 | `9a7445e8f0ddefbb69355855fb6b3654` | 一致(/tmp 副本 dylib 同 md5) |
| X1a0He 插件 md5 | `9ea5524d90f6e9abecd2df4040529c42` | 一致(用 `/Applications/.../Frameworks/` 那份) |
| /tmp 副本 | 清空 | 见下方清理 |
| 测试进程 | 全退 | 见下方清理 |
| 测试证书 | 无(全 adhoc `--sign -`) | 是 |

**工具:** lldb(只读 attach dump `__TEXT`/`__DATA_CONST`、断 `WeChatMain` 取 hook 字节与跳板 target、解析 region/module)、自写 arm64 微解码 + diff(`live_text.bin` vs `.original` slice)、r2(`af`/`pdf`/`fd.` 解析命中函数与 ObjC 方法名)、otool/nm/lipo(节布局、imports、slice 偏移)、`insert_dylib.py`(注入插件 LC_LOAD_DYLIB)、`locate_gate1.py`(loader 门① 特征码 patch)、codesign(adhoc 重签 + entitlements 回灌)、vmmap/pgrep/defaults。
