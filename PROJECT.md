# WeChatMulti — 项目进度与决策日志

> 这是项目的**唯一权威进度文件**。换对话、换设备、隔很久回来时，先读这里恢复上下文。
> 每次有进展/决策/踩坑，都追加到对应章节，并更新顶部「当前状态」。
> 写明**为什么**做某个决定，而不只是做了什么 —— 半年后的自己会感谢现在的你。

---

## 用户真实诉求澄清（2026-06-24，重要）
- 用户要的不是「侵略性小」，而是 **稳定 + 低熵**。
- 反对克隆 .app 的理由：会产生多个副本、各自版本漂移、变量多、熵高。
- → 这**强化**注入路线：单一 App、单一版本 = 最低熵。克隆 = 高熵，排除。
- **新硬约束**：数据容器 **45GB**，磁盘仅剩 **23GB** → **无法在本机完整备份聊天记录**。换版本（App Store→官网）是唯一可能动到这 45G 的环节，与"稳定"正面冲突，需先解决备份/迁移风险。
- 关键待确认：官网版 4.x 是否用**同一容器路径** `~/Library/Containers/com.tencent.xinWeChat/`（是则数据不搬动、覆盖.app后重登即可接上，风险大降）。

## 迁移与备份现状（2026-06-24，进行中）
- **数据路径隔离（关键，已修正认知）**：App Store 沙盒版数据在 `~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/`；官网非沙盒版用**独立路径**（待实测，pplx 称 `~/Library/Application Support/WeChat/`）。→ 覆盖 .app 后官网版会显示**空白聊天列表（逻辑丢失）**，**迁移是必做项**，非"万一"。
- **备份已完成**：聊天数据库已备份到 NAS `/Volumes/will/wechat-db-backup-2026-06-24.tar.zst`（418MB，6433 文件，zstd 完整性校验通过）。源沙盒数据未删，数据现存两处。
- 全量 45G 备份放弃（NAS 写入仅 ~27MB/s，需 ~24min，超时）。45G 大头是可重下的图片/视频缓存。
- **下一步（用户已决定直接覆盖）**：用户覆盖官网版 DMG → 登录 → 若聊天为空 → 迁移。
- **迁移计划**：① 装好后实测官网版真实数据路径；② 把沙盒目录的 Message/Contact/Group/Favorites 等 DB 迁到官网路径。⚠️风险：DB 可能加密/不同版本 schema 不兼容，迁移未必一键成功，但源数据+备份齐全，有试错空间。

## 🎉 多开已跑通（2026-06-24）
- **现状:屏幕上同时运行 2 个微信实例,核心目标达成。**
- 方案:官网 4.1.5(build 32288 支持版)+ `wechattweak patch` 原地注入。单一 App、无额外 .app = 低熵/稳定（符合用户诉求）。
- 验证:multiInstance 补丁字节 `20008052c0035fd6` 已就位;`open -n` 实测进程数 1→2。
- 附带:patch 同时打了"阻止自动更新"(6 个 update 函数 return 0)→ 版本被锁,多开补丁不会被自升级冲掉。
- 回滚物:`/tmp/WeChat_4.1.10_backup.app`、`/tmp/WeChatMac_4.1.5.dmg`。
- 复现命令:装 `WeChatMac_4.1.5.dmg`(32288) → `wechattweak patch` → 启动后 `open -n /Applications/WeChat.app` 开第二个。

## TCC 弹窗"访问其他 App 数据"根因与解法（2026-06-24）
- **现象**：patch+重签后，每次启动狂弹「"微信"想访问其他 App 的数据」。
- **根因**：微信要访问 app-group 共享容器 `~/Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat`（5A4RE8SF68=腾讯 Team）。patch 必须重签 → 签名 Team 变成 `not set` → 与容器归属腾讯 Team 不匹配 → macOS 判定"访问别家数据"。
- **重签(自签名)无法解决**：要 Team 匹配需腾讯证书，不可得。已确认自签名(`WeChatMulti Local CodeSign`)重签后弹窗依旧。→ 签名稳定性不是这个症状的因。
- **正解 = Full Disk Access，但有坑（社区 issue #808 多人验证）**：必须把微信从 FDA 列表用 `−` **彻底删除再重新 `+` 添加**（不是关开关），保持开启，再彻底重启微信。
  - **为什么单纯开 FDA 没用**：FDA 授权绑定 App 的 **cdhash(二进制指纹)**。本项目反复 patch/重签（adhoc→自签名→adhoc），每次 cdhash 变，旧 FDA 记录按旧指纹建、与当前二进制不匹配 → FDA 不生效 → 继续弹。删掉重加=按当前 cdhash 建新记录 → 命中 → 弹窗止。
  - **GUI 必须处理**：每次 patch 后 cdhash 变，需引导用户「移除并重新添加 WeChat 到 FDA」，否则旧授权失效。可检测 FDA 记录 cdhash 是否匹配当前二进制。
