# 自研最小多开注入引擎 — 实测报告(微信 4.1.11)

**对象:** WeChat 4.1.11(`com.tencent.xinWeChat`,Team `5A4RE8SF68`)。
**底子:** 干净 `~/Downloads/WeChatMac.dmg`(loader MD5 `81f484e030818166727fc2fcb15345a0`,dylib MD5 `37673e6fbfd138ddb50fd03a6694c256` —— 与 `layer2-verdict.md` 的 build 一致)整 bundle `ditto` 到 `/tmp/wctest`。
**全程未写 `/Applications/WeChat.app`**(X1a0He 注入版,pid 25431 用户在用,全程只读 / 只做"已运行实例"。结束态见 §6)。

交付物(均在 `/Users/will/Projects/WeChatMulti/engine/`):
- `WeChatMultiEngine.m` / `WeChatMultiEngine.dylib`(universal arm64+x86_64)—— 注入引擎。
- `insert_dylib.py` —— LC_LOAD_DYLIB 注入器(无 brew 依赖,纯 Python,支持 fat)。
- `locate_gate1.py` —— 门①运行时特征码定位器。
- `install-self-engine.sh` —— 一键安装(门①patch + 门③注入 + 重签)。

---

## 0. 一句话结论

> **造成了。** 自研引擎在 `/tmp` 副本上,**门①纯静态特征码 byte-patch + 门③ 运行时 swizzle**,起的实例与 X1a0He(`/Applications`,同 bundleId `com.tencent.xinWeChat`)**2 个同-app 实例并存常驻**(`pgrep` 数=2,我方实例 pid 55903 存活 >3 分钟)。引擎 dylib 经 `@rpath` 随业务体加载,constructor 先于门③ swizzle 选择子;`perms.json` 正确写出。**完全替代抄 X1a0He —— 门①/门③/注入/重签/权限探针全是自己的代码。**
>
> 唯一不是"门"的拦路项是 **LaunchServices 按 CFBundleIdentifier 去重**:`open -n` 对同一 bundleId 不再 fork 而是把已注册实例提到前台。这与门①/门③无关(已实证引擎在第三个进程里完整跑过),要在"同一个 app bundle 自己叠开 N 个常驻实例"必须绕过 LS 去重(见 §4),务实落地仍是 **clone-bundle(改 CFBundleIdentifier)**。

---

## 1. 实测证据

### 1.1 两实例并存(铁证)
```
$ ps -ax -o pid,etime,rss,command | grep MacOS/WeChat | grep -v WeChatApp
25431   56:55  156848  /Applications/WeChat.app/Contents/MacOS/WeChat      ← X1a0He(已运行实例)
55903   03:06   83328  /private/tmp/wctest/WeChat.app/Contents/MacOS/WeChat ← 我方引擎实例
                                                                            ← 两者同为 com.tencent.xinWeChat
concurrent count = 2

$ # 区分:谁带我方引擎
pid 25431 -> WeChatMultiEngine 映射区: 0    ← X1a0He 不含我方引擎
pid 55903 -> WeChatMultiEngine 映射区: 4    ← 我方实例,引擎 dylib 完整 map(__TEXT/__DATA_CONST/__DATA/__LINKEDIT)
```
我方实例 55903 存活 **>3 分钟**(远超 30s 要求)。`vmmap` 证 `/tmp/wctest/.../wechat.dylib`(我方 patch 过的业务体)+ `WeChatMultiEngine.dylib` 都 map 进进程。

### 1.2 引擎 constructor 完整执行(第三个进程的实时日志)
直接 exec loader(无 LS 沙盒 bootstrap,故启动后期会退,但 constructor 全跑完):
```
WeChat[57497] [WeChatMultiEngine] loaded into pid=57497 (WeChat)
WeChat[57497] [WeChatMultiEngine] swizzled +[NSRunningApplication runningApplicationsWithBundleIdentifier:]
WeChat[57497] [WeChatMultiEngine] perms.json -> .../WeChatMulti/perms.json {screen:1, fda:0} write=1
```
→ 门③ swizzle **就位**(且发生在业务体单例检测之前),权限探针 **写盘成功**。我方 LS 实例 55903 之所以**不退**,正是因为这个 swizzle 让业务体的 `runningApplicationsWithBundleIdentifier:com.tencent.xinWeChat` 返回 `@[]`,查不到"已有实例"→ 不再 `exit(-1)`。

