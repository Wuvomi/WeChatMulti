<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# 我在研究 macOS 微信 4.1.x 版本（如 4.1.10/4.1.11）的静态二进制修改（static byte-patch），遇到了一个技术卡点，想搜索有没有人遇到过同样的问题并找到解决方案。

背景信息：

1. 微信 4.x 的架构变了：主程序 Contents/MacOS/WeChat 变成了一个很小的 loader（加载器），真正的业务逻辑在 Contents/Resources/wechat.dylib（或类似命名的核心动态库）里。
2. 微信的多开限制有三层门：
    - 第①层：loader 里的 mach bootstrap 单例锁（可以静态 patch，比如把 cbz 改成无条件跳转）
    - 第②层：loader 对业务体（wechat.dylib）的校验（这是我卡住的地方）
    - 第③层：业务体里的 NSRunningApplication 单例检查（可以静态 patch）

问题描述：

- 我静态 patch 了第①层的 mach 单例锁（修改主程序二进制）
- 然后用 ad-hoc 重签整个 App（codesign --force --deep --sign -）
- 重签后启动微信，loader 进程会干净地退出（_exit(0)），根本不加载 wechat.dylib 业务体
- 推测是 loader 有某种校验机制：检查业务体的签名/完整性/是否被篡改，发现不是腾讯的原始签名就拒绝加载
- 这导致纯静态 patch 方案无法实现多开——因为你改了 loader 就必须重签，一重签第②层校验就通不过

我想找的信息：

1. 有没有其他逆向工程师讨论过微信 4.x 的这种 loader + 业务体架构？
2. 有没有人遇到过"重签后 loader 不加载业务体"的问题？
3. 有没有已知的绕过方法？比如：
    - 能不能只 patch 业务体而不碰 loader？
    - 能不能找到 loader 里的校验函数并一起 patch 掉？
    - 有没有特殊的重签名参数可以保留腾讯签名的某些部分？
    - 或者有没有办法在不重签的情况下做静态修改？
4. X1a0He（微信 4.x 的多开插件）是怎么绕过这个问题的？它用的是动态注入所以不需要改二进制？还是有其他技巧？

请搜索逆向工程论坛、GitHub 项目、技术博客、看雪/吾爱破解等中文逆向社区，以及英文的逆向/安全社区的相关讨论。

根据搜索结果，我现在可以给出一个详尽的技术分析。X1a0He 的插件明确声明**不支持 4.x 版本**，说明它用的注入方案在 4.x 架构变更后已失效。以下是对你问题的完整分析。

***

## 微信 4.x Loader + 业务体架构分析

微信 4.0 之后对 macOS 端进行了架构重组，主程序变成了一个轻量 loader，真正的业务逻辑被移入 `wechat.dylib` 这个核心动态库。 X1a0He 的插件（最新版 1.0.3，2025年1月）在 README 中**明确注明：❌ 不支持 4.x，也不会支持 4.x**，它只支持 3.8.9 / 3.8.10，说明其动态注入方案已被这层新架构挡住。[^1]

***

## 三层防多开门的技术本质

### 第①层：Mach Bootstrap 单例锁

这层在 loader 里通过 `mach_bootstrap` 注册命名服务实现单例检查。你已经可以通过把条件跳转（如 `cbz`）改成无条件跳转来 patch。 Windows 版的类似机制用的是 `CreateMutexW` + 命名互斥体 `_WeChat_App_Instance_Identity_Mutex_Name`，通过 `GetLastError` 返回 `183`（`ERROR_ALREADY_EXISTS`）来检测。 macOS 端的 Mach bootstrap 单例逻辑同理——检测到服务名已注册则 `_exit(0)`。[^2]

### 第②层：Loader 对业务体的完整性校验（你卡住的地方）

这是 4.x 架构的核心反篡改机制。根据现有逆向社区信息，可以推断 loader 在加载 `wechat.dylib` 之前会做以下校验之一（或组合）：