- **GUI 功能(结果导向，按用户定义)**：功能 = 「消除访问数据弹窗」，由结果定义而非手段。实现 = **检测 + 引导 FDA**，**不含签名**（签名试过、对此症状无效，已从功能剔除）。
  - 检测微信是否已授 FDA；未授 → 一键跳 FDA 设置面板 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` + 图文引导。
  - patch 步骤保持 WeChatTweak 原样（adhoc 即可），不把签名当卖点。
- **签名实验已按奥卡姆剃刀清理**：WeChat 已 `wechattweak patch` 还原成默认 **adhoc** 签名；自签名身份/证书已从 keychain 删除，`/tmp/wxsign.crt` 已删。系统无残留。多开正常。
- **教训**：功能要锚定用户痛点(消弹窗)，别锚定某个手段(签名)。签名对这个症状是死路；没用的东西不要加(奥卡姆)。
- **机器当前净状态**：官网 4.1.5(32288) + wechattweak patch(adhoc) + 多开可用；待办仅 FDA。

## 版本适配尝试失败 + 克隆方案凸显（2026-06-24，关键）
- **阻塞**：风控账号要求最新版微信（图6"版本过低"），4.1.5(32288) 太老登不上。最新版 = **4.1.10 / build 268831**（官方 CDN `WeChatMac.dmg`；二进制结构利好：代码在 5.1MB 主程序、wechat.dylib 仅 82K，可 patch）。
- **自适配尝试（失败）**：用 32288 的 multiInstance(VA 0x1001e1a74)做签名移植找 268831 偏移——①原始字节、②带通配符屏蔽位置相关指令(adrp/分支/ldr-literal)，**两轮全无匹配**。结论：4.1.5→4.1.10 该函数改动太大，签名移植走不通；从零语义逆向要数小时且不保证成 → **放弃自适配**，让用户搜现成的(Option 2)。
- **"blu"=BundleID**：用户口中的 blu 指**克隆 .app+改 BundleID（路线A）**，与 WeChatTweak(注入/byte-patch)无关。
- **关键反转**：路线A 克隆**完全不依赖版本偏移** → 4.1.10 等任何版本零适配即可多开（byte-patch 的死穴正是每版找偏移，这次就卡死）。代价=多 .app(熵)，但 GUI 可自动创建/重建/管理副本把熵收进工具。
- **最新版多开抉择(待用户定)**：① 搜到 268831 的 byte-patch 偏移→零额外.app；② 克隆 BundleID→现在就能用、零适配、多 .app。
- WeChatTweak 技术：v1.x=dylib 注入(method swizzling，工具 insert_dylib/optool)；v2.0=静态字节 patch(改 multiInstance 等函数返回值，offset 存 config.json)。

## 适配情报：作者已死、X1a0He 是活路（2026-06-24）
- **WeChatTweak 作者停更**：config.json 最后适配 2026-02-08 的 34371，之后没动。新版（4.1.8/4.1.10）等他没意义。适配方式=每 build 手动逆向找偏移→提交 config.json，**无公开找偏移脚本**。
- **找到活跃替代 `X1a0He/X1a0HeWeChatPlugin`**：活跃维护（2026-06-17 / v2.4.7），**dylib 注入**（X1a0HeWeChatPlugin.dylib + .pkg 一键装），支持 4.1.10.53(39917)、4.1.11.x、40431/40446。→ 比已死的 WeChatTweak 更值得依附；注入靠符号、更抗版本变化，没有 byte-patch 偏移表可抄。
- **build 号谜团**：4.1.5.28=CFBundleVersion 32288（与 WeChatTweak 一致）；但官方 WeChatMac.dmg 的 4.1.10=CFBundleVersion **268831**，而 X1a0He 标 4.1.10.53=**39917**——两套编号远程未能对齐，需用实际要登录的微信 build 对 X1a0He 兼容表。
- **克隆 BundleID 路线：用户已在立项时否决，永久不再提。**
- 同类项目备选：TKkk-iOSer/WeChatPlugin-MacOS、MustangYM/WeChatExtension-ForMac（多为老/iOS）。
- 已给用户 pplx 调研 prompt（对比各项目维护状态/支持 build/注入vs patch/安装）。

## ⛔️ 重大修正：byte-patch 没死，是之前找错了二进制（2026-06-24，2个核查 subagent）
- **此前"加密壳→byte-patch 结构性死亡"的结论作废（我错了）。** 两个独立 subagent 一致纠正：
- **真正微信本体 = `Contents/Resources/wechat.dylib`（fat 320MB / arm64 155MB，明文未加密）**，由 `MacOS/WeChat`(明文loader) 经 `dlopen` 加载。证据：无 LC_ENCRYPTION_INFO、熵 6.5–6.95（非密文7.99）、`__text` 正常反汇编、还原出 `lock.ini`/`IsRunning`/Qt 真符号。`WCDY.framework`(0.83MB) 只是 stub；`bad decrypt`/IV 是给热更新下载包的，非出厂 dylib。
- **多开判定在该明文 dylib 里**，机制 `flock(lock.ini)`。候选 patch 分支：`cbz w0` @ `0x43391a4 / 0x433d4bc / 0x433d4d0`（lock.ini xref 0x4339150/0x433d45c/0x433d95c）。无应用层完整性校验，唯一阻碍是 OS 代码签名→`codesign --force --deep` 重签。
- **结论：静态 byte-patch 在 4.1.11 可行**（Doubao 评分：纯机器码 8/10、insert_dylib 7/10）。详见 `re/static-patch-verdict.md`。
- **X1a0He 机制（`re/injection-approach.md`）**：Tyilo insert_dylib 给 `wechat.dylib` 插 `LC_LOAD_DYLIB=@rpath/X1a0HeWeChatPlugin.dylib`；Swift+静态Dobby inline hook C++ 单例函数（名字被混淆，静态读不到，需 lldb 断 `_DobbyHook` 动态读）；全量 ad-hoc 重签绕 library validation。多开是否需第二实例独立数据目录未确认。
- **战略更新**：byte-patch 腿复活，且比 X1a0He 注入更低熵/可控 → 值得自研一个 4.1.11 的 byte-patch 引擎（patch cbz 分支+重签），与 X1a0He 注入并存。下一步需：确定确切字节改法 + 实测多开是否生效（候选分支需验证）。

## ~~🔑 决定性发现：新版微信加密壳架构 → byte-patch 死路（已被上方修正推翻）~~
- **微信 4.1.10(268831) 主程序只是 5MB「加载器壳」**：真正业务代码在 `WeChat.app/Contents/Frameworks/WCDY.framework/Versions/A/WCDY`(~141MB)，**磁盘上加密**(loader 含 OpenSSL CMS/EVP 解密 + `xWeChatLdrIV2024` IV、`xwechat_load`/`is_wcdy_supported`)，运行时才解密加载。
- 证据：268831 arm64 slice 仅 2.5MB、ObjC class 仅 1 个(Crashpad)、objc_msgSend 仅 53 处；32288(4.1.5) 本体 141MB、海量 ObjC。微信 4.x 已 Qt/C++ 重写，老 `+[CUtility HasWechatInstance]` 多开判定搬走。
- **结论(战略级)**：多开函数在加密的 WCDY 里 → **static byte-patch 对 4.1.10+ 架构性死亡**(改的是密文)。这才是 WeChatTweak 没法适配新版的真因(非作者偷懒)。
- **唯一活路=运行时注入**(解密后内存里 hook) → **X1a0He** 正是这么做。签名移植/找偏移对新版彻底放弃。
- 逆向产物：`re/268831-finding.md`。

## 战略定型：双引擎
- **老版(4.1.5/32288)**：byte-patch(WeChatTweak)——已跑通，本机在用。
- **新版(4.1.10+，风控账号要的)**：注入(X1a0He)——dylib 运行时 hook，绕加密。pplx 报告也证实 X1a0He 是唯一活跃支持 4.x 的项目(支持到 4.1.11.21/40446)，自带禁用自动更新，`sudo sh install.sh` 装，`sudo chflags schg` 锁版本。注意:仅 Apple Silicon + 官网 DMG 版;build 号看「关于微信」(非 CFBundleVersion)。
- GUI 目标：双引擎管理器(老版调 wechattweak / 新版调 X1a0He)，检测 build→选引擎。

## ✅ 自研 byte-patch 引擎跑通（4.1.11，2026-06-24，subagent 实测）
- **真正的多开闸门 = `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]`**（进程级单实例判定），不是 flock(lock.ini)（那是账号级数据锁，前序 verdict 的 cbz 候选作废）。X1a0He 即 hook 此选择子返回空。
- **确切 patch（实测生效）**：明文 `Resources/wechat.dylib`，`func.00ec5e84`="是否已有实例"谓词。
  - arm64 VA `0x00ec5ee8` / fat 文件偏移 **`0x0acbdee8`**；原始 `f5 07 9f 1a`(`cset w21,ne`)→ patched `15 00 80 52`(`mov w21,#0`)。
  - 重签：`codesign --force --sign -` dylib + `--force --deep --sign -` app。config.json(version=269077) 在 `re/byte-patch-4.1.11.md`。
- 实测：patched 副本 + 用户 X1a0He 微信同时各 1 进程并存=多开成立。X1a0He 完好（subagent 未碰 /Applications，仅 /tmp 副本）。
- **关键边界（待解决）**：① byte-patch 去掉的是 dylib 内单实例判定，但**同一 bundle 用 `open -n` 叠开是否被 loader/LaunchServices 再去重，subagent 未验证**（它用了 2 个不同 bundle 测）；若 loader 有独立去重，则同-bundle 需 **patch + App 克隆改 BundleID**（=多 .app，用户反对）。需实测同-bundle open -n。② 不同账号多开不需独立数据目录；同账号双开才需。③ 微信有应用层签名自校验（X1a0He hook 了 17 个 Security API），但本地 ad-hoc 重签实测没被拦。
- **战略**：现有两个验证过的新版引擎 —— byte-patch（自研、低熵、纯多开）vs X1a0He（注入、防撤回等更多功能、已在用）。

## ⛔ byte-patch 引擎被实测否决（同-bundle open -n 不行，2026-06-24）
- **决定性验证**（`re/open-n-verify.md`）：byte-patch + 重签后，同一 `/Applications/WeChat.app` 连续 `open -n` → 每次 fork 新 PID 但 1.5~2s 后自退，稳态恒 1。
- **根因**：byte-patch 只钉死消费 NSRunningApplication 结果的那一处谓词；同-bundle 启动还有**第二道更早的单例门**（键在 bundle path+id，LaunchServices/loader 协作层），不经过被 patch 的指令。→ 这就是 X1a0He 用插件侧 NSTask re-launcher 而非翻谓词的原因。
- **结论**：byte-patch 单独**做不到干净同-bundle 多开**，要多开必须**克隆 .app 改 BundleID**（=多 .app，用户反对）；而克隆本身又不需要 byte-patch。→ **byte-patch 对 4.1.x 实际多开无用，引擎方案否决。4.1.11 干净多开只有 X1a0He（注入+relauncher）。**
- 「延续 WeChatTweak 火种」在 4.x 第二道门前，静态 patch 够不着——已用实测问死，非猜测。
- **关键重签名坑（解释此前大量痛点，务必记住）**：`codesign --force --deep --sign -` 会把**嵌套 bundle 的腾讯团队签（TeamID 5A4RE8SF68）也 adhoc 掉** → `containermanagerd` 拒绝访问 group container `5A4RE8SF68.com.tencent.xinWeChat` → 微信启动数秒自退/或狂弹「访问其他App数据」。**正解=只 adhoc 签被改的 mach-o + 顶层可执行(带 entitlements) 重封资源，绝不 --deep，保留嵌套原厂团队签。** （这或许才是"访问其他App数据"弹窗的真正治法，优于 FDA 兜底。）
- **战略定型**：新版(4.1.x)= X1a0He 注入引擎（唯一可行）；老版(4.1.5)= byte-patch(WeChatTweak)。byte-patch 自研引擎归档，不集成。