### 1.3 perms.json
路径(沙盒应用 → 落到**容器内**,GUI 必须读这里,见 §5):
```
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/WeChatMulti/perms.json
```
两种启动上下文实测两种真值(证明探针随 TCC 真实授权变化、不是写死):
| 启动方式 | screen | fda | 解释 |
|---|---|---|---|
| LS 沙盒实例 55903 | false | false | 该 adhoc 二进制无屏幕录制授权;沙盒挡 TCC.db 读 → 无 FDA |
| 终端 exec 实例 57497 | **true** | false | 继承终端的屏幕录制授权;仍无 FDA |
```json
{ "screen" : true, "fda" : false, "updated" : 1782312599.62, "pid" : 57497 }
```

---

## 2. 门① 特征码方案(不硬编码偏移)

`locate_gate1.py`:用 `lipo -detailed_info` 现取 arm64 slice 起点,在 slice 内扫特征码定位单例分支的 `cbz w0`,把它改成无条件 `b`(保留 imm 位移)。

**特征码(与具体偏移解耦):**
```
str w0, [sp, #0x70]      ; 字节 E0 73 00 B9   ← 单例检查函数把布尔返回值存栈
cbz w0, <relaunch+_exit> ; 32-bit CBZ Wt
```
即连续 8 字节 `E0 73 00 B9` + 一条 `cbz w0`。`cbz w0` 的判定(ARM64 CBZ 编码):
- 字节[3] == `0x34`(`bits[30:25]=0b011010`, bit31=0 → 32-bit, bit24=0 → CBZ 非 CBNZ)
- `Rt`(bits[4:0]) == 0 → w0

**patch:** CBZ 的 `imm19`(bits[23:5])转成无条件 B 的 `imm26`(bits[25:0]),指向同一目标:
```
b_word = (0b000101 << 26) | (sext(imm19) & 0x3FFFFFF)
```

**本 build 实测命中(唯一一处):**
```
ARM64_SLICE_OFF = 2850816 (0x2B8000)
GATE1_SLICE_OFF = 0x890f0
GATE1_FAT_OFF   = 0x3410f0
原字节 a0 0a 00 34 (cbz w0, 0x100089244)  →  patch 55 00 00 14 (b 0x100089244)
```
与 `layer2-verdict.md` §1 给的偏移 / 字节**完全一致**。特征码全程零硬编码偏移,GUI 复用安全。

> ⚠️ 脆弱点:特征码本身依赖"单例返回值存到 `[sp,#0x70]`"这个栈布局。若新 build 改了该局部变量栈偏移(`0x70`→别的),`E0 73 00 B9` 前 4 字节会变。降级方案见 §7。

---

## 3. 门③ 注入方案

`WeChatMultiEngine.dylib`(`__attribute__((constructor))`)做两件事:
1. **多开:** `method_setImplementation` 替换 `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]` 的 IMP。仅当 `bundleID == com.tencent.xinWeChat` 时返回 `@[]`(空数组),**其它 id 透传原 IMP**(绝不全局清空,不影响业务对其它 app 的查询)。这是方法实现级替换,无论调用方静态/动态/`sel_registerName` 拼选择子,最终 `objc_msgSend` 都落到换过的 IMP → 全覆盖(对应 `layer2-verdict.md` §4 的结论:swizzle 通、逐点 byte-patch 不通)。
2. **权限探针:** `CGPreflightScreenCaptureAccess()` 取屏幕录制授权;`fopen("/Library/Application Support/com.apple.TCC/TCC.db")` 试读判 FDA;结果写 `perms.json`。

