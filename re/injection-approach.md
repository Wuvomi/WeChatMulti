# 微信 4.1.11 多开方案评估 + X1a0He 逆向

分析对象:`X1a0HeWeChatPlugin` v2.4.7（dylib `/tmp/X1a0HeWeChatPlugin/X1a0HeWeChatPlugin.dylib`，4.4MB arm64；pkg 同目录，已展开到 `/tmp/x1a0he_pkg`）。目标微信 `/Applications/WeChat.app`，版本 4.1.11.21，**只读**。

---

## 0. 关键纠正:微信 4.1.11 的二进制布局

Gemini 的前提里有个事实错误,先纠正,后面的可行性评估都依赖它:

| 文件 | 大小 | 角色 |
|------|------|------|
| `Contents/MacOS/WeChat` | 5.6 MB | 启动 loader(明文 Mach-O,但**不是**业务入口) |
| `Contents/Resources/wechat.dylib` | **320 MB**(fat: x86_64 + arm64) | **真正的业务主体**,明文 Mach-O DYLIB,98 条 load command |
| `Contents/Frameworks/WCDY.framework` | — | 存在,但不是主业务载体 |
| `Contents/Frameworks/wechat.dylib` | 84 KB | 另一个小 stub(同名,别混淆) |

要点:
- `MacOS/WeChat` 通过 **dlopen 字符串**(不是 LC_LOAD_DYLIB)加载 `Resources/wechat.dylib`(在主程序里能搜到 `wechat.dylib` 字符串,但 `otool -l` 里没有指向它的 LC_LOAD_DYLIB)。
- `Resources/wechat.dylib` 是**明文**的(`otool -hv` 直接能读头、能 `nm`),不是"运行时解密进内存"。Gemini 说的"WCDY 加密、loader 解密进内存"这个模型,对 4.1.11 不成立——业务代码就躺在磁盘上明文可读。这一点直接改变了整个方案的难度。
- 主程序与 `Resources/wechat.dylib` 都启用了 **hardened runtime**(codesign `flags=0x10000(runtime)`),签名者 `Developer ID Application: Tencent Mobile International Limited (5A4RE8SF68)`。
- WeChat 的 entitlements 里有 `com.apple.security.cs.allow-jit`,但**没有** `com.apple.security.cs.disable-library-validation`。所以默认情况下不能注入非 Tencent 团队签名的 dylib——必须破掉 library validation(见 §3)。

---

## 1. Gemini 方案逐步可行性评估

### 步骤 1:写 Tweak.dylib,hook dlopen/bundle load,等解密进内存后改多开判定
- **现实部分**:注入一个 constructor dylib 到微信进程是完全可行的(X1a0He 就是这么干的)。
- **坑**:
  - "hook dlopen 等 WCDY 解密"这个前提对 4.1.11 是多余的——业务代码在 `Resources/wechat.dylib` 里就是明文,**不需要等解密**,直接把自己的 dylib 插进去,加载时机由 dyld 保证(见 §2 X1a0He 的做法)。
  - "在内存里找到并改多开判定"——这是真正的难点,且 Gemini 没说清"判定"长什么样。微信 Mac 端的多开/单例判定是 **C++**(在 `wechat.dylib` 里),不是 ObjC 选择子,所以"hook 选择子返回 YES"这种 ObjC swizzle 思路对核心判定不一定够,可能需要 inline hook(Dobby)。这正是 X1a0He 同时带了 Dobby 的原因。

### 步骤 2:insert_dylib / optool 给 loader 的 Mach-O 头插 LC_LOAD_DYLIB
- **现实部分**:insert_dylib 加 LC_LOAD_DYLIB 是标准操作,可行。
- **坑**:
  - **插错文件**。Gemini 说插 `MacOS/WeChat`(loader)。X1a0He 实测插的是 **`Contents/Resources/wechat.dylib`**(业务主体),不是 loader。插业务主体更靠谱,因为:(a) 你的 dylib 和 ObjC/C++ runtime、目标符号在同一加载链里;(b) loader 太薄、你的 hook 目标(WeChat 类/函数)在 loader 加载时还没就位。
  - insert_dylib(Tyilo 版,pkg 里就带的这个)默认会 **strip 掉 LC_CODE_SIGNATURE**(它有 `strip-codesig`/`no-strip-codesig` 开关,默认 strip),所以插完**必须重签**,否则 dyld 直接拒载。