## 第二道单例门定位完成（2026-06-24，subagent，`re/second-gate.md`）
- **第二道门在 loader（`Contents/MacOS/WeChat`，5.6MB 明文），不在 wechat.dylib、不在系统库。** 机制=mach bootstrap 单例锁（`mach_port_allocate`+`bootstrap_look_up` well-known service）；命中→relaunch(posix_spawn)+父进程 `_exit(0)`=「fork 新 PID 后 ~1.5-2s 自退」的真相。hook exit 抓到调用栈,3 次运行一致。
- **可静态 patch**：`Contents/MacOS/WeChat` arm64，VA `0x10009df88`，thin 偏移 `0x9df88`，**干净 loader fat 偏移 `0x379f88`**；`40 0b 00 34`(cbz w0)→`5a 00 00 14`(b 无条件)。实测打完 relaunch 自退消失。
- **但纯静态单 app 多开仍不成（关键边界）**：多开链共三层 —— ① loader mach 单例(本次)② **loader 对业务体的校验(adhoc 重签后失效→loader 走 main 干净返回、不加载业务体)** ③ 业务体 NSRunningApplication 谓词。单 app 静态多开需同时处理 ①+②，而 ② 在 adhoc 重签下没法纯静态绕(要么注入 hook 校验=X1a0He 路线，要么有腾讯签名)。
- **结论**：① **clone bundle 改 CFBundleIdentifier 一招绕全部三层**(最稳纯静态，但=多 .app，用户反对)；② **X1a0He 注入处理全部三层**(已在用,唯一干净单-app 方案)。**纯 byte-patch 单-app 多开在 4.1.11 上被 layer② 卡死**——火种挖到底了,实测问清,静态够不着。X1a0He 仍是新版引擎。

### GUI v1.7：自动下载替换兼容版微信
- 兼容判断：App Store 版 / build > 内置引擎目标(269077) → `needsDownload`。按钮变蓝「下载并替换为兼容版微信」→ 确认弹窗(说明原因+约470MB+聊天记录不丢)→ 下载(curl 无密码)→ 关微信 → 管理员权限覆盖安装。目标版=4.1.11.21/40446(X1a0He README 的官方 CDN 链接)。

## 🔬 第②层门核实：不存在！三层实为两层（2026-06-24，subagent，`re/layer2-verdict.md`）
- **推翻 `second-gate.md` §4**：所谓"loader 重签后拒载业务体的第②层"是**误诊**。隔离实验证明：patch①+adhoc 重签 loader（保留业务体腾讯签名）后，**loader 照常 dlopen 业务体**（1787 次、140MB __TEXT 全 map、进 UI 初始化）。之前把"后期 exit(-1)"误当"早期未加载"。
- 否定 Library Validation（adhoc 宿主 team 空、不进 CS_REQUIRE_LV 路径，实测能加载腾讯签 dylib）；否定腾讯自检（无 log）。
- **真凶=第③层**：业务体 `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]` 撞到已运行实例→`exit(-1)`。**门只有两道：① loader mach 单例 + ③ 业务体 NSRunningApplication。**
- **纯字节补丁单-app 多开不成立**：第①层可静态 patch；但第③层 4.1.11 重构为多处消费+动态派发，patch 3 个谓词点（slice 0xec9314/0x1d6f70/0x4506918）第二实例仍自退；**唯有选择子级 swizzle 全覆盖派发路径才通**（实测 2 实例并存 >50s）。
- **干净单-app 多开两条路**：① **swizzle 第③层选择子=注入**（X1a0He 路线）② **clone bundle 改 id+group**（零注入、三门全不触发、最稳，但多 .app）。
- **副产品（重要）**：自研注入引擎清晰可行——只需极小 dylib **swizzle `runningApplicationsWithBundleIdentifier:` 返回空** + insert_dylib 挂入。不必抄 X1a0He 4.4MB 大库。这是零第三方依赖的自研多开引擎。
- group container：adhoc 抹 team→containermanagerd REJECT app-group（自签证书无解，仅腾讯私钥可过），**但非致命**（swizzle 版第二实例照常常驻）。`app-sandbox` entitlement 必须保留，勿 `--deep`。无"访问其他App数据"弹窗。
- **偏移强依赖 build**：本 DMG loader arm64 slice 起点 0x2B8000≠文档 0x2DC000。引擎须运行时 `lipo -detailed_info` 取 slice 起点 + 特征码定位，不能硬编码。

## 当前状态（最近更新：2026-06-24）

## 🎉 自研注入引擎落地（2026-06-24，subagent，`re/self-engine.md`，代码 `engine/`）
- **`WeChatMultiEngine.dylib`(universal)**：constructor ① swizzle `+[NSRunningApplication runningApplicationsWithBundleIdentifier:]` 仅对 com.tencent.xinWeChat 返回空(覆盖全派发路径) ② 权限探针(`CGPreflightScreenCaptureAccess`+读 TCC.db)写 `perms.json`。
- 配套：`insert_dylib.py`(纯 Python LC_LOAD_DYLIB 注入)、`locate_gate1.py`(运行时特征码定位门① `E0 73 00 B9`+后随 cbz→B，不硬编码)、`install-self-engine.sh`(门①patch+门③注入+adhoc 重签，保留 app-sandbox、不 --deep、拒碰 /Applications)。
- **实测**：2 个同-app 实例并存 >3min（X1a0He /Applications + 自研引擎 /tmp），perms.json 正确写出且值跟真实 TCC 一致，`codesign --verify` 通过。X1a0He 完好（未碰 /Applications）。
- **关键边界**：同一 bundle 叠 N 开被 **LaunchServices 按 CFBundleIdentifier 去重**(非微信门)——但 `open -n` 带 `-n` 旗标绕过 LS 去重，且用户已实测 X1a0He 下 open -n 多开有效；自研引擎门处理与 X1a0He 等价,装上 /Applications 后 open -n 应同样有效(待装机验证)。稳妥 N 开仍是 clone-bundle，引擎可复用。
- **待办**：① 装机验证(替换 X1a0He，备份)② 接进 GUI 做「自研引擎(主)/X1a0He(备)」+ 读 perms.json 显真权限 ③ 装后清 quarantine 防 AppTranslocation；GUI 读 perms.json 走沙盒容器路径。

## 当前状态（最近更新：2026-06-24）

## 🔓 X1a0He 机制彻底逆向（2026-06-25，内存diff subagent，`re/body-gate-memdiff.md`）
- **X1a0He 不是 byte-patch、不 swizzle NSRunningApplication**（实测那俩 IMP 仍指向 AppKit）。用 **Dobby 内联 hook**（`adrp x17;add x17;br x17` 覆盖函数序言）。我方引擎的 NSRunningApplication swizzle 是另一条路（能并存，但非 X1a0He 真实做法）。
- **X1a0He 共 20 处内存 patch**：稳态 19 处 Dobby hook（5 关自动更新 XAppUpdateManager、1 Qt dock 菜单、**13 处 Cronet/Mars 网络栈文件函数=多开数据/日志/缓存路径隔离**）。这 19 处都不是单例门。
- **第 20 处=真正的早期单例门中和，只装在「第二+实例」**（所以一直没人定位到——都在看第一实例）：
  - `WeChatMain` vmaddr `0x16380` / fat `0x9e0e380`；原 `fd 7b bf a9`(stp 正常序言)→ patched `d0 e8 07 14`(`b 0x2106bc`，位移 +0x1fa340)。
  - 效果：第二实例从 WeChatMain 第一条就跳进 `func.002106bc`，**整段跳过 WeChatMain 的 init 链**（单例-exit 判定就埋在那条链里）。
- **闭环实证**：同副本+gate①patch+exec 第二同路径实例 → 无插件 `exit(255)`；有插件 2 实例并存 >10s。
- **复刻配方（报告 §5 有代码）**：引擎 constructor 仅当本进程是第二+实例时，mprotect WeChatMain 页→写 `b` 到放行入口(imm26 特征码动态算)→复原+clear_cache。**但跳过 init 链后需数据目录隔离**（否则抢 Cronet/MMKV 文件不稳）=X1a0He 那 13 个 hook 的活，或直接 clone-bundle。
- **结论**：同路径多开=复刻 X1a0He(WeChatMain 跳 + 路径隔离)。我方引擎能做核心跳转(第二实例存活)，鲁棒性需补路径隔离=重建一块 X1a0He。**完整逆向档案(re/)本身=开源旗舰价值。**

## 当前状态（最近更新：2026-06-25）

- **阶段**：✅ GUI v0.9.0；**核心可用(X1a0He)**；🎉 自研引擎同路径多开攻克+已接GUI；🎉 bundleID兜底已坐实(稳定配方+脚本);待办：bundleID接GUI、装机验证(用户在场)