- **CS（Code Signing）Page Hash 校验**：loader 会读取 `wechat.dylib` 的 `LC_CODE_SIGNATURE` load command，验证每个代码页的 SHA256 哈希是否与嵌入的签名匹配。Ad-hoc 重签（`--sign -`）会重新生成哈希，但它的 signing identity 是临时的，loader 可能硬编码要求 TeamID（腾讯的 `8VD56APP7F`）。
- **TeamID 白名单**：loader 通过 `SecCodeCopySigningInformation` 或直接读取 `__LINKEDIT` 段的 CMS blob，提取 `wechat.dylib` 的 TeamID，如果不是腾讯的则拒绝。Ad-hoc 签名的 TeamID 是空或 `-`，因此无法通过。
- **Hardened Runtime + Library Validation**：Apple 的 Hardened Runtime 有 Library Validation 选项，开启后 dylib 必须与主程序有相同的 TeamID 或是苹果平台库。 腾讯很可能开启了这个 entitlement，这样即使不是 loader 自己校验，系统 dyld 也会拒绝加载被篡改的 dylib。[^3]

重签 loader 用 `--sign -` 后，loader 的 TeamID 也变成了 ad-hoc，但系统仍会因 `wechat.dylib` 签名不一致而拒绝，loader 感知到 dylib 加载失败就直接 `_exit(0)`。[^4]

### 第③层：NSRunningApplication 单例检查

业务体 `wechat.dylib` 里用 `[NSRunningApplication runningApplicationsWithBundleIdentifier:]` 检查是否已有同 Bundle ID 的进程运行。 这层可以通过 patch `wechat.dylib` 里的条件跳转绕过，但前提是你能先过第②层。[^5]

***

## 已知绕过方案与思路

| 方案 | 可行性 | 关键原理 |
| :-- | :-- | :-- |
| 只 patch `wechat.dylib`，不改 loader | ⚠️ 部分可行 | 绕过第③层无需触碰 loader；但 loader 校验 dylib 签名，改了 dylib 也得重签 dylib，同样触发第②层 |
| 找到 loader 里的校验函数一起 patch | ✅ 理论可行 | 用 Hopper/IDA 定位校验函数（搜索 `SecCodeCopySigningInformation`、`teamID`、`8VD56APP7F` 等字符串），NOP 掉校验跳转；但改 loader 之后仍需重签 loader，需要同时 patch 掉 loader 内所有校验逻辑才能让整条链成立 |
| 不重签，用 `DYLD_INSERT_LIBRARIES` 运行时注入 | ✅ 主流工具方案 | 不修改任何二进制，不破坏任何签名；通过环境变量或 `insert_dylib` 在运行时注入钩子 dylib，hook `NSRunningApplication` 相关方法 [^6] |
| 修改 Bundle ID 克隆第二个 App 副本 | ✅ V2EX 上有人验证可行 | 复制 WeChat.app 改 `CFBundleIdentifier`，再 ad-hoc 重签；两个不同 Bundle ID 的应用在第③层互不干扰 [^5] |
| 保留腾讯签名的二进制修改 | ❌ 不可行 | macOS 代码签名一旦修改字节就失效，无法在保留有效腾讯签名的同时修改二进制内容，除非有腾讯私钥 |


***

## 最可行的突破路径

**方向一（推荐）：只攻第②层——在 loader 里找校验逻辑并 patch 掉**

用 Hopper Disassembler 打开 loader，搜索以下特征：

```
字符串：8VD56APP7F（腾讯 TeamID）
函数：SecCodeCopySigningInformation
函数：SecStaticCodeCheckValidity
字符串：teamID / com.tencent
```

找到校验函数后，把校验失败分支的跳转 NOP 掉或改为无条件跳转到"校验成功"分支。这样你改了 loader 并重签后，loader 就不再拒绝 ad-hoc 签名的 `wechat.dylib`。

**方向二（最低风险）：运行时注入，完全不碰静态二进制**

