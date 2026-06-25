# 微信 4.1.11 多开 byte-patch —— 确切 patch + 实测验证

**对象:** WeChat 4.1.11，`CFBundleVersion=269077`，`com.tencent.xinWeChat`，Team `5A4RE8SF68`。
**patch 底子:** `/Applications/WeChat.app/Contents/Resources/wechat.dylib.original`（干净未注入，306M fat；md5 `9a7445e8f0ddefbb69355855fb6b3654`）。
**全程未改 `/Applications`，只在 `/tmp` 副本上 patch+签名+实测。用户的 X1a0He 结束时完好（见文末）。**

---

## 0. 一句话结论

> **真正的多开网关不是 `flock(lock.ini)`，而是 ObjC 选择子 `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]`。** 在明文 `wechat.dylib` 里有一个自包含的「是否已有实例」谓词函数 `func.00ec5e84`，它 `runningApplicationsWithBundleIdentifier: → count → (count!=0)` 返回布尔。把这个布尔强制成 0（"无其他实例"），**单字节级 4 字节 patch + ad-hoc 重签**即可让微信与已有实例**并存**。实测：patched 副本与用户的 X1a0He 微信**同时各跑一个进程**，共 2 个 `WeChat.app/Contents/MacOS/WeChat`。
>
> 前序 verdict 里"flock/lock.ini cbz 是多开网关"的判断**不成立**——实测翻转那些 cbz / 强制 flock 成功（patch v1/v2）**都不产生多开**。lock.ini/flock 是**账号级数据目录锁**，不是进程级单例门。

---

## 1. 确切 patch（交付物）

### 1.1 单点 4 字节 patch（已实测生效）

| 项 | 值 |
|---|---|
| 架构 | arm64（thin slice）|
| 函数 | `func.00ec5e84`（"是否已有实例运行"谓词）|
| 指令 VA | **`0x00ec5ee8`** |
| arm64 thin slice 内文件偏移 | `0x00ec5ee8`（`__TEXT` vmaddr=0/fileoff=0，VA==slice 偏移）|
| **fat 文件内偏移**（306M dylib） | **`0x0acbdee8`**（= arm64 slice fat 起点 `0x9DF4000`/165642240 + `0xec5ee8`）|
| 原始字节 | `f5 07 9f 1a`（`cset w21, ne`）|
| **patched 字节** | **`15 00 80 52`**（`mov w21, #0`）|

含义：原本 `cmp x0, #0 ; cset w21, ne` 让 `w21 = (running.count != 0)`；patch 后 `w21` 恒为 0，函数恒返回"无其他实例运行"。

反汇编（patch 前后）：
```
; --- func.00ec5e84  单例谓词 ---
0x00ec5e9c  adrp x8, 0x8efa000
0x00ec5ea0  ldr  x1, [x8, 0xb60]        ; sel = sharedWorkspace/bundleId 取法
0x00ec5ea4  bl   objc_msgSend
...
0x00ec5ec0  ldr  x1, [x8, 0x6f8]        ; sel = runningApplicationsWithBundleIdentifier:
0x00ec5ec8  bl   objc_msgSend           ; → NSArray<NSRunningApplication*>
0x00ec5edc  ldr  x1, [x8, 0xaf0]        ; sel = count
0x00ec5ee0  bl   objc_msgSend           ; x0 = 实例数
0x00ec5ee4  cmp  x0, #0
0x00ec5ee8  cset w21, ne                ; w21 = (count != 0)   ← 原始
0x00ec5ee8  mov  w21, #0                ; w21 = 0  (恒"无其他实例") ← PATCHED
...
0x00ec5efc  mov  x0, x21                ; 返回值 = w21
0x00ec5f0c  ret
```

### 1.2 WeChatTweak 风格 config.json（arm64）

```json
{
  "version": 269077,
  "shortVersion": "4.1.11",
  "arch": "arm64",
  "target": "Contents/Resources/wechat.dylib",
  "note": "wechat.dylib is fat (x86_64+arm64); arm64 slice starts at fat offset 0x9DF4000. __TEXT vmaddr=0 so VA==slice-offset.",
  "patches": [
    {
      "name": "MultiInstance_NSRunningApplication_predicate",
      "va": "0x00ec5ee8",
      "fileOffsetArm64Slice": "0x00ec5ee8",
      "fileOffsetFat": "0x0acbdee8",
      "original": "f5079f1a",
      "patched":  "15008052",
      "asm_original": "cset w21, ne",
      "asm_patched":  "mov  w21, #0",
      "desc": "func.00ec5e84: force 'is another instance running?' predicate to always return 0"
    }
  ],
  "postPatch": [
    "codesign --force --sign - Contents/Resources/wechat.dylib",
    "codesign --force --deep --sign - WeChat.app"
  ]
}
```

> 注：`fileOffsetArm64Slice` 用于你已经 `lipo -thin arm64` 出来的 thin 文件；`fileOffsetFat` 用于直接 patch 原始 fat dylib（WeChatTweak 通常这么干）。x86_64 slice 同名函数偏移**未在本次定位**（用户机为 arm64，实测只覆盖 arm64；要支持 Intel 需在 x86_64 slice 重复定位 `runningApplicationsWithBundleIdentifier:` 谓词）。