### 🎉 bundleID 终极兜底坐实（2026-06-25 12:5x，`re/clone-verdict.md`）
- **被杀真凶**：非系统宽限——微信内置 **Crashpad** 启动时 `bootstrap_check_in` mach 名 `5A4RE8SF68.<bundleId>.crashpad.*` 被沙盒 `deny(1100)`→SIGTRAP 自退(exit133)。沙盒只放行【进程自己 application-identifier 的 team 段】为前缀的 mach 名。
- **稳定配方钥匙**：`com.apple.application-identifier` = **`5A4RE8SF68.com.tencent.xinCloneN`**(保留腾讯 team 前缀、只换 bundle 后缀)→ 放行 Crashpad 不被杀。app-group 同理(各克隆独立 group 容器)。app-sandbox 保留。其余 cs/files/network/mach-lookup 能力位照搬。adhoc 逐文件深→浅签、顶层带 entitlements 最后、不 --deep、清 quarantine。
- **实测**：克隆 `open -n` 存活 >92s;两克隆并存 95s 双活,各独立容器=真数据隔离。
- 交付：`engine/install-clone.sh`(纯克隆安装器,入参 N+源app+目标,幂等)、`engine/cleanup-clone.sh`(删 .app+数据容器+group容器)、`re/clone-verdict.md`。
- **GUI 需知局限**：① 独立容器=独立登录(克隆=独立账号、注入=共享数据);② **清理容器需 FDA**(`~/Library/Containers/<bundle>` 受 TCC 保护,无 FDA 连空目录都删不掉)→ GUI 清理前检测 FDA 并引导授权。
- **残留**：测试克隆建的 `~/Library/Containers/com.tencent.xinClone1/2/3`(3×36KB 空壳,无数据)受 FDA 保护、autonomous shell 删不掉,留待用户授 FDA 后 `rm -rf` 或访达删。

### 🎉 自研引擎 v2 — 同路径多开攻克（2026-06-25 12:32，`re/self-engine-v2.md`）
- **达成**：同一 app 副本 `open -n`/exec 起 **2 实例并存稳定 >70s**(direct-exec + open -n 均验证)，零崩溃。/tmp 副本施工，**/Applications 全程未碰，.original md5 不变，X1a0He 完好**。
- **真门②=`tbz w20,#0` @vmaddr `0x2117e0`**(在出厂自带的放行函数 `0x2106bc` 里)：第二实例 w20.bit0=0→bail→WeChatMain 返回-1→loader `exit(255)`。**中和=运行时特征码定位该 tbz→NOP，仅第二实例装**。
  - 修正 body-gate-memdiff §2：`WeChatMain`(`0x1637c`)首条 `b 0x2106bc` **出厂自带**，非 X1a0He hook（off-by-4 误读），引擎不动它。
- **第二实例判据=容器内 `flock` 锁文件**(NSRunningApplication 数不到非LS实例、proc_listpids 被沙盒挡 → 都失效)。门①静态 patch 不变；门③ swizzle 保留但单独不足以放行(只消 UI 提示)。
- **数据隔离不需要**：共享容器 + MMKV `InterProcess` 多进程锁 + AppEx `--instance-index`，75s 零 DB锁/CRC/崩溃。真·按账号隔离仍靠 clone-bundle(=bundleID 兜底)。
- **引擎 constructor 3 步**：flock判role → (第二实例)门②tbz NOP → 门③swizzle → 写 perms.json(权限探针=注入微信自检，即用户要的原生效果)。零硬编码偏移(全运行时特征码)。
- **GUI 对接**：装=`engine/install-self-engine.sh <副本>`；多开=现有 `openNewInstance()`(open -n)即可，无需 clone；权限读容器内 `…/WeChatMulti/perms.json`。
- **待办**：① 接进 GUI(自研引擎为主、X1a0He 兜底、读 perms.json 显真权限)；② 装机验证留给用户在场时(会替换 X1a0He，autonomous 阶段不做)。

### ⚠️ 优先级与权限方案纠正（2026-06-25，用户明确）
- **全盘权限检测=注入微信、伪装成微信自检**（微信自己查自己→写 perms.json 给 GUI 读）。**「把工具自身加进 FDA 读 TCC.db」方案已否决**（之前的 GUI-FDA 闭环说法作废）。原生自检需注入→**依赖自研引擎**；若实现不了再说。
- **优先级**：① 完成所有已知/现成工具 → ② **bundleID 终极兜底（优先级高于自研引擎）** → ③ 自研引擎(option A，为原生探针+自研多开)。
- **不打断正在跑的 A subagent**，等它完成再动 /tmp。

### bundleID 终极兜底 — 设计规格（待 A 完成后实现）
- **尾号复用策略（用户问的"1/2/3/4 关系"）**：克隆 bundleId `com.tencent.xinCloneN`(N=1,2,3…)，各自独立容器 `~/Library/Containers/com.tencent.xinCloneN`。
  - 点"新开"时：**扫描已有克隆 1..K，找最小的「存在但没在跑」的 N → 启动它(复用)**；**只有当 1..K 全在跑**，才新建 `CloneK+1`(新 .app+容器)。→ 尾号只在「全占满」时才 +1，**先用完前面的再推进**，克隆数收敛到历史最大同时实例数，不无限膨胀。
- **双计数显示**（"已打开的微信"行右边加括号）：`N（已克隆 X 个）`——N=运行中实例数(原版+在跑克隆)，X=已存在克隆总数(不论是否在跑)。EN: `N (X clones)`。
- **克隆模式下的 GUI 状态**：① 权限行**隐藏**(克隆无注入、不适用探针)；② "双开插件版本"显示**本工具自己的版本号**(用的是我们自己的克隆引擎，非 X1a0He)；③ "双开插件状态"右边方案名 = **「BundleID 方案」**(EN: `BundleID`)，即 `已可用（BundleID 方案）`/`Ready (BundleID)`——与注入类方案(X1a0He/自研引擎)区分。
- **清理(硬要求)**：删克隆时**同时删 .app + `~/Library/Containers/com.tencent.xinCloneN`(及 group 容器)**，不留残留占空间；提供"清理克隆"动作；重置时清所有克隆+容器。
- **签名待解**：adhoc 下 app-group(`5A4RE8SF68.*`绑腾讯 team) / application-identifier 怎么处理才能稳定存活(裸删→app-sandbox 起不来；裸留→宽限被杀)。`engine/install-clone.sh` 为起点。

### bundleID 终极兜底（2026-06-25 /tmp 实测，概念已证实）
- **目的**：版本无关的"永不失效"兜底——所有注入/字节方案失效(微信大改/项目长期没维护)时仍能多开。
- **实测**：纯克隆(零注入零patch) `/Applications/WeChat.app` → 还原干净业务体 → 改 `CFBundleIdentifier=com.tencent.xinClone1` → adhoc 重签 → **独立实例能起、生成独立沙盒容器**(`~/Library/Containers/com.tencent.xinClone1`=独立登录/数据)。多开门全按 bundle 身份判定，换 id 即绕。
- **稳定性待坐实**：两次裸克隆都未稳住——但**被并发的 A engine subagent /tmp pkill 清理污染**，不算数；且裸重签 entitlement 配方有坑(app-group `5A4RE8SF68.com.tencent.xinWeChat` 绑腾讯 team，adhoc 不匹配→宽限后被杀；删掉又导致 app-sandbox 起不来)。
- **待办**：A 跑完后做一次**不受干扰的干净稳定性测试** + 定 adhoc 下正确签名配方(app-group/application-identifier 怎么处理)→ 稳了就接进 GUI 作终极兜底按钮。`engine/install-clone.sh` 是现成起点。
- **取舍**：✅版本无关韧性拉满；⚠️独立登录(多账号本应如此)、多一个.app、签名配方讲究。

### GUI 近期变更（v1.27–v1.29）
- v1.27 绿按钮「多开一个新微信」；v1.28 菜单栏图标回 `3.square.fill`(语言中立)、菜单文案对齐、**找不到微信→灰按钮+手动选 .app 路径**(`appPath` 可配置+`chooseWeChatPath` NSOpenPanel，泛用性)。
- v1.29 **中英双语**(subagent)：全部用户可见串走 `String(localized:)`/LocalizedStringKey，`Resources/en.lproj`+`zh-Hans.lproj`(各41条)，build.sh 拷 lproj、Info.plist 加 `CFBundleDevelopmentRegion=zh-Hans`+`CFBundleLocalizations`。按系统语言自动切换。
- 按钮换自定义 `SolidButton`(实心色，失焦不变灰)；权限行/提示在「检测到全盘正常」时自动隐藏(v1.24，B 经 GUI-FDA 闭环)。
- **进行中**：版本日期(app/ subagent)、A 自研引擎同路径多开(engine/ subagent)。

