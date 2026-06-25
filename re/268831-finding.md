# WeChat 268831 多开判定函数定位 — 结论

**TL;DR:** 你给的 `WeChat_268831.bin` **不是微信主程序本体，而是一个 5MB 的加载器/壳 (loader stub)**。
多开判定函数 **不在这个文件里**，它已经被搬进了同 .app 里的 `WCDY.framework`。
所以"在 268831 里找这个函数的 VA"这个前提不成立 —— 需要去拿 `WeChat.app/Contents/Frameworks/WCDY.framework/Versions/A/WCDY` 这个二进制重新分析。

这解释了为什么之前所有签名移植都失败：函数压根不在被搜的二进制里。

---

## 1. 核心证据：268831 是 loader，不是主程序

| 指标 | 参考版 32288 (微信 4.1.5, 主程序本体) | 目标 268831 (微信 4.1.10) |
|---|---|---|
| arm64 slice 大小 | ~141 MB | **2.5 MB** |
| `__text` 大小 | 巨大 | 0x1ad5ac (1.7 MB)，且绝大部分是 OpenSSL/BoringSSL + Tencent `mars` 库 + 崩溃处理 |
| ObjC class 数 | 海量 | **1 个**（`CrAppProtocol`，Chromium/Crashpad 的，不是业务类）|
| `__objc_methname` 段 | 0xc505 | **0x60d**（几乎为空）|
| `objc_msgSend` 调用点 | 数万 | **53 个** |
| 标志性字符串 | 业务字符串、`AVCaptureDeviceTypeBuiltInWideAngleCamera` 等 | `xwechat_load`、`WCDYCrshInfoKey!xWeChatLdrIV2024`、`is_wcdy_supported`、`loader_completed`、`bad decrypt`、`%s.dylib` |

关键 load command：
- 目标 268831 链接了 `@rpath/WCDY.framework/Versions/A/WCDY`（compat 1.0.0）
- LC_RPATH = `@executable_path/../Frameworks`
- 即：`MacOS/WeChat`（这个 loader）运行时去 `Contents/Frameworks/WCDY.framework/Versions/A/WCDY` 加载真正的微信。
- `WCDY` ≈ "微信电脑" 的内部代号；loader 内含 OpenSSL CMS/EVP 解密例程 + `xWeChatLdrIV2024` 这种 IV 字样，说明它会解密/校验后再把主体 load 进来。

补充：`re/` 目录下另外两个文件 `WeChat.bin`(1.84MB, App Store 版 loader, 路径含 `xwechat_mac_appstore`) 和 `WeChat_official.bin`(5.35MB, 与 268831 同源的 loader) **也都是 loader**，不是 WCDY framework。三个顶层 .bin 全是壳。

### 微信 4.x 架构变化（与社区情报一致）
- 微信 4.x 改成 **Qt/C++ 重写**；老的 ObjC 类面（如 `CUtility`）基本消失。
- 历史上多开判定是 `+[CUtility HasWechatInstance]`（返回 BOOL），WeChatTweak 把它前 8 字节覆盖成 `mov w0,#1; ret`。
- WeChatTweak 的 config.json **只有 3.x build**（31927/32281/32288/31960/34371），没有任何 4.x/268831 条目；issue #962 里 4.1.5 多开早就失效。
- 参考版 32288 (你标注为 4.1.5) 仍是 **objc 密集的单体主程序**，函数 `0x1001e1a74` 也确实是 objc_msgSend 满天飞的大函数（带 `sub sp,sp,#0x180` 大栈帧、`cmp x0,2; cset w20,lo` 这类字符串/版本比较）。
- 到 4.1.10 (268831) 时，微信把主体拆成了 **loader (MacOS/WeChat) + WCDY.framework**。函数搬家到了 framework 里。

---

## 2. 候选 VA

**在 `WeChat_268831.bin` 内：无可信候选。**

理由：该二进制不含微信业务代码（见上表），其 `__text` 内容是：
- BoringSSL/OpenSSL（`EVP_Decrypt*`, `CMS_decrypt*`, `rsa_ossl_*` 等）
- Tencent `mars` 网络库（路径 `/Users/bkdevops/.wconan2/mmnet/.../mars/comm/...`）
- loader 自身逻辑（`xwechat_load`, `is_wcdy_supported`, `DetectPreviousCrpid`）
- Crashpad/Chromium base