### 步骤 3:ad-hoc 重签 loader + dylib,移除 library validation
- **现实部分**:ad-hoc 重签(`codesign -f -s -`)是破 library validation 的标准手段——ad-hoc 签名不带 team ID,LV 就不再要求"被加载 dylib 的 team ID == 主程序 team ID"。
- **坑**:
  - 重签会**抹掉 Tencent 原签名**。任何依赖原签名/公证的东西(部分网络握手、Sparkle 更新校验、Tencent 自己的完整性自检如果有的话)可能受影响。X1a0He 用 `--preserve-metadata=entitlements` 保留 entitlements 来缓解。
  - 必须**自底向上重签**:先签插件 dylib → 再签被注入的 `wechat.dylib` → 最后签整个 `.app`(嵌套代码改了,外层封签必须重做,否则 `codesign --verify` 失败、Gatekeeper 拦)。X1a0He 的 postinstall 正是这个顺序。
  - hardened runtime 本身不阻止"ad-hoc 重签后加载 ad-hoc dylib"。真正卡你的是 library validation,ad-hoc 重签即可绕过,**不需要**额外加 `disable-library-validation` entitlement(X1a0He 没加)。
  - SIP 不影响(`/Applications` 不在 SIP 保护路径)。需要 sudo 改 `/Applications/WeChat.app`。

**结论**:Gemini 的三步框架方向对,但 (a) 把"解密进内存"想复杂了,业务是明文;(b) 注入目标应是 `Resources/wechat.dylib` 而非 loader;(c) "改多开判定"这一步是真难点,核心判定在 C++,需要 inline hook 能力。

---

## 2. X1a0He 到底怎么做的

### 2.1 注入手法(postinstall + insert_dylib)

postinstall 脚本(`/tmp/x1a0he_pkg/X1a0HeWeChatPlugin_component.pkg/Scripts/postinstall`)完整流程:

```
WECHAT_PATH=/Applications/WeChat.app           # 或 /Applications/微信.app
APP_NAME=wechat.dylib
WECHAT_EXECUTABLE_PATH=$WECHAT_PATH/Contents/Resources/wechat.dylib      # ← 注入目标
PLUGIN_INSTALL_PATH=$WECHAT_PATH/Contents/Frameworks/X1a0HeWeChatPlugin.dylib
```

步骤:
1. 检查微信没在跑(`pgrep -xq WeChat`),读版本号。
2. **备份**:首次安装把 `Resources/wechat.dylib` 复制成 `wechat.dylib.original`(卸载/重装靠它还原)。重装时先从 `.original` 还原干净副本,再操作。
3. **拷贝插件**:把 `X1a0HeWeChatPlugin.dylib` 复制到 `Contents/Frameworks/X1a0HeWeChatPlugin.dylib`。
4. **注入**:
   ```
   insert_dylib  $PLUGIN_INSTALL_PATH  $WECHAT_EXECUTABLE_PATH  $WECHAT_EXECUTABLE_PATH
   ```
   即给 `Resources/wechat.dylib` 插一条 LC_LOAD_DYLIB。插件 dylib 的 `LC_ID_DYLIB` 是 **`@rpath/X1a0HeWeChatPlugin.dylib`**,而 `MacOS/WeChat` 带 `LC_RPATH = @executable_path/../Frameworks`,所以 `@rpath/...` 正好解析到 `Contents/Frameworks/X1a0HeWeChatPlugin.dylib`——拷贝路径和 rpath 解析路径对得上。
   - 这里用的 `insert_dylib` 是 **Tyilo 的开源 insert_dylib**(strings 里有 `Usage: insert_dylib dylib_path binary_path [new_binary_path]`、`strip-codesig`、`LC_LOAD_WEAK_DYLIB`)。**没用 optool**。默认会 strip 掉 LINKEDIT 末尾的 LC_CODE_SIGNATURE,所以下一步必须重签。
5. **重签(自底向上,全 ad-hoc)**:
   ```
   codesign -f -s - --all-architectures   Frameworks/X1a0HeWeChatPlugin.dylib
   codesign -f -s - --all-architectures   Resources/wechat.dylib
   codesign -f -s - --preserve-metadata=entitlements   /Applications/WeChat.app
   ```
   - `-s -` = ad-hoc → 抹掉 team ID → library validation 不再要求 team 匹配 → 自签 dylib 能被加载。
   - 最外层 `.app` 用 `--preserve-metadata=entitlements` 保住原 entitlements(`allow-jit` 等)。
6. 重装时还会清理用户域里的旧配置:`defaults delete com.tencent.xinWeChat X1a0HeWeChatPlugin_*`(说明插件配置存在微信自己的 prefs domain `com.tencent.xinWeChat`,key 前缀 `X1a0HeWeChatPlugin_`)。

pkg 元信息:`Distribution` 限定 `hostArchitectures="arm64"`、`customize="never"`;`PackageInfo` 用 `postinstall` 脚本,`auth="root"`(需管理员)。