### 1.3（可选）额外候选点

`runningApplicationsWithBundleIdentifier:`（selref `0x8efa6f8`）在 dylib 里共 3 处代码 xref：
- `0x001cc35c` —— `count` 后 `cmp x0,#2 ; b.lo`（"≥2 个实例就激活已有窗口"的 UI 路径）。配套点：把 `0x001cc38c` 的 `b.lo`(`c3010054`)→ 无条件 `b 0x1cc3c4`(`0e000014`) 可让它永远走"solo"分支。
- `0x00ec5ebc` —— **本交付 patch 所在**（谓词，最干净）。
- `0x044e1fb4` —— 另一处谓词变体，返回 `w20`。

实测：**只打 1.1 单点**即足以让 patched 副本与已有实例并存（见 §3）。`0x1cc38c` 那点对"同一 bundle 用 `open -n` 叠起来"无效（原因见 §4）。

---

## 2. 为什么不是 flock / lock.ini（推翻前序候选）

前序 verdict 给的候选 `cbz w0` @ `0x43391a4 / 0x433d4bc / 0x433d4d0`，以及 flock 簇 `func.04c66dac`（`flock(fd, LOCK_EX|LOCK_NB)`，占用时返回 3/5/0xf0a）。逐个实测：

| patch | 改动 | 实测结果 |
|---|---|---|
| v1 | `0x4339140` cbz→`b 0x4339208`（强制走 lock.ini "允许"分支）| 第二实例仍**退出**，不多开 |
| v2 | `0x4c66e04` cbz→`b 0x4c66e64`（强制 flock 永远"取锁成功"）| 第二实例仍**退出**，不多开 |

lldb 追踪第二实例：退出码 255，**`flock`/`exit`/`_exit`/`abort` 断点全未命中**，`dlopen` 之前就 bail——说明 flock 路径根本没参与进程级单例决策。`lock.ini` 是**账号数据目录级文件锁**（`…/app_data/lock/lock.ini`、各 `wxid_*/lock.ini`），管的是"同一账号别被两个进程同时写库"，不是"微信 App 只能开一个"。

进程级单例真相（lldb attach 已装 X1a0He 的活体微信，断 `DobbyHook` 读 hook 目标得到，42 个 hook 里的关键一条）：
```
DobbyHook  x0 = AppKit`+[NSRunningApplication runningApplicationsWithBundleIdentifier:]
```
X1a0He 把这个系统选择子 hook 成返回空数组 → 微信认为"没有其他实例" → 放行。本 patch 是它的**静态等价**：不改系统框架，而是改 `wechat.dylib` 里**消费**这个选择子结果的谓词函数，把 `count!=0` 钉成 0。

X1a0He 另外 hook 了 ~17 个 `Security.framework` 函数（`SecCodeCheckValidity`/`SecStaticCodeCheckValidity*`/`SecRequirementCreateWithString`/`SecTaskCopyTeamIdentifier`…）—— 这是**绕过微信自身的代码签名自校验**（这点修正了前序 verdict "应用层无完整性校验"的说法：**有**，走 Security API 自查）。但实测：**clean dylib 仅 ad-hoc 重签后能正常启动并常驻**，所以自校验在"本地 ad-hoc 重签"这条路上没有把我们拦死，纯 byte-patch 无需附带 Sec hook 即可启动多开。

---

## 3. 实测验证（关键）

环境：用户 `/Applications` 是 X1a0He 注入版（`MultipleInstance=1`），全程未动。测试副本 = `/tmp/.../test/WeChat.app`（clean original dylib + 1.1 单点 patch + `codesign --force --sign -` dylib + `codesign --force --deep --sign -` 整 app）。

进程计数用 `pgrep -f 'WeChat.app/Contents/MacOS/WeChat$'`（排除 WeChatAppEx/crashpad）。

**对照（clean，未 patch，仅重签）：**
```
启动副本#1            → 副本进程数 1
再启动副本#2(锁被#1持) → 副本进程数仍 1   （单例生效，#2 自退）
```

**patch v3（单点 1.1）：**
```
before:  /Applications X1a0He 实例 = 1 ，  patched 副本 = 0
启动 patched 副本
after :  /Applications X1a0He 实例 = 1 ，  patched 副本 = 1     → 共 2 个并存
```
证据（`ps` 同时可见两条不同路径的主进程）：
```
75311  /Applications/WeChat.app/Contents/MacOS/WeChat                    (X1a0He)
75108  /private/tmp/.../test/WeChat.app/Contents/MacOS/WeChat            (patched, clean底子)
```
patched 副本在"已有实例正持有单例"的前提下**仍启动并常驻**（稳定 >20s，正常进入 MMKV/账号加载阶段），对照组在同样前提下会自退。→ **byte-patch 让多开成立。**

另一独立佐证：对 clean 副本在 lldb 里把 `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]` 强制返回空 `NSArray`，第二实例同样**存活**（两进程并存）。这定性证明该选择子就是单例门，1.1 的静态 patch 正是消费端等价。

---

## 4. 还需不需要"第二实例独立数据目录"？/ 同 bundle 叠开的边界

- **数据目录隔离：实测多开当下不是硬阻塞。** 两实例共用同一容器 `~/Library/Containers/com.tencent.xinWeChat`，靠账号级 `lock.ini`（flock）天然互斥——同一时刻**同一 wxid 只能一个实例写库**。所以典型用法是 **A 实例登账号甲、B 实例登账号乙**，各自抓不同 `wxid_*/lock.ini`，互不冲突。若两实例都想登**同一账号**，会撞账号锁，需要给第二实例**独立容器/数据目录**（X1a0He 文档也没确认它隔离了数据目录——本次实测它确实没隔离，靠"不同账号"规避）。结论：**多开本身不需要改数据目录；同账号双开才需要，且那是另一道工程（hook 容器/数据路径选择，或起进程时改 `HOME`/沙盒）。**

- **同一 bundle 用 `open -n` 叠两个：本 patch 不解决。** 实测：patched app `open -n` 两次仍合并成 1。原因是**同 bundle path+id 的去重发生在 LaunchServices/loader 层**（不在 `wechat.dylib` 的这几个 ObjC 谓词里，patch `0x1cc38c` 也无效）。X1a0He 能"同 bundle 叠开"是因为它插件侧另带了 **NSTask/`setLaunchPath:` 重新拉起**的 re-launcher（见 injection-approach §2.3）。
  - **纯 byte-patch 的稳妥多开姿势 = patch + App 克隆**：`ditto` 复制成 `WeChatB.app`，改 `CFBundleIdentifier`（如 `com.tencent.xinWeChat.b`）+ 打本 patch + `codesign --force --deep -s -`，则两个 bundle 各自独立、各自一个实例，叠几个都行。本次跨 bundle 路径的 2 实例并存实测正是这个原理的最小验证。

---

## 5. 复现步骤（落地）

```bash
# 1. 取干净底子
cp /Applications/WeChat.app/Contents/Resources/wechat.dylib.original /tmp/WeChat.app/Contents/Resources/wechat.dylib