### 同-bundle spawn 谜底（2026-06-25，subagent，`re/spawn-verdict.md`）
- **spawn 不是秘密**：X1a0He 也是 `system("open -n ...")`，无特殊参数。
- **真凶=业务体 `wechat.dylib` 内一个 C/C++ 级单例门**，框架加载早期(ilink2/Mars 间)触发→2nd 实例 `exit(255)`，**早于 NSRunningApplication**。排除了 mach bootstrap/lock.ini flock/NSRunningApplication ObjC(都 swizzle 过仍死)。门①patch+门③swizzle 拦不到它。所有 spawn 方式(open-n/posix_spawn/NSWorkspace)同路径都失败。
- **X1a0He 破法=运行时内存 patch**：插件 import `mprotect`+`mach_vm_protect`+`method_setImplementation`，两实例都加载，`isMultipleInstanceEnabled` 开时把业务体早期门内存字节改掉。纯运行时、非静态。
- **现可用：clone-bundle**（`engine/install-clone.sh`）——自研引擎+克隆改 BundleID，实测 2 实例并存 >32s（门按 bundle 身份判定，换 id 即绕）。代价=多 .app（用户反对）。
- **自研引擎补最后一环**：给 `WeChatMultiEngine.m` constructor 加 `patch_body_early_gate()`（mprotect+写 `mov w?,#0;ret`，X1a0He 式）。**但 295MB 业务体里那道门的确切 patch 点未定位**——最快=内存 diff(X1a0He patched 实例 vs 原始字节)。坑：注入 dylib 必须 `-mmacosx-version-min=11.0` 否则 constructor 不跑(落 __init_offsets)。

### 自研引擎装机实测（2026-06-24，/Applications，已回滚）
- 流程：退微信→备份 X1a0He（`/tmp/x1a0he_bak/`）→还原干净业务体→`install-live.sh`（门①patch slice 0x9df88✓ + 门③注入 + adhoc 重签）→清 quarantine→启动。
- **结果**：引擎 dylib 成功映射进程✓；**perms.json 正确写出✓（注入式权限检测通了）**；门①定位与 second-gate 一致✓。**但 CLI `open -n` 叠开仍=1**。
- 研判：疑非引擎错——**CLI `open -n` vs GUI `NSWorkspace.createsNewApplicationInstance` 对同-bundle LS 去重处理可能不同**；X1a0He 同-bundle 多开靠 relauncher 主动 spawn（非裸 open -n）。**自研引擎可能差一个 relauncher**（或改用 NSWorkspace 调用即成）。
- **已完整回滚 X1a0He**：业务体 md5 52bb2c9e✓、loader 门①字节还原、引擎 dylib 移除、重签 `codesign --verify` PASS、实测多开 1→2 恢复。
- 待办：在 /tmp 副本上查清同-bundle 多开的正确 spawn 方式（NSWorkspace vs relauncher），补全自研引擎最后 10%。（X1a0He + GUI「开新微信」open -n 实测多开成功，用户已确认）；正挖第二道单例门

### 核心确认（2026-06-24）
- **X1a0He 下 GUI 绿色「开新微信」(open -n) 能成功多开**（用户实测）。修正：byte-patch 裸版 open -n 自退是因为没处理第二道门；X1a0He 处理了第二道门，故 open -n 在 X1a0He 下有效。GUI「开新微信」按钮保留。
- 用户计划：后续开源本项目（GitHub），可能较多人用 → 代码与署名要干净。

### 正在做：定位"第二道单例门"（subagent，2026-06-24）
- 现象：byte-patch 第一道门后，重复实例 fork 出来跑 1.5~2s 主动 exit（检查在微信代码内部，非系统级）。
- 方法：注入 dylib hook `exit`/`_exit`/`terminate:` 抓调用栈，定位谁让它退；判断是否可静态 patch。在 /tmp 副本上做，**不碰 /Applications 的 X1a0He**。
- 若第二道门可静态 patch → 纯 byte-patch 同-bundle 多开成立 → 火种烧通 + 可给原作者提完整 PR（工具 patch wechat.dylib + 双门 config）。
- UI v1.5：菜单栏开关改回 checkbox；权限检测不到时显灰点+提示、不显"未授权"（避免误导）。

### GUI v0.8（2026-06-24，按用户反馈重做按钮逻辑）
- 单一动作按钮：未装=蓝「安装双开插件」(`installBestEngine()` 按 build 自动选 WeChatTweak/X1a0He)；已装=红「重新安装双开插件」。去掉每引擎的「启用」按钮和「打补丁」按钮（画蛇添足）。
- 引擎行只显版本：`WeChatTweak 2.0.1 · 支持≤4.1.5`、`X1a0He 2.4.7 · 支持≤4.1.11`。补丁状态→「双开状态」，已生效显引擎名。

### 「结构性死亡」说法的修正（重要，诚实记录）
- 之前说"byte-patch 对 4.1.10+ 结构性死亡"**措辞过绝对**。精确版：**直接静态 patch 加密 WCDY 里的判定函数不行（改密文）；但注入（明文 loader 插 LC_LOAD_DYLIB + 运行时内存 hook）可行，X1a0He 即如此**。豆包把"改 loader 加载命令"也算静态修改=术语之争。
- 已派 2 个 subagent 用证据核查：
  - `re/static-patch-verdict.md`(进行中)：判定函数在加密WCDY还是明文loader？纯静态 byte-patch 到底行不行？核查我的说法。
  - `re/injection-approach.md`(进行中)：逆向 X1a0He dylib 看它具体 hook 哪里/怎么注入/怎么重签；评估自研等价 Tweak 的可行性。
- 右键「新开微信」hook 暂不集成（会与 X1a0He 注入冲突）；待摸清 X1a0He 注入机制后考虑搭进去。

### GUI v0.7：双引擎一步到位（2026-06-24）
- X1a0He pkg 内置进 App Resources；GUI「X1a0He」行有「启用」按钮 → `installX1a0He()`：退微信 + `osascript do shell script ... with administrator privileges`（**GUI 内弹原生密码框**，不碰终端）装内置 pkg。用户全程在 GUI 操作。
- 双引擎识别：`detectX1a0He()` 查 `wechat.dylib.original`/`X1a0HeWeChatPlugin.dylib` 是否存在；`activeEngine`= x1a0he(优先) / weChatTweak(byte-patch 已生效) / none。
- 补丁状态显示「已生效（X1a0He）」或「已生效（WeChatTweak）」；WeChatTweak 行标「老版 ≤build 34371」；新增 X1a0He 引擎行。
- 已装微信 4.1.11.21(269077)，X1a0He 内置 pkg 版本 2.4.7 支持它。Downloads 里的 pkg 已删（内置 GUI）。
- 待办：GUI 给自己申请 FDA 以读 TCC.db（权限红绿才准）；X1a0He 卸载按钮；自动按 build 拉对应 X1a0He pkg 版本。

### X1a0He 集成进度（2026-06-24，恢复新版可用性）
- 已装 **官网微信 4.1.11.21（CFBundleVersion 269077 / 关于-build 40446）**，替换原 4.1.5（备份 `/tmp/WeChat_4.1.5_backup.app`，DMG `/tmp/WeChat_41121.dmg`）。X1a0He 最新支持此版。
- X1a0He pkg **SHA256 校验通过**（=官方公布值，未篡改），已放 `~/Downloads/X1a0HeWeChatPlugin.pkg`。其 postinstall：备份 `Contents/Resources/wechat.dylib`→`.original`，注入加载 `Contents/Frameworks/X1a0HeWeChatPlugin.dylib`，可逆。
- **卡在 sudo 密码**：pkg 装需管理员密码，AI 无法代输 → **用户需双击 pkg 自行安装**（一步）。装前微信已退、otool 就绪。
- X1a0He 下载链接模式：`https://dldir1v6.qq.com/weixin/Universal/Mac/xWeChatMac_universal_<版本>_<build>.dmg`。CFBundleVersion(269077) ≠ 关于-build(40446)，X1a0He 按关于-build 标。
- **装后**：cdhash 变→可能再弹「访问其他App数据」→ 删+重加 FDA；多开走 X1a0He（菜单项/快捷键），GUI「开新微信」按钮(open -n)装后也应生效。

### GUI v0.6
- 加回「运行中微信 N 个」；「重打补丁」改实心红色大按钮(borderedProminent + large)。
- **待办（双引擎 GUI）**：当前 GUI 仍是 WeChatTweak(byte-patch)视角，4.1.11.21 上「补丁状态」会显未生效（因新版走 X1a0He 注入，非 byte-patch）。需让 GUI 按 build 识别引擎：老版查 byte-patch、新版查 X1a0He 注入状态（看 `wechat.dylib.original` 是否存在）。