**注入手段(`insert_dylib.py`):** 给 `Contents/Resources/wechat.dylib` 的每个 arch slice 追加一条 `LC_LOAD_DYLIB = @rpath/WeChatMultiEngine.dylib`(就地写在 load-commands 区尾部 padding,更新 `ncmds`/`sizeofcmds`;余量按"首个 section 文件偏移"校验)。dylib 放 `Contents/Frameworks/`,loader 自带 `@executable_path/../Frameworks` 的 `LC_RPATH` → `@rpath` 解析成 `Contents/Frameworks/WeChatMultiEngine.dylib`。业务体被 loader `dlopen` 时,dyld 顺着 LC_LOAD_DYLIB 把引擎一并 map 进来,constructor 在业务体单例检测前执行。实测 4 个 slice(x86_64/i386/armv7/arm64,后三是腾讯伪 cpusubtype 切片,实际都是 MH_MAGIC_64)全部成功注入,`ncmds 96→97`,Mach-O 仍合法。

---

## 4. LaunchServices 去重(非门,但拦"同 bundle 自叠开")

- `Info.plist` **无** `LSMultipleInstancesProhibited`,但 LS 仍按 `CFBundleIdentifier=com.tencent.xinWeChat` 去重:`open -n /tmp/wctest`、`open -n /tmp/wctest2`(另一路径副本)都**不 fork**,而是把已注册实例提前台 → 我方只能稳定起到 1 个常驻实例。
- 之所以测到 count=2,是因为 X1a0He(`/Applications`)是另一条已注册路径 —— 它和我方 `/tmp` 副本是 LS 眼里两个不同 app 注册项,故能并存。**这恰好满足"同-app 2 实例并存常驻"**(都 `com.tencent.xinWeChat`)。
- 直接 exec loader(绕过 LS)能起第三个进程、constructor + 门③ swizzle 全跑过,但缺 LS 的沙盒容器 bootstrap,业务体启动后期 abort → 不常驻。证明:**门①/门③ 已被引擎彻底中和;唯一挡"自己叠 N 开"的是 LS 去重**,与门无关。
- **务实落地(GUI):** 要稳定 N 开同一 app,绕 LS 去重的可靠路线 = **clone-bundle**:把副本 `CFBundleIdentifier` 改成 `com.tencent.xinWeChat.2` 等 → LS 视为不同 app,各自独立常驻;NSRunningApplication 单例也天然不触发(连门③ swizzle 都可省,但保留无害)。本引擎的门①patch + 注入 + 探针对 clone-bundle 完全复用。

---

## 5. 重签命令 & 签名坑

逐文件 adhoc,**不 `--deep`**,顺序:引擎 → 业务体 → loader → bundle:
```bash
# 1) 引擎 dylib
codesign --force --sign - Contents/Frameworks/WeChatMultiEngine.dylib
# 2) 业务体(header 被改,必须重签)
codesign --force --sign - Contents/Resources/wechat.dylib
# 3) loader(被 byte-patch;带 entitlements,必须保 app-sandbox)
codesign --force --sign - --entitlements ent.plist Contents/MacOS/WeChat
# 4) 整 bundle(密封资源;同一 entitlements;不 --deep)
codesign --force --sign - --entitlements ent.plist WeChat.app
```
**坑(均已踩实):**
- **必须保留 `com.apple.security.app-sandbox` entitlement** —— 去掉后 loader 早期(dlopen 业务体前)`main` 返回 -1 自退(`layer2-verdict.md` §5)。`install-self-engine.sh` 用 `codesign -d --entitlements` 从原 loader 提取整套 entitlements(含 app-sandbox / app-group / allow-jit / network 等)回灌;提取失败才用内置最小集兜底。
- **不要 `--deep`** —— 会递归重签嵌套的 `.framework`/`XPCServices`/`PlugIns`,破坏原厂团队签的密封,徒增风险。只重签被改的 3 个文件 + 顶层 bundle。
- **app-group 会被 REJECT 但非致命**:adhoc 抹掉 team,containermanagerd 拒绝 TCC-strict 的 group container 访问,但实例照常常驻(`layer2-verdict.md` §5)。
- **quarantine → AppTranslocation 坑**:Safari 下载的 DMG 带 `com.apple.quarantine`,首次 `open` 会被 Gatekeeper 搬到只读 `AppTranslocation` 随机路径运行,@rpath 仍解析但路径乱、不稳。安装后 GUI 应 `xattr -dr com.apple.quarantine <app>`(adhoc 签名不受 xattr 移除影响,实测 `codesign --verify` 仍 PASS),避免 translocation。
- 最终 `codesign --verify --verbose=2 WeChat.app` → **`valid on disk` + `satisfies its Designated Requirement`** ✓。

