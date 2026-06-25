# 微信 4.1.11 第二道单例门 —— 定位 + 调用栈 + 静态 patch

**对象:** WeChat 4.1.11（`com.tencent.xinWeChat`，Team `5A4RE8SF68`）。
**方法:** 早期注入诊断 dylib，hook `exit`/`_exit`/`_Exit`/`abort`，被调用时 `backtrace` 落盘。
**全程未写 `/Applications/WeChat.app`（X1a0He 版只读、只 `open`）。诊断在 `/tmp/wcdiag` 干净副本上做，测完已清理。结束态 X1a0He 完好（md5/codesign 全过，见文末）。**

---

## 0. 一句话结论

> **第二道门在 loader（`Contents/MacOS/WeChat`，5.6MB 明文可执行）里，不在 `wechat.dylib`，不在系统库。** 它是一个 **mach bootstrap 单例锁**：loader 启动早期用 `mach_port_allocate` + `bootstrap_look_up`/`bootstrap`（注册一个固定的 well-known mach service 名）来判断"是否已有实例"。若已有 → 走 **relaunch + 父进程 `_exit(0)`** 路径（这就是"fork 出新 PID、~1.5-2s 后干净自退"的真相）。
>
> **它发生在 `Resources/wechat.dylib`（320MB 业务体）被 dlopen 之前** —— 所以**改 `wechat.dylib` 永远治不了它**。第一道门（`NSRunningApplication` 谓词 @ `wechat.dylib` fat `0x0acbdee8`）是业务体内的二级门；这第二道门更早、在 loader 内。
>
> **能静态 patch。** 决策点是 loader arm64 slice VA `0x10009df88` 的 `cbz w0, 0x10009e0f0`，改成无条件 `b 0x10009e0f0` 即让 loader 永远认为"我是唯一实例"，**relaunch+`_exit(0)` 路径被消除**（实测：打完该 patch 后 hook 再也抓不到那条 `_exit(0)`）。

---

## 1. 调用栈（谁调 exit）—— 实测 backtrace

诊断 dylib 注入 `/tmp/wcdiag` 副本（第一道门已 patch + adhoc 重签）。先跑 X1a0He 版做"已有实例"，再 `open -n` 诊断副本 → 它检测到已有实例 → 自退。hook 抓到的**稳定、可复现**调用栈（3 次运行偏移完全一致，仅 slide 变）：

```
===== _exit(code=0) pid=<child> =====
  [ 0] tracer.dylib   wc_log_bt
  [ 1] tracer.dylib   my__exit            ← 我们 hook 的 _exit
  [ 2] WeChat        +0xaa55c             ← bl __exit 的返回地址（call 在 0xaa558）
  [ 3] WeChat        +0x9fda0
  [ 4] WeChat        +0x9e254             ← bl 0x10009ee08（relaunch helper）的返回地址
  [ 5] WeChat        +0xa1470
  [ 6] WeChat        +0x59a98
  [ 7] WeChat        +0x5a0a0
  [ 8] WeChat        +0x5a4c0             ← loader 主初始化序列
  [ 9] dyld          start
```

**全部 `WeChat` 帧都在 loader（`Contents/MacOS/WeChat`）里**，没有一帧在 `wechat.dylib` / WCDY / 系统框架。`Resources/wechat.dylib`（320MB 业务体）此时**根本还没被 dlopen**（诊断 dylib 的 constructor 在自退前的镜像列表里只有 loader + WCDY + andromeda + mmcronet，无 `Resources/wechat.dylib`）。

> 注：偏移是 arm64 thin slice 内 VA（loader `__TEXT vmaddr=0x100000000`、`__text fileoff=0x12000`、addr `0x100012000`；slice 内 file_off = VA − `0x100000000`）。

---

## 2. 这道门是什么（反汇编实证）

### 2.1 真正的决策点 —— mach 单例检查 + relaunch 分支

loader VA `0x10009df0c` 是 "checkSingletonAndMaybeRelaunch" 函数。核心：