### M2 GUI v0.5（2026-06-24，按用户反馈）
- 重打补丁按钮→红色；状态与权限合并为一栏，权限红(未授权)/绿(已授权)+「去设置」；补丁状态置顶显示「已生效」；去掉"签名/支持/多开已启用"冗余；「版本」改「当前微信版本」；WeChatTweak 行显示引擎版本(读 Cellar)。
- 权限红绿检测：读系统 `TCC.db`(`sqlite3 -readonly`)查 com.tencent.xinWeChat 的 AllFiles/ScreenCapture auth_value≥2。**需本工具自身有 FDA 才读得到**，否则 permsReadable=false 一律显未授权(已在 UI 注明)。

### M2 GUI v0.3（2026-06-24）
- v0.3 改进：权限区(ToDesk 风格行：全盘访问→`tccutil reset`清旧授权+跳面板；屏幕录制截图→跳面板)、菜单栏「显示菜单栏图标」开关(@AppStorage+isInserted)、菜单栏图标改 SF 双气泡符号(黑白原生)。
- **待办/限制**：① 权限行目前是 amber 可操作样式,**真·红/绿检测微信授权状态需 GUI 自身先拿 FDA 去读系统 TCC.db**(chicken-egg，留作进阶)；② 菜单栏要用用户那张图的精确剪影需一版黑底透明 PNG；③ 右键菜单注入(dylib 已编译，待做可逆开关，默认关)。

### M2 进度（2026-06-24，MVP v0.1 已落地）
- 工具链：Swift 6.3 + `swift build`（无需 Xcode），手动组 .app bundle。源码在 `app/`，构建脚本 `app/build.sh`，产物 `app/WeChatMulti.app`。
- 已实现：
  - **菜单栏常驻「➕ 开新微信」**（NSWorkspace 新实例 + 强制中文 `-AppleLanguages`），⌘N。← 用户最在意的自然多开
  - 主窗口环境检测：版本/build（Info.plist）、签名类型（codesign：App Store/官网/adhoc）、WeChatTweak 是否支持（拉远程 config.json 比对 build）、**多开补丁状态**（解析 fat→arm64 slice 偏移，读 multiInstance 处 8 字节与 config asm 比对）
  - App Store 版橙色警告条；一键 patch 按钮（调 `wechattweak patch`）；一键打开 FDA 设置面板
- 架构：`WeChatModel`(@MainActor ObservableObject) + SwiftUI `Window`+`MenuBarExtra`。
- 待办（下一迭代）：patch 后引导 FDA 刷新(tccutil)、版本守门员、实例列表。
- v0.2 改进（用户反馈）：紧凑布局(窗宽360)、大号绿色"开新微信"主按钮、中文启动改 `cfg.environment=LANG/LC_ALL`(AppleLanguages 参数无效)、自动实时检测(2s 轮询+NSWorkspace 启停监听)去掉手动刷新、显示运行实例数。

### 右键菜单注入功能（独立模块，进行中）
- 定位：独立、默认关、**可取消勾选即恢复**的高风险模块（解耦于 byte-patch 多开核心）。
- 已完成：`app/hook/WeChatMultiHook.m` —— 注入微信后 hook `applicationDockMenu:` 插入「开新微信」(动作=NSWorkspace 新实例+中文 env)。**已编译成功(53K)**。
- 前置条件已验证：微信 flags=`0x2(adhoc)` 无 hardened runtime → 注入 dylib 可加载 ✅。
- 剩余步骤：①装 `insert_dylib`(或自写 Mach-O 加载命令插入)；②dylib 放 `WeChat.app/Contents/Frameworks/`；③`insert_dylib` 加 `LC_LOAD_DYLIB @executable_path/../Frameworks/WeChatMultiHook.dylib`；④adhoc 重签 dylib+微信(→cdhash 变→**需刷新 FDA**)；⑤测试 Dock 右键出「开新微信」。
- 取消勾选的可逆设计：注入前备份主程序二进制；"禁用"=还原备份(去掉加载命令)+删 dylib。
- ⚠️ 注入会再次改 cdhash → 重新触发"访问其他App数据"弹窗 → 需再走一次 FDA 删除重加。
- **已完成**：用户把 App Store 版(4.1.8/37351 沙盒)替换为**官网版 4.1.10(build 268831, Developer ID)**，聊天记录完整保留（路径隔离结论被证伪，官网版照读旧数据）。
- **结构利好**：官网版主程序 5.1MB、多开代码仍在主程序(`__TEXT` 到 0x10021c000，覆盖历史多开地址)；`wechat.dylib` 仅 82K（App Store 版是 295MB）→ 是 WeChatTweak 可 patch 的结构。
- **当前卡点**：build 268831 不在 WeChatTweak 支持列表(31927/32281/32288/31960/34371)。最高支持 34371；确认 **32288 = 微信 4.1.5.28**。
- **下一步（待用户决策）**：装 WeChatTweak 支持版 **4.1.5.28(32288)** → `wechattweak patch` 零逆向一键多开 → 开启"阻止自动更新"锁版本。或保留 4.1.10 等作者适配。
- 逆向新版 268831 无意义：取签名也需旧支持版二进制，不如直接用支持版。
- **形态目标**：最终做成原生 App 补丁管理器(见 M2/M3)。

---

## 1. 项目目标

做一个本机微信多开工具。要求：

1. **目前自用**，但架构上要为「持续迭代 + 未来给更多人用」留余地。
2. 最终形态是 **macOS 原生应用**（不是一堆 shell 脚本）。
3. 优先探索**不复制多个 .app**、纯技术手段实现多开的路线。

### 非目标（暂不做）
- Windows / 跨平台
- 自动化营销、群控、批量账号操作（只做「同机多窗口」这一件事）

---

## 2. 关键技术决策

> 决策一旦定下来写这里，避免反复推翻。状态：✅已定 / 🤔待验证 / ❌已否决