排查过的"疑似点"及排除原因：
- `_flock` 确实被 import（stub @ `0x1001bed74`），但其周边 `lock`/`islocked`/`Mutex` 字符串全部来自 `mars` 的 `unix/thread/lock.h`、`mutex.h` 和 OpenSSL 的 `asn1_do_lock`/`engine_unlocked_finish`，是通用线程锁，**不是 app 单实例 lock.ini 的 flock**。没有 `lock.ini`、没有 "already running"、没有 AppKit reopen 业务串。
- `DetectPreviousCrpid:` 看名字像"检测已有进程"，但它属于 Crashpad（crpid = crash reporter pid），与多开判定无关。

置信度：**该文件不含目标函数 = 高置信度**。

---

## 3. 下一步建议（怎么真正拿到答案）

1. **拿对二进制。** 去真实 .app 里取
   `WeChat.app/Contents/Frameworks/WCDY.framework/Versions/A/WCDY`
   （这才是微信 4.1.10 的本体，对应 32288 那个 141MB 单体）。对它跑分析，多开判定函数在它里面。
   - 注意 WeChat_official.bin / WeChat.bin / 268831 都是壳，别再在它们上面搜了。

2. **拿到 WCDY 后的定位思路（参考函数已破解，可复用语义）：**
   参考版 32288 的函数 `0x1001e1a74` 真身（跳过前面 4 条间接派发守卫 `adrp x9; ldr x9,[x9,#0xf18]; cbz; br x9`）从 `0x1001e1a84` 开始，特征：
   - 大栈帧 `sub sp,sp,#0x180`，保存 x28..x19/x29/x30
   - 取 `AVCaptureDeviceTypeBuiltInWideAngleCamera` 之类全局存栈（疑似栈金丝雀/无关）
   - `bl func.103cba16c` 后 `tbz w0,#0, ...`：拿一个 bool 分支
   - 一连串 `objc_msgSend` + `objc_retainAutoreleasedReturnValue`，中间 `cmp x0,2; cset w20,lo`（像比较某计数/版本是否 < 2）
   这是个"判断是否已有实例 / 是否允许新实例"的 ObjC 方法（很可能就是 `HasWechatInstance` 在 4.x 的等价物）。
   在 WCDY 里建议：
   - **(a) 字符串交叉引用**：4.x Qt 化后多用 C++，先 `strings` 找 `lock.ini`、单实例相关串、`flock` 调用点，回溯调用者里那个返回 bool 的小函数。
   - **(b) 选择子签名**：若仍是 ObjC，搜 `__objc_methname` 里 `HasWechatInstance`/`hasInstance`/`allowMulti`/`isMultiInstance` 之类，再经 `__objc_selrefs` 找到引用它的方法实现。
   - **(c) 函数体中段位置无关指令片段**（而非函数开头）做签名，从 32288 的 `0x1001e1a84` 之后那段 `objc_msgSend` 簇 + `cmp x0,2; cset w20,lo` 取一段无 adrp/分支的指令做匹配。
   - **(d) 交叉引用**：32288 里谁 `bl 0x1001e1a74`（调用者），在 WCDY 里找同构调用点。

3. **如果只想要"能多开"而不在乎补这个函数**：社区在 4.x 上已基本放弃二进制补丁，改用 **App 克隆法**（`ditto` 复制 WeChat.app → 用 PlistBuddy 改 `CFBundleIdentifier` → `codesign --force --deep` 重签），绕开任何 in-binary 判定。这对 4.1.10 是更稳的路子。

---

## 4. 方法与验证记录

- 用 `lipo -thin arm64` 把两个 fat 文件切出纯 arm64 thin Mach-O，便于 r2 用真实 VA 寻址（直接 `r2 -a arm64 -b 64` 读 fat 文件里某偏移会读到未映射区返回 0xff，不可靠）。
- 在 thin macho 上 `r2 -q -c 's 0x1001e1a74; pd' ` 成功还原参考函数，确认前缀守卫 + 大函数结构与题面一致。
- 对 268831 thin slice 做 `otool -l/-L/-Iv`、`strings`、`nm -u`、objc 段大小统计、`objc_msgSend` 计数，交叉印证它是 loader：
  - 链接 `WCDY.framework`、含 `xwechat_load`/CMS 解密、ObjC 几乎为空、msgSend 仅 53 处。
- 启动了一个联网调研子代理，独立确认：WeChatTweak 补的是 `+[CUtility HasWechatInstance]`、config.json 只覆盖 3.x、4.x 已 Qt 化、社区转向克隆法。结论一致。

文件路径备注（均为 thin slice 临时副本，原文件未改动，全程只读）：
- 参考 thin: `/private/tmp/.../slices/wc32288_arm64.macho`
- 目标 thin: `/private/tmp/.../slices/wc268831_arm64.macho`