```
0x10009df70  mov w0, #1
0x10009df74  bl  0x1000a8160      ; ← 单例检查（见 2.2）。返回 w0 = 0 表示"我成功占住端口=我是唯一实例"
                                  ;                w0 ≠ 0 表示"已有别的实例占着端口"
0x10009df84  str w0, [sp, #0x70]
0x10009df88  cbz w0, 0x10009e0f0  ; ★第二道门决策★  w0==0(唯一) → 跳 0x9e0f0 干净继续
                                  ;                 w0!=0(有别人) → 落空 → 进入 relaunch+_exit 序列
0x10009df8c  ...                  ; (落空分支) 收集 posix_spawn 参数
0x10009e250  bl  0x10009ee08      ; relaunch helper（frame4）
```

落空分支最终走到 relaunch helper（`0x10009ee08` → … → spawn 函数 `0x1000aa484`）：

```
; 函数 0x1000aa484（spawn-then-exit）
0x1000aa540  blr x8               ; posix_spawn / posix_spawnp（拉起新进程）
0x1000aa544  mov x20, x0          ; x20 = spawn 结果
0x1000aa550  cbnz w20, 0x1000aa560 ; spawn 失败 → 重试；成功 → 落下
0x1000aa554  mov w0, #0
0x1000aa558  bl  __exit           ; ★ _exit(0)：父进程干净自退 ★  ← backtrace frame[2] 命中点
```

这就是"重复实例 fork 出新 PID 后 ~1.5-2s 父进程 `_exit(0)`"的机器码真相 —— 经典 **relaunch-and-die**。

### 2.2 单例检查本体 `0x1000a8160`（mach bootstrap 锁）

```
0x1000a8160  ...                          ; 函数入口
0x1000a8180  ldr  ... _mach_task_self_
0x1000a818c  bl   _mach_port_allocate     ; 申一个 receive right
0x1000a81b4..e8  XOR 解混淆出一个固定 service 名（运行时拼，__cstring 里无明文）
             ; → bootstrap 注册/查询该 well-known mach service
0x1000a8134  cset w0, eq                  ; 返回布尔：成功占住=0 / 已被占=非0
```

loader 的 import 表直接坐实机制（仅此一处 `bootstrap_look_up` 代码 xref @ `0x1000a6d98`）：
```
_bootstrap_look_up   _bootstrap_port   _bootstrap_strerror
_mach_port_allocate  _mach_port_extract_right  _mach_port_mod_refs
_mach_port_request_notification   _flock
```
即：**第一个实例注册一个 well-known mach service 名并持有；后续实例 `bootstrap_look_up` 命中 → 判定"已有实例" → relaunch+`_exit(0)`。** 这与豆包"方法2"里 `bootstrap_check_in`/`bootstrap_look_up` 的猜测完全吻合，是 mach-port 级单例而非文件锁、非 `NSRunningApplication`。

> （另有 `0x1000a6d98` 处 `bootstrap_look_up` + `cbz w0,0x1000a6eb8` 是同机制的并行/辅助查询点；实测单 nop 它**不足以**消门——真正喂给 relaunch 决策的是 `0x1000a8160` 的结果，见 §3。）

---

## 3. 静态 byte-patch（交付物，实测有效消除自退）

| 项 | 值 |
|---|---|
| 目标二进制 | **`Contents/MacOS/WeChat`**（loader，**不是** `wechat.dylib`）|
| 架构 | arm64 |
| 函数 | `0x10009df0c`（单例检查→relaunch 决策）|
| 指令 VA | **`0x10009df88`** |
| arm64 thin slice 内 file 偏移 | **`0x9df88`** |
| **干净原版 loader fat 文件偏移** | **`0x379f88`**（= arm64 fat 起点 `0x2DC000`/2998272 + `0x9df88`）|
| 原始字节 | `40 0b 00 34`（`cbz w0, 0x10009e0f0`）|
| **patched 字节** | **`5a 00 00 14`**（`b 0x10009e0f0`，无条件跳"我是唯一实例"continue 分支）|