| 编号 | 决策 | 状态 | 理由 |
|---|---|---|---|
| D1 | 多开优先用 `open -n` / `NSWorkspace createsNewApplicationInstance`，不默认复制 .app | 🤔待验证 | 侵入性最低，不污染 /Applications；能否成功取决于微信是否有单实例锁 |
| D2 | 复制 Bundle 方案作为「需要多账号数据隔离」时的可选模式，不作为默认 | ✅已定 | 复制 .app 的真正价值是独立沙盒容器/登录态，而非「能否多开」 |
| D3 | App 本体定位为「启动器/管理器」，微信进程是被它拉起的子进程 | ✅已定 | 决定了整体架构：我们不 hook 微信内部，只管启动与编排 |
| D4 | 技术栈：待定（Swift + SwiftUI vs. 其他） | 🤔待验证 | 见 [开放问题 Q1](#开放问题) |

---

## 3. 多开技术方案备忘

### 方案 A：`open -n`（零复制）
- 命令：`open -n /Applications/WeChat.app`
- Cocoa 等价：`NSWorkspace.OpenConfiguration().createsNewApplicationInstance = true`
- 优点：不碰 /Applications，最干净。
- 风险：① 微信可能有进程互斥锁，第二个实例自杀；② 多个实例共享 `~/Library/Containers/com.tencent.xinWeChat/`，登录态可能互相覆盖。

### 方案 B：克隆 Bundle + 改 BundleID
- 复制 `WeChat.app` → 改 `CFBundleIdentifier`（如 `com.tencent.xinWeChat.clone1`）。
- 每个副本是独立 App 身份 → 独立沙盒容器 → 各自持久登录态。
- 优点：最稳，天然多账号隔离。缺点：要维护副本、占空间、微信更新后要重新克隆。

### 方案 C：`open -n` + 指定独立数据目录
- 启动新实例时让其使用不同的容器/数据目录，兼顾「不复制 .app」与「数据隔离」。
- 难点：微信是沙盒应用，重定向容器目录需要验证可行性。

> 设计取舍：App 里把 A 作为默认快速多开，把 B 作为「需要稳定多账号」时的高级模式，二者做成开关。C 作为研究方向。

---

## 4. 里程碑

### M1: 可行性验证 ✅ 已完成（2026-06-24，实机测试）
- [x] 微信路径/版本：`/Applications/WeChat.app`，4.1.8
- [x] `open -n` 测试：**失败**。第 2 次 `open -n` 新增进程数 = 0（PID 不变），被单实例锁挡掉。
- [x] 锁机制定位：**flock 文件锁**，主进程独占持有这些 `lock.ini`：
  - `…/xwechat_files/all_users/sqlite/lock.ini`
  - `…/app_data/lock/lock.ini` ← 全局单实例锁
  - `…/app_data/wxid_xxx/lock.ini`
- [x] 沙盒判定：`codesign` 显示 `com.apple.security.app-sandbox` = **已沙盒**；签名权威 `Apple Mac OS Application Signing` = **Mac App Store 版**。
- [x] 关键推论见第 9 节。

**M1 结论**：本机这版微信是 App Store 沙盒版，单实例锁是「容器内 flock」。因为沙盒把容器钉死在 BundleID 上，**无法靠重定向数据目录绕过**。→ 纯 `open -n`（零复制+零注入）在此版本**走不通**。

### 多开的正确打开方式（重要，易误解）
- 点 Dock/Launchpad 图标 = 普通 `open` = LaunchServices 只**聚焦现有实例**，不开新进程（与补丁/FDA 无关）。
- 真多开必须 `open -n /Applications/WeChat.app`（`-n`=新实例）。每多开一个敲一次。
- WeChatTweak 2.0 的"多开启动器"插件本质就是替执行 `open -n`。→ 本项目 GUI 的「开新微信」按钮 = 调 `open -n`，一键替代。

### 多开入口方案的成本对比（2026-06-24 决策）
- **方式一 GUI 按钮 / 菜单栏项（选用）**：你的 App 内控件，动作 = `NSWorkspace.OpenConfiguration.createsNewApplicationInstance = true`（=`open -n` 的 Cocoa 等价）。**代价极低**：几行、纯加法、不碰微信二进制、不注入、不重签、微信更新不受影响。菜单栏常驻(NSStatusItem)一键开，自然度不输右键。定位：GUI 子功能/开关（"☑ 菜单栏显示快速多开"），是补充非独立主功能。
- **方式二 老版右键 Dock 菜单（否决）**：Dock 菜单由微信自身控制，外部无法注入条目 → 必须**注入 dylib 进微信进程**(老版 v1.x 做法)。代价：写/维护 Obj-C dylib hook `applicationDockMenu:`；改二进制插 `LC_LOAD_DYLIB`；**重签→cdhash 变→FDA 弹窗回归**；每次微信更新全部重做；更 invasive。换一个入口，性价比差，且踩中"高熵/不稳定"红线。
- **结论**：菜单栏常驻项 = 右键 Dock 菜单的最佳平替（自然+便宜+稳定），不走注入。

### 成本对比的深入分析（回应"成本相同论"，2026-06-24）
- 用户论点：FDA 一次 + 更新后重做 既然两种方案都要付，那注入(右键菜单)同成本却多给功能，为何不做？
- **共享/沉没成本（用户对的部分）**：FDA 刷新、更新后重新应用——byte-patch 与注入都付（都重签→cdhash 变→刷 FDA）。
- **但总成本不等（结论不成立）**：注入在共享成本之上**叠加** = 写并维护 dylib(Obj-C hook) + 每次更新重注入 + 显著更高的 invasive/崩溃/封号面。是加法非搭车。
- **收益增量极小**：菜单栏常驻项 ≈ 右键菜单的自然度（都是一个动作），成本近零。→ 注入=大成本增量换极小体验增量，且踩稳定/低熵红线。
- **FDA 复发成本的事实**：新用户=patch 一次+加 FDA 一次（"两次"是本机多次重签 cdhash 变的假象）；阻止自动更新已 patch → 微信不自更新 → 稳态下不再重做；只有主动更新那次才需 重打+刷 FDA。
- **降本杠杆**：①已做：阻止自动更新；②GUI 引导/半自动 `tccutil reset SystemPolicyAllFiles com.tencent.xinWeChat`+重加 FDA；③**待实测**：稳定签名是否让 FDA 按签名身份(非 cdhash)记忆→重打补丁后 FDA 不失效（不确定，TCC 细节上已两次判断失误，GUI 阶段验证）。

### M2: 最小原生 App（MVP）—— 产品形态：补丁管理器 GUI
- [ ] 「开新微信」入口 = `NSWorkspace` 新实例（或 `open -n`）；菜单栏常驻项作为 GUI 子功能/开关
  - 稳健性：可带 `-AppleLanguages '(zh-Hans-CN)'` 强制中文，避免继承异常 locale 显示英文。
  - 注：英文界面是「从英语 locale 环境启动」的副作用（如 agent shell `LANG=en_US.UTF-8`），正常 GUI 会话启动即中文，与补丁/FDA 无关。
- [ ] 选定技术栈：SwiftUI + 特权 helper（SMAppService 提权改 /Applications + 重签名）
- [ ] 环境检测面板：微信路径/版本/build（读 Info.plist）；App Store vs 官网版（codesign 看 app-sandbox + 签名权威）
- [ ] App Store 版 → 红条提示「不支持」+ 一键打开 weixin.qq.com
- [ ] 补丁状态检测：读目标二进制偏移处 8 字节，比对是否 = `20008052C0035FD6`（已打/未打/该 build 不支持）—— 不依赖外部状态文件
- [ ] 一键打/卸补丁：退微信→patch→`codesign -f -s -`→重启

### M3: 更新感知与版本守门员（核心稳定性功能）
- [ ] 记录上次 build；启动比对，build 变→提示补丁失效需重打
- [ ] 拉 WeChatTweak 远程 config.json，判断新 build 是否已被官方适配
- [ ] **接管微信自动更新**：应用 WeChatTweak 现成的更新补丁组（startUpdater/startBackgroundUpdatesCheck/checkForUpdates/enableAutoUpdate/automaticallyDownloadsUpdates/canCheckForUpdate 全部 `return 0`）→ 微信永不自升级。协同效应：二进制不被替换→多开补丁不被冲掉。
- [ ] **可控更新**：只允许升到仍被 WeChatTweak 支持的版本，自动下官方 DMG→装→重打补丁。更新永不超出支持范围 = 稳定+低熵。
- [ ] 版本目录数据源：`Rodert/wechat-mac-versions`（覆盖 3.8.10–4.1.9 + 暴露 CDN 链接模式 `dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac_<版本>.dmg`）；`zsbai/wechat-versions`（每日追踪新版+Hash）。
- [ ] 列出/聚焦实例

### 获取支持版的可用直链（2026-06-24 实测）
- 官方 CDN：`https://dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac_4.1.5.dmg` → HTTP 200 ✅（4 位版本号 URL 全 404，腾讯只按 3 位 `4.1.5` 提供）。
- 支持版 build 31927/31960/32281/32288 多为 4.1.5.x → 该 DMG 大概率即支持版，下载后挂载验 `CFBundleVersion` 确认。
- Uptodown 也有精确 4.1.5.28（2025-12-09）。

### M3: 实例管理
- [ ] 列出/聚焦/关闭各实例
- [ ] 方案 B 的克隆管理（创建/删除副本、命名）

### M4: 打磨与分发（未来）
- [ ] 偏好设置、开机自启、状态栏图标
- [ ] 签名 / 公证（要给他人用时）

---

## 5. 环境信息（已探测 2026-06-24）

- 微信安装路径：`/Applications/WeChat.app` ✅
- 微信版本：**4.1.8**（4.x 新架构）
- 沙盒容器路径：`~/Library/Containers/com.tencent.xinWeChat/` ✅ 存在
- BundleID：`com.tencent.xinWeChat`
- macOS 版本：Darwin 25.5.0
- ⚠️ 4.x 是微信 Mac 端的大重写，老的注入类工具适配滞后（见第 8 节）

---

## 6. 开放问题

- **Q1 技术栈**：Swift + SwiftUI（最原生、面向未来）还是先用脚本快速验证再包壳？倾向：先脚本验证 M1，App 本体用 Swift + SwiftUI。
- **Q2 合规/分发**：给他人用涉及微信使用条款，目前自用不展开，到 M4 再评估。
- **Q3 微信自动更新**后克隆副本失效如何优雅处理（方案 B 的维护成本）。

---

## 8. 竞品/现有方案调研：WeChatTweak（2026-06-24）

**结论先行**：若需求仅「多开」，自研外部启动器长期比 WeChatTweak 更稳；WeChatTweak 的不可替代价值是「防撤回」等进程内功能。

### 现状
- `sunnyyoung/WeChatTweak`（主项目，原 WeChatTweak-macOS）：**仍维护**，最新 release 2.0.1（2025-12-09），13.7k star。
- `sunnyyoung/WeChatTweak-CLI`：**已归档（2025-12-05）**，最后版本 1.5（2023-07），功能已合并回主项目。→ CLI 不是新东西，是被弃用的旧物。

### 原理与命门
- WeChatTweak = **dylib 注入微信进程 + 改内部单实例锁**。
- 只支持特定 build 号（如 31927/32281/32288/31960）；微信每次更新就可能失效，需被动等作者重新适配。
- 已有 4.1.x 多开失效的 issue（#962、#946）。本机 4.1.8 是否被适配需实测。
- 副作用：破坏代码签名、改 /Applications 权限，有封号/安全顾虑。

### 与自研的哲学差异（决策依据）
| 维度 | WeChatTweak（进程内注入） | 自研启动器（进程外） |
|---|---|---|
| 功能广度 | 多开+防撤回+防自动更新 | 基本仅多开 |
| 抗微信更新 | 差，每次更新可能坏 | 强，不依赖内部符号 |
| 签名/封号风险 | 高 | 低（克隆仅改 BundleID） |
| 可控性 | 受制于单一作者 | 完全自控 |
| 开发成本 | 0 | 有前期投入 |

### 采纳的策略（D5）
- **D5**：自研外部启动器为主体扛多开（durability 优先）；防撤回等进程内功能作为「未来可选插件」，必要时集成/复用 WeChatTweak，不自己重造注入。与 D1/D2 的「方案 A 默认 / 方案 B 高级」一致。

---

## 9. 三方案交叉比对（沙盒是胜负手）

微信 4.1.8 单实例锁 = 容器内 flock。绕过它只有三条物理路径：

| 路线 | 是否建额外 .app | 是否注入 | 在「沙盒App Store版」上可行？ | 抗微信更新 | 风险 |
|---|---|---|---|---|---|
| **A 克隆 Bundle 改 BundleID** | ✅ 要 | ❌ | 可行，但要重签名/调 entitlements，破坏 MAS 收据 | 中（更新后要重克隆） | 中 |
| **B 注入（WeChatTweak）** | ❌ 不要 | ✅ | 看 build 是否被适配，4.1.x 多开有失效 issue | 差 | 高（破坏签名/封号） |
| **C 重定向数据目录(改 HOME)** | ❌ 不要 | ❌ | **当前沙盒版不可行**（容器被 BundleID 钉死） | 强 | 低 |

**对应用户三个输入：**
- 「不建额外 .app」(偏好) + 「pplx 的数据目录方案」(路线 C) 是同一族：理念正确，但**被沙盒挡死**——只有换成**非 App Store 的官网直装版微信(通常非沙盒)**，C 才成立，届时可经 `HOME` 重定向实现「一个 App、多数据目录、零注入、抗更新」。
- 「一直在用的 GitHub 项目 WeChatTweak」= 路线 B：能满足「不建额外 .app」，但脆、有风险、4.1.8 待验证。

**待验证（M1.5）**：官网直装版微信是否真的非沙盒（决定路线 C 能否成立）。

### M1.5 实测：WeChatTweak 不支持当前 build（2026-06-24）
- 已 `brew install sunnyyoung/tap/wechattweak`（2.0.1，仅装补丁器，未 patch）。
- `wechattweak versions`：当前微信 build **37351**；支持列表 = 31927/32281/32288/31960/**34371**（最高 34371）。
- → **37351 未被适配，路线 B 当前不可用**。未执行 `patch`（对未支持版本 patch 有改坏微信风险）。
- 印证 D5：注入路线对微信更新极脆，第一天就卡住。
- 卸载备忘：`brew uninstall wechattweak`（补丁器本身没碰微信，无需回滚微信）。

### M1.6 关键纠正：路线 C 对 4.x 不成立（2026-06-24）
- 试 `wechattweak patch` → **硬拒绝**：`Error: Unsupported WeChat version (37351)`。路线 B 当前彻底走不通，且无法绕过（需逆向本 build 偏移量）。
- 调研 2026 年 4.x 在 Mac 上所有在用多开法：**几乎全部是「克隆副本+改 BundleID+重签名」**。号称"非沙盒法"的，数据仍在 `/Library/Containers/com.tencent.xinWeChat/`、每个 BundleID 一个子目录 = 本质仍是克隆。
- **纠正 D1/方案 C**：4.x 容器按 BundleID 被系统钉死，`HOME` 重定向**绕不过**，路线 C 不成立。之前的乐观判断作废。
- **新结论（D7）**：对 WeChat 4.x，「不建额外 .app + 不注入」组合**物理上不存在**。唯一不建 .app 的路子是注入（B），当前被版本卡死。要"今天可用"只能走克隆（A）。
- 参考实现：`MaoTouHU/WeChatMulti-macOS`、`CLOUDUH/dual-wechat`（脚本：自动克隆+重签名+更新后自动重建）。本项目原生 App ≈ 把这套做成 GUI。

### 决策点（已定）
用户接受注入；目标改为「给 WeChatTweak 强行加 37351 兼容 / 自研注入」。长期诉求：长期更新、侵略性小、可在开源项目基础上做（注明出处即可，WeChatTweak 是 MIT）。

## 10. WeChatTweak 2.0 机制逆向（2026-06-24，关键）

- **它不是 dylib 注入，是「静态字节 patcher」**：`patch --config <json>` 接受自定义配置。
- 配置来源：`https://raw.githubusercontent.com/sunnyyoung/WeChatTweak/refs/heads/master/config.json`（已存 `/tmp/wt_config.json`）。
- 配置格式：每个 `version`(build号) 下若干 `targets`，每个 target = `identifier` + `entries[{arch, addr, asm}]`。
  - patch 动作 = 在 `addr` 处把字节覆盖成 `asm`。
  - 多数功能 asm=`00008052C0035FD6` = `mov w0,#0; ret`（函数返回0）。
  - **多开 `multiInstance` asm=`20008052C0035FD6` = `mov w0,#1; ret`**（强制"允许多实例"函数返回1）。
- **目标二进制**：wechattweak 字符串证实它只 patch `Contents/MacOS/WeChat`（用 `__TEXT vmaddr` 即 0x100000000 换算文件偏移，`seekToOffset` 写入）。
- 支持的 build：31927/32281/32288/31960/34371。历史 multiInstance 地址都在 `0x1001b8…–0x1001e4…`（主程序 +1.8MB 处）。

### ⚠️ 为什么 37351 加 config 也救不了（根因）
- 4.1.8(37351) 主程序 arm64 段只到 `0x1000cc000`（~836KB）。历史多开地址 `0x1001b82c4` 落在其外。
- 即微信在 34371→37351 间**把这段代码从主程序搬进了 295MB 的 `wechat.dylib`**（主程序瘦身成 1.8MB 壳）。
- WeChatTweak 工具写死 patch 主程序 → 对 4.1.8 **光补 config 不够，要改工具去 patch dylib**。这就是它卡住的真正原因。

### 自研路线（D8）
- 直接在 `wechat.dylib` 里定位「多开闸门函数」，把前 8 字节 patch 成 `20008052C0035FD6`，再重签名 dylib+app。
- 难点：dylib 295MB、本地符号被 strip、闸门函数无具名符号。线索：`lock.ini` 字符串（单例锁）。
- 工具：已装 radare2 6.1.8 + objdump/lldb/otool/dyld_info。
- 逆向产物归档在 `re/`（含 WeChat.bin 主程序副本）。

### RE 进展（2026-06-24）
- radare2 在 295MB dylib 上 `izz`/`iz`/全量分析太慢，单次跑不出，盲扫不可行。
- dylib 仅 ~2311 符号且多为 undefined import；闸门函数无具名符号。`lock.ini` 字符串存在（flock 单例锁线索），但 xref 定位需更系统的方法。
- **可行但成本高的两条精确定位法**（留给后续）：
  1. 签名移植：取支持版(如 34371) dylib 在多开函数处的原始字节签名，在 37351 dylib 里搜同签名。需下载旧版微信二进制。
  2. lock.ini xref：系统化跑 `aav`/`aar` 限定区段，找引用 lock 路径的函数与其单例分支。需可控的 r2 脚本+耐心。
- **结论**：自研 byte-patch 路线技术可行，但 = 每次更新重逆向，与「侵略性小/长期省心」诉求相悖。更鲁棒的长期方向应是 **按符号/特征 hook 的运行时注入**，而非硬编码偏移。

### 待用户定方向（D9）
1. 投入做 DIY dylib patch（我驱动，数小时，脆，每次更新要重做）。
2. 向上游提 issue/PR（附本根因：4.1.8 闸门移入 wechat.dylib，需工具支持 patch dylib）→ 最省长期维护的"不建.app"路径。
3. 先用克隆(路线A)马上可用，并行推进 1 或 2。

## 7. 变更日志

- 2026-06-24：立项，建立目录与本进度文件；确定 D2/D3，明确 MVP 走「启动器」架构；多开默认探索 `open -n` 零复制路线。
- 2026-06-24：探测环境（微信 4.1.8）；调研 WeChatTweak（CLI 已归档、主项目仍维护但依赖注入易随更新失效）；确定 D5 混合策略——自研外部启动器为主、注入类深度功能作可选插件。
