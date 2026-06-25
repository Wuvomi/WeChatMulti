# WeChatMulti

本机微信多开工具（macOS 原生 App）。当前自用，保留未来迭代与分发的可能。

## 文档导航
- **[PROJECT.md](./PROJECT.md)** — 进度与决策的唯一权威记录。换对话/隔很久回来，先读它恢复上下文。
- `docs/` — 技术调研笔记。

## 一句话原理
App 本体是个「启动器」，通过 `open -n`（或 `NSWorkspace` 新实例）拉起多个微信进程；需要多账号数据隔离时，再走「克隆 Bundle」高级模式。详见 PROJECT.md 第 3 节。

## 状态
立项 / 技术调研阶段 —— 见 PROJECT.md「当前状态」。