**加载链总结**:`MacOS/WeChat`(dlopen)→ `Resources/wechat.dylib`(被插了 LC_LOAD_DYLIB)→ dyld 自动加载 `@rpath/X1a0HeWeChatPlugin.dylib` → 插件 constructor 跑起来。插件和 WeChat 业务 C++/ObjC 在同一进程同一加载链里,可以直接 swizzle/inline-hook。

### 2.2 hook 工具箱(dylib 内部)

`otool -L` 显示插件**只链系统库**(Foundation/AppKit/IOKit/Security/CloudKit/libobjc/libc++),没有外链 fishhook/Dobby/CydiaSubstrate。但符号表说明它**静态打包**了两套 hook 能力:

- **Dobby(inline hook,静态链入)**:导出符号里有 `_DobbyHook`、`_DobbyCodePatch`、`_DobbySymbolResolver`。`_DobbySymbolResolver` 在 `func.0x5aed0` 里被调用——这是"按符号名在某模块里解析地址 → 用 `_DobbyHook` 做 ARM64 inline hook"的典型用法。**用来 hook `wechat.dylib` 里的 C++ 函数**(C++ 判定没有 ObjC 选择子可 swizzle,只能 inline hook)。
- **ObjC runtime swizzle**:imports 里有 `_method_exchangeImplementations`(用在 `func.0x62934`)、`_class_replaceMethod`(`func.0x63524`)、`_method_setImplementation`(`func.0x60170`)、`_class_getInstanceMethod`、`_class_addMethod`、`_method_getImplementation` 等。**用来 hook ObjC 选择子**(UI 类、Sparkle `checkForUpdates`/`checkForUpdatesWithManualCheck:` 等)。
- 注:**没有 fishhook / `rebind_symbols` / MSHookFunction**。重绑定路线它没走;走的是 Dobby(C++)+ ObjC swizzle(选择子)双轨。

插件本体是 **Swift 写的**(类名:`WeChatPlugin`、`WeChatPluginConfig`、`WeChatPluginMenu*`、一堆自定义 NSView 子类如 `RoundedCardView`/`PillButton`;还静态打包了 zstd/sqlcipher 等)。

### 2.3 多开具体 hook 点

诚实说明:dylib 里插件自己的 Swift 字符串是**运行时解密/混淆**的(`func.0x62934` 等用"32-bit 哈希常量 switch"分发配置 key,字符串不以明文存在 `__cstring`),所以**没法静态抓到那条多开判定函数的明文符号名**。能确定的:

- `__objc_methname` 里有插件自己的配置 getter **`isMultipleInstanceEnabled`**、`hookLongLongForKey:`,以及 `setBool:forKey:`/`boolForKey:` 配 `com.tencent.xinWeChat` 域 → 多开是一个**可开关的配置项**(README 也确认"允许微信多开 ⚠️请慎用",change-log 说默认关闭)。这些是插件的**配置层**,不是 WeChat 的判定函数。
- 真正的多开实现走 **Dobby inline hook**:`func.0x5aed0` 用 `_DobbySymbolResolver` 在 `wechat.dylib` 里按名解析一个 C++ 符号,再 `_DobbyHook` 替换。被 hook 的符号名是运行时拼出来的(混淆),静态读不到明文。从架构上判断,hook 的是微信启动时那个"检测已有实例/单例 guard"的 C++ 函数,改其返回值/绕过其 `exit`/`terminate` 路径,从而允许第二个实例继续启动。
- `__objc_methname` 里还出现 `setLaunchPath:`/`launch`/`isRunning`/`terminationStatus`(NSTask 一套)+ `NSWorkspace` 引用 → 插件具备"用新进程再拉起一个微信"的能力,配合 inline hook 绕过单例 guard,即"点一下多开一个实例"。

> 想拿到那条 C++ 符号的明文,需要**动态**:在 lldb 里给 `_DobbyHook`/`_DobbySymbolResolver` 下断,跑起来读它第一个参数(目标地址/符号名)。本次只读静态分析到此,符号名本身被混淆,未落地到具体 mangled name。

### 2.4 怎么处理 hardened runtime / library validation

- **不靠 entitlement**:插件不要求 `disable-library-validation`。
- **靠 ad-hoc 重签**:postinstall 把 `Frameworks/X1a0HeWeChatPlugin.dylib` + `Resources/wechat.dylib` + 整个 `.app` 全部 `codesign -f -s -`(ad-hoc)。ad-hoc 签名不带 team ID,library validation 退化为"只要签名有效即可",自签 dylib 因此能被加载。hardened runtime 标志在重签后仍在(无所谓,它本身不拦 ad-hoc dylib)。
- **保 entitlements**:最外层 `.app` 用 `--preserve-metadata=entitlements`,避免丢掉 `allow-jit` 等导致功能异常。
- **SIP/Gatekeeper**:`/Applications` 不受 SIP;重签后本机 Gatekeeper 对本地修改的 ad-hoc 包通常放行(已安装应用、非隔离)。pkg 用 root 权限运行 postinstall。