---

## 6. 安全 / 结束态

| 检查项 | 期望 | 实测 |
|---|---|---|
| 全程未写 `/Applications/WeChat.app` | 是 | 是(仅 `open`/只读;patch/签名/launch 全在 `/tmp/wctest`、`/tmp/wctest2`、`/tmp/wcdmg` 只读挂载) |
| 干净 build 来源 | DMG | `~/Downloads/WeChatMac.dmg` 只读挂载到 `/tmp/wcdmg`,`ditto` 出副本 |
| X1a0He 实例 | 1 个干净 | 1(pid 25431 全程未受扰,无我方引擎注入) |

**测后清理(由调用方执行):** 退测试进程 `pkill -f /tmp/wctest`、卸载 DMG `hdiutil detach /tmp/wcdmg`、删 `/tmp/wctest /tmp/wctest2 /tmp/body_test.dylib /tmp/wcm_*`。adhoc 重签**未往钥匙串装任何测试证书**(全程 `--sign -` adhoc,无自签证书),故无证书可删。

---

## 7. 版本脆弱性

| 项 | 依赖 | 新 build 失效条件 | 降级方案 |
|---|---|---|---|
| 门① 特征码 | loader 单例返回值存 `[sp,#0x70]` + 紧跟 `cbz w0` | 栈偏移 `0x70` 变 / 编译器换分支形态(如 `tbz`) | 放宽到"扫所有 `cbz w0`,回溯前一条是否 `bl <调 mach_port_allocate 的函数>`";或 `lldb` 断 `_mach_port_allocate` 回溯调用栈定位 |
| 门③ swizzle | `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]` 仍是单例判据 | 腾讯换用别的 API(如自管 mach 端口锁) | swizzle 是选择子级,只要还用这个系统选择子就有效;换了得重新逆 |
| LC_LOAD_DYLIB 注入 | 业务体 header 有 padding 余量 | 余量耗尽(罕见) | 改用 `__LINKEDIT` 扩展法或重排 load commands |
| @rpath 解析 | loader 含 `@executable_path/../Frameworks` RPATH | 该 RPATH 被删 | 注入名改 `@loader_path/../Frameworks/...`(脚本已留 WARN 检测) |

**通用安装流程对 build 的依赖已最小化:** 偏移全部运行时现取(`lipo` + 特征码),无任何写死的 fat / slice 偏移。

---

## 8. 对接 GUI 的接口

**安装(GUI 复用):**
```bash
engine/install-self-engine.sh /path/to/WeChat.app副本
```
幂等(门①/门③ 已装会跳过)、自校验原字节、自提取 entitlements、自重签。`exit 0` = 成功。安装后 GUI 应 `xattr -dr com.apple.quarantine <app>` 防 translocation。

**门①单独定位(GUI 想自己 patch):**
```bash
python3 engine/locate_gate1.py /path/to/MacOS/WeChat
# 输出 KEY=VALUE: ARM64_SLICE_OFF / GATE1_FAT_OFF / GATE1_ORIG_LE / GATE1_PATCH_LE …
```

**权限读取(GUI 显示授权状态):** 读 **沙盒容器内** 路径(非 `~/Library/Application Support`):
```
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/WeChatMulti/perms.json
# { "screen": bool, "fda": bool, "pid": int, "updated": unixtime }
```
引擎每次启动异步刷新该文件。GUI 据此提示用户去"系统设置 → 隐私与安全性"补授权。

**多实例落地建议:** 同-bundle 叠开受 LS 去重限制(§4);GUI 要 N 开请用 **clone-bundle**(改副本 `CFBundleIdentifier`,本引擎全套复用),每个 clone 独立常驻、独立容器、门③天然不触发。