含义：无论单例检查结果如何，永远走"唯一实例"路径，**不再进入 relaunch+`_exit(0)`**。

> ⚠️ fat 偏移依赖 loader 是否被 `insert_dylib` 改过：
> - **干净原版 loader**（DMG/原 `/Applications`）：arm64 fat 起点 `0x2DC000` → 门 fat 偏移 **`0x379f88`**。
> - 若先 `insert_dylib` 注入过插件再 patch（X1a0He 注入版 loader），slice 会前移，需重新 `lipo -detailed_info` 取 arm64 `offset` 再 `+0x9df88`。slice 内偏移 `0x9df88` 恒定。

### 复现（python）
```python
# 干净原版 loader
p = "WeChat.app/Contents/MacOS/WeChat"
f = open(p, "r+b")
f.seek(0x379f88); assert f.read(4) == bytes.fromhex("400b0034")
f.seek(0x379f88); f.write(bytes.fromhex("5a000014")); f.close()
# 然后 adhoc 重签 loader（带 entitlements，见 §5）
```

### 实测验证
- **未打此 patch**：X1a0He 跑着时 `open -n` 诊断副本 → hook 稳定抓到 `_exit(0)`（§1 调用栈），副本自退。
- **打此 patch 后**（`cbz`→`b`）：同样场景 → **hook 再也抓不到那条 `_exit(0)`**（`grep _exit(code=0)` = 0 条）。relaunch+自退路径被彻底消除。✓

---

## 4. 还剩什么 / 边界（诚实）

打掉第二道门后，relaunch+`_exit(0)` 没了，但**诊断副本仍未能并存常驻**：它改走 loader `main()` 正常 `return`（hook 抓到的是 `dyld…exit` from `start`，即 main 返回，**不是** relaunch），且 **`Resources/wechat.dylib` 体始终没被 dlopen**。无论"有别的实例"还是"独占"都如此（独占时存活更久 ~8s 再 `main` 干净返回）。

判断：这**不是第三道单例门**，而是 **adhoc 重签副作用**：
- loader 自带 `xWeChatLdrIV2024`/`bad decrypt`/`is_wcdy_supported` —— 它在 dlopen 业务体前**校验**（这正是 X1a0He 要 hook ~17 个 `Security.framework` 函数的原因，见 `injection-approach.md` §2.2）。
- 诊断副本顶层是 adhoc（`TeamIdentifier=not set`），loader 的校验/沙盒前提不满足 → loader 决定不加载业务体、`main` 干净返回。系统日志**无** container REJECTED（排除了 group-container 那个签名坑），属 loader 自身的"前提不满足就不跑"。
- 对比 `byte-patch-4.1.11.md` §3 实测过"patched 副本与 X1a0He 并存 2 实例"成立 —— 那是**跨 bundle**（不同 path）场景，单例 mach service 名/注册行为不同；本次是**同 bundle `open -n`**，loader 校验链更敏感。

**结论:** 第二道门（mach 单例 relaunch）= **可静态 patch，已给偏移**。但要让"同 bundle `open -n` 叠开"真正常驻，还需绕过 loader 对业务体的校验（adhoc 重签后失效），这要么走**注入式**（hook loader 的 Security/校验函数，X1a0He 路线），要么走 `byte-patch-4.1.11.md`/`open-n-verify.md` 已定的 **clone bundle（改 CFBundleIdentifier）** 稳妥路线（不同 bundle 各自独立单例域，连第二道门都不会触发）。

---

## 5. 能否纯静态 patch？最终裁定