# 2. 打 patch（fat 文件偏移 0x0acbdee8： f5079f1a -> 15008052）
python3 - <<'PY'
f=open('/tmp/WeChat.app/Contents/Resources/wechat.dylib','r+b')
f.seek(0x0acbdee8); assert f.read(4)==bytes.fromhex('f5079f1a')
f.seek(0x0acbdee8); f.write(bytes.fromhex('15008052')); f.close()
PY

# 3. 重签（硬化运行时 + 封签，必须）
codesign --force --sign -  /tmp/WeChat.app/Contents/Resources/wechat.dylib
codesign --force --deep --sign -  /tmp/WeChat.app

# 4. （叠同账号/同 bundle 时）改 bundle id 克隆，或直接与已有实例并存启动
```

---

## 6. 失败/卡点记录（诚实）

1. **flock/lock.ini 路线（前序候选）= 死路**：v1/v2 实测不多开；那是账号数据锁不是进程单例门。已弃。
2. **同 bundle `open -n` 叠开**：本 byte-patch 不覆盖（去重在 LS/loader 层）。需配 App 克隆或 NSTask re-launcher。
3. **x86_64 slice** 未定位同名谓词偏移（用户机 arm64，未实测 Intel）。
4. **代码签名自校验**：微信有（Security API 自查，X1a0He hook 了 17 个），但 ad-hoc 本地重签这条路实测没被它拦死，故纯 patch 无需附带 Sec hook 即可启动。若将来某版加强自校验，可能需补 Sec hook（那就回到注入路线）。

---

## 7. 用户 X1a0He 完好性确认（结束态）

| 检查项 | 期望 | 实测 |
|---|---|---|
| `/Applications/.../wechat.dylib` md5 | `52bb2c9e4c0cb755ab9a82db52e6b8b8`（X1a0He 注入版）| **一致** ✓ |
| `wechat.dylib.original` md5 | `9a7445e8f0ddefbb69355855fb6b3654` | **一致** ✓ |
| `X1a0HeWeChatPlugin.dylib` | 存在（4411136 bytes）| **存在** ✓ |
| 活体 dylib 内 X1a0He LC_LOAD_DYLIB | 2 处引用 | **2** ✓ |
| `codesign --verify --deep /Applications/WeChat.app` | 通过 | **通过** ✓ |
| 结束时运行实例 | 1 个干净 X1a0He | **1** ✓ |

**全程未对 `/Applications/WeChat.app` 做任何写操作**（所有 patch/签名/启动都在 `/tmp` 副本）。另有完整备份留在 scratchpad `backup_x1a0he/`（`wechat.dylib.x1a0he` + `_CodeSignature/` + `X1a0HeWeChatPlugin.dylib` + `STATE.txt`），但本次未动用——用户 X1a0He 安装**完好可用**。