---

## 3. 自研等价 Tweak.dylib 的可行路线 + 难点

### 路线(照抄 X1a0He 即可跑通)
1. **写 constructor dylib**(Swift 或 ObjC/C 均可),`__attribute__((constructor))` 或 `__init_offsets` 入口。`LC_ID_DYLIB` 设成 `@rpath/MyTweak.dylib`。
2. **拿到 Dobby**:编译 [Dobby](https://github.com/jmpews/Dobby) 静态库链进来(arm64 macOS)。用于 inline hook `wechat.dylib` 里的 C++ 单例判定。
3. **定位多开判定函数**(核心难点,见下):在 `Resources/wechat.dylib`(明文)里找单例/已存在实例检查的 C++ 函数,记其符号名或相对地址。
4. **hook**:`DobbySymbolResolver("wechat.dylib", "<mangled symbol>")` → `DobbyHook` 让它返回"无已存在实例"/不 `exit`。或者直接 inline patch 掉那个 `exit`/`NSRunningApplication` 检查分支。ObjC 层面顺手 swizzle 掉任何弹"已在运行"提示的选择子。
5. **安装**:`insert_dylib @rpath/MyTweak.dylib Resources/wechat.dylib`(就地)→ 拷贝 dylib 到 `Contents/Frameworks/` → 自底向上 ad-hoc 重签三件套(dylib → wechat.dylib → .app,`.app` 带 `--preserve-metadata=entitlements`)。先备份 `wechat.dylib.original`。

### 难点
1. **找判定函数(最大难点)**。X1a0He 把符号名混淆了,抄不到现成名字。自己得在明文 `Resources/wechat.dylib`(320MB)里逆向定位:
   - 思路:搜 `NSRunningApplication`/`runningApplicationsWithBundleIdentifier`、`com.tencent.xinWeChat` bundle id 比对、`pthread_kill`/`exit`/`abort` 附近的"已运行"分支,或 lldb 动态断在 `exit`/启动早期看调用栈。
   - 或者最省力:lldb attach 到**已装好 X1a0He 的**微信,断 `_DobbyHook`,直接读出它 hook 的目标地址 → 反查 `wechat.dylib` 里对应函数 → 抄符号/偏移。(这是逆向 X1a0He 多开点最快的路子,本次静态没做。)
2. **arm64e/PAC 与 inline hook 稳定性**。Dobby 要正确处理 ARM64 指令重定位;hook 大函数开头若有 PC 相关指令需谨慎。
3. **版本脆弱**。按地址/偏移 hook 强依赖 4.1.11.21 这个确切版本;微信一更新,符号/偏移就变,得重做(X1a0He 每版发新 dylib 正是这原因)。按符号名 hook 稍稳,但符号也可能被改。
4. **重签副作用**。抹掉 Tencent 签名后,若微信有自校验或公证依赖,可能触发异常(目前 X1a0He 能用,说明 4.1.11 暂时没强自检,但不保证)。
5. **`.app` 整体重签耗时**:`wechat.dylib` 320MB,`codesign` 全量 hash 慢(几秒~十几秒),pkg timeout 设了 600s。
6. **同一份用户数据目录**:多开通常还需让第二实例用**不同的数据目录/账号沙盒**,否则两个实例抢同一 SQLite/文件锁会冲突。X1a0He 是否处理了数据目录隔离,本次未确认——自研时这点要单独验证(可能还需 hook 沙盒/数据路径选择函数,或起进程时改环境/参数)。

---

## 附:关键文件路径
- 插件 dylib:`/tmp/X1a0HeWeChatPlugin/X1a0HeWeChatPlugin.dylib`(arm64,4.4MB,Swift + 静态 Dobby/zstd/sqlcipher)
- postinstall:`/tmp/x1a0he_pkg/X1a0HeWeChatPlugin_component.pkg/Scripts/postinstall`
- 注入工具:`/tmp/x1a0he_pkg/X1a0HeWeChatPlugin_component.pkg/Scripts/insert_dylib`(Tyilo insert_dylib,x86_64+arm64 fat)
- 注入目标(微信):`/Applications/WeChat.app/Contents/Resources/wechat.dylib`(320MB 明文业务主体)
- 注入产物落点:`/Applications/WeChat.app/Contents/Frameworks/X1a0HeWeChatPlugin.dylib`(经 `@rpath` 解析)
- 备份:`/Applications/WeChat.app/Contents/Resources/wechat.dylib.original`
- 配置存储:`defaults` 域 `com.tencent.xinWeChat`,key 前缀 `X1a0HeWeChatPlugin_`