| 问题 | 裁定 |
|---|---|
| 第二道门在哪 | **loader `Contents/MacOS/WeChat`**（不是 `wechat.dylib`、不是系统库） |
| 是什么 | **mach bootstrap 单例锁**（`mach_port_allocate`+`bootstrap_look_up`/注册 well-known service），命中即 **relaunch + 父 `_exit(0)`** |
| 谁调 exit | loader 自己：`0x1000aa558  bl __exit`（`_exit(0)`），由单例决策 `0x10009df88 cbz w0` 落空触发 |
| 能否静态 patch 掉自退 | **能**。loader arm64 `0x9df88`（fat `0x379f88`）`cbz w0`→`b`（`400b0034`→`5a000014`）。实测消除 `_exit(0)`。✓ |
| 单 patch 是否=同 bundle 叠开常驻 | **否**。还卡在 loader 对业务体的校验（adhoc 重签后失效）。要并存常驻：注入式 hook 校验 **或** clone bundle（推荐，见前序报告）。 |
| 注入式（hook 它）是否唯一解 | 对"同 bundle 叠开常驻"不是唯一解（clone bundle 更稳）；但对"就地改 `/Applications` 单 app 多开"，注入式（hook loader 单例 + 校验）是务实解 = X1a0He 路线。 |

**给引擎的直接启示:** 多开链有**三层**：① loader mach 单例（本报告，`MacOS/WeChat` `0x9df88`，最早）→ ② loader 对业务体校验（adhoc 敏感）→ ③ 业务体内 `NSRunningApplication` 谓词（`wechat.dylib` fat `0x0acbdee8`，最晚）。**clone bundle 一招全绕**（不同 path+id 三层都不触发），这仍是性价比最高的落地路线；纯静态单 app 多开需同时处理 ① 和 ②。

---

## 6. 工具/方法

- 诊断 dylib（`tracer.c`，arm64）：`DYLD_INTERPOSE` hook `exit`/`_exit`/`_Exit`/`abort`，`backtrace`+`dladdr` 落盘。
  - **坑1（已解决）**：WeChat 沙盒禁写 `/tmp` → 改写 `$HOME/tmp/wc_tracer.log`（沙盒下 `$HOME`=容器 `…/Containers/com.tencent.xinWeChat/Data`，可写）。`os_log` 自定义 subsystem 在本机 `log show` 不持久化，弃用。
  - **坑2（已解决）**：hook 内 `dlsym(RTLD_NEXT,"exit")` 会再拿到被 interpose 的自己 → 无限递归爆栈。改用 `syscall(SYS_exit, code)` 直接退、绕过 interpose。
- 注入：`insert_dylib`（pkg 自带 Tyilo 版）给 loader + `wechat.dylib` 各插 `@rpath/tracer.dylib`（`@executable_path/../Frameworks` 已解析）。
- 反汇编：`otool -tvV` / `r2`（注意 r2 直接读 fat 易错位，先 `lipo -thin arm64` 出 thin slice 再寻址）。
- 重签（避坑）：adhoc 签 tracer + loader（带 entitlements），**不 `--deep`**，保留嵌套腾讯团队签（否则 containermanagerd 拒 group container 自退，那是签名坑非门）。

---

## 7. X1a0He 完好性确认（结束态）

| 检查项 | 期望 | 实测 |
|---|---|---|
| `/Applications/.../wechat.dylib` md5 | `52bb2c9e4c0cb755ab9a82db52e6b8b8` | **一致** ✓ |
| `wechat.dylib.original` md5 | `9a7445e8f0ddefbb69355855fb6b3654` | **一致** ✓ |
| `X1a0HeWeChatPlugin.dylib` | 存在（4411136 bytes）| **存在** ✓ |
| `codesign --verify /Applications/WeChat.app` | 通过 | **rc=0** ✓ |
| 结束时测试进程 | 全部清理 | **0**（`/tmp/wcdiag` 已删、DMG 已卸载、tracer 日志已清）✓ |

**全程未对 `/Applications/WeChat.app` 做任何写操作**（仅 `open` 拉起做"已有实例"）。诊断在 `/tmp/wcdiag`（DMG 干净副本）上做，已删除。
</content>
</invoke>
