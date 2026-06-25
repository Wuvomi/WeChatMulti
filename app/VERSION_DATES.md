# 微信版本 → 近似发布日期（版本多旧的直观参考）

版本号本身没有时间含义。这里给每个 marketing version 标一个**近似发布月（YYYY-MM）**，
让用户对"当前微信版本多旧"有直观感（越旧失效风险越高）。**月级近似即可，不追求精确到天。**

实现位置：
- 数据 + 查找逻辑：`Sources/WeChatMulti/WeChatModel.swift`
  - `builtinReleaseDates`（内置离线兜底，保证一定有数据）
  - `onlineReleaseDates` + `fetchReleaseDates()`（可选在线增强，拉不到就用内置，绝不阻塞 UI / 不报错）
  - `releaseDate`（当前版本的近似月；在线优先 → 内置兜底 → nil）
- 显示：`Sources/WeChatMulti/ContentView.swift` 的 `versionValue`
  当前微信版本行示例：`4.1.11 (269077) · 发布于 2026-06`；匹配不到 → 只显版本号（不报错）。
- 本地化：`Resources/{zh-Hans,en}.lproj/Localizable.strings` 词条 `"发布于 %@"`（英文 `released %@`）。

## 数据来源

主来源（权威、可引用）：**微信官方更新日志**
- https://weixin.qq.com/updates?platform=mac
- 单版本页示例：https://weixin.qq.com/updates/mac/4111?head=true （确认 4.1.11 = 2026-06-24）

build 级细化参考（CFBundleShortVersionString 只有 3 段，对应多个内部 build）：
- https://github.com/zsbai/wechat-versions/releases （4 段版本如 4.1.11.21 → 日期）

注：微信 `CFBundleVersion`（6 位数字 build，如 `269077`）未被公开追踪站收录，
无法精确映射到天；按 marketing version 对到月级（4.1.11 → 2026-06）已满足需求。

## 内置 map（marketing version → YYYY-MM，置信度均为高，除注明）

| 版本 | 近似发布月 | 置信度 |
|---|---|---|
| 4.1.11 | 2026-06 | 高（官方确认 2026-06-24）|
| 4.1.10 | 2026-05 | 高 |
| 4.1.9  | 2026-04 | 高 |
| 4.1.8  | 2026-03 | 高 |
| 4.1.7  | 2026-01 | 高 |
| 4.1.6  | 2025-12 | 高 |
| 4.1.5  | 2025-11 | 高 |
| 4.1.4  | 2025-11 | 高 |
| 4.1.2  | 2025-10 | 高 |
| 4.1.1  | 2025-09 | 高 |
| 4.1.0  | 2025-08 | 高 |
| 4.0.6  | 2025-07 | 高 |
| 4.0.5  | 2025-05 | 高 |
| 4.0.3  | 2025-03 | 高 |
| 3.8.9  | 2024-09 | 高 |
| 3.8.8  | 2024-05 | 高 |
| 3.8.7  | 2024-03 | 高 |
| 3.8.6  | 2023-12 | 中 |
| 3.8.5  | 2023-11 | 中 |
| 3.8.4  | 2023-10 | 中 |
| 3.8.2  | 2023-08 | 中 |
| 3.8.1  | 2023-07 | 中 |
| 3.8.0  | 2023-05 | 中 |

## 如何更新

1. 新版本发布后，到官方更新日志查发布日，取年-月。
2. 在 `WeChatModel.swift` 的 `builtinReleaseDates` 里加一行 `"<版本>": "<YYYY-MM>"`。
3. 同步更新本文件的表格。
4. `swift build -c release && ./build.sh` 验证。

可选在线 map（`fetchReleaseDates()` 拉取）期望 JSON 格式：
```json
{ "4.1.11": "2026-06", "4.1.10": "2026-05" }
```
URL 当前指向 `zsbai/wechat-versions/master/mac-release-dates.json`（占位；该文件不存在也不影响，
会静默回退到内置 map）。要启用在线增强，把上面 JSON 放到该路径或改 `fetchReleaseDates()` 里的 URL 即可。