用 `DYLD_INSERT_LIBRARIES` 或 `insert_dylib` 注入一个自定义 dylib，在进程启动时 hook：

- `mach_bootstrap` 相关调用（第①层）
- `NSRunningApplication` 相关调用（第③层）

但这同样面临 SIP 和 Hardened Runtime 的限制，需要先关闭 SIP（`csrutil disable`）或对注入的 dylib 进行恰当签名，并配合 `com.apple.security.cs.disable-library-validation` entitlement。[^3]

**方向三：Bundle ID 克隆方案（最简单，已有人验证）**

V2EX 上有人在 4.1.x 上验证了通过复制 App 包、修改 `CFBundleIdentifier` + ad-hoc 重签实现双开，绕过了第③层的 Bundle ID 检测。 这个方案不需要修改任何业务逻辑，代价是两个实例共享同一个微信数据目录路径，需要额外处理数据隔离。[^5]

***

## 关于 X1a0He 插件的架构

X1a0He 的插件用的是**纯 Shell 脚本 + 运行时动态注入**方案（仓库 100% Shell），安装脚本 `install.sh` 将插件 dylib 注入到 WeChat.app 的 Mach-O load commands 里，并重签整个 App。 这个方案在 3.8.x 的单体架构下有效，因为当时 loader 和业务体是一体的，重签一次就够了。4.x 的 loader + dylib 分离架构使得这套流程在第②层直接失效，这也是该插件作者明确放弃支持 4.x 的原因。[^1]
<span style="display:none">[^10][^11][^12][^13][^14][^15][^16][^17][^18][^19][^20][^21][^22][^23][^24][^25][^26][^27][^28][^7][^8][^9]</span>

<div align="center">⁂</div>

[^1]: https://github.com/X1a0He/X1a0HeWeChatPlugin

[^2]: https://www.kn0sky.com/?p=53495e9e-1f6e-4439-aed6-2561887af85a

[^3]: https://stackoverflow.com/questions/59214424/macos-homebrew-dylib-formula-all-hit-code-sign-errors

[^4]: https://ask.csdn.net/questions/8954771

[^5]: https://www.v2ex.com/t/1199073

[^6]: https://blog.csdn.net/gitblog_00786/article/details/151603277

[^7]: https://github.com/ttttupup/wxhelper

[^8]: https://blog.csdn.net/m0_61634551/article/details/129474450

[^9]: https://mac.weixin.qq.com

[^10]: https://cloud.tencent.com/developer/article/2521757

[^11]: https://ask.csdn.net/questions/9082471

[^12]: https://blog.csdn.net/qq_48514193/article/details/130338812

[^13]: https://www.cnblogs.com/xuzeyu/p/9318340.html

[^14]: https://www.pd521.com/thread-1634-1-1.html

[^15]: https://cloud.tencent.com/developer/article/1917709

[^16]: https://blog.csdn.net/gitblog_00112/article/details/151602864

[^17]: https://github.com/izj007/wechat

[^18]: https://blog.csdn.net/wangxiaoertedaye/article/details/83507145

[^19]: https://www.youtube.com/watch?v=DxlyQ_BwFQk

[^20]: https://stackoverflow.com/questions/79508043/how-to-notarize-a-c-sharp-dynamic-library-dylib-in-macos

[^21]: https://juejin.cn/post/6844904035783458829

[^22]: https://v2ex.com/t/1161108

[^23]: https://tao1010.github.io/2018/06/08/iOS/iOS逆向/iOS逆向-实战-微信红包和步数/

[^24]: https://libraries.io/go/github.com%2F0xd219b%2Fwechat-cli

[^25]: https://juejin.cn/post/6844903465299214349

[^26]: https://developer.apple.com/library/archive/technotes/tn2206/_index.html

[^27]: https://blog.csdn.net/yemeishu6033022/article/details/81229935

[^28]: https://developer.apple.com/forums/thread/115451

