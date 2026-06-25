#!/bin/bash
# cleanup-clone.sh — 删除一个克隆实例的全部残留(供 GUI 删克隆 / 重置时调用)。
#
# 删除三处:
#   1) 克隆 .app 本体
#   2) 数据容器  ~/Library/Containers/com.tencent.xinCloneN
#   3) app-group 容器 ~/Library/Group Containers/5A4RE8SF68.com.tencent.xinCloneN
#
# ★ 重要(TCC 限制,实测):
#   ~/Library/Containers/<bundle>/.com.apple.containermanagerd.metadata.plist 受
#   macOS 的 "完全磁盘访问(Full Disk Access)" TCC 保护(非 SIP/rootless,无 restricted flag)。
#   → 不带 FDA 的进程 rm 该文件会 "Operation not permitted",容器目录删不掉(剩 36KB 空壳)。
#   → 调用本脚本的进程(GUI 主程序 / 其 Terminal)必须已被授予【完全磁盘访问】,
#     才能彻底删除数据容器。group 容器与 .app 本体不受此限,任何进程都能删。
#   GUI 落地:在"清理克隆"动作前检测 FDA(尝试读 ~/Library/Application Support/com.apple.TCC/),
#     未授予则引导用户到 系统设置 > 隐私与安全性 > 完全磁盘访问 勾选本 App。
#
# 用法:
#   cleanup-clone.sh <N> [克隆.app所在目录]
# 例:
#   cleanup-clone.sh 1
#   cleanup-clone.sh 2 ~/Apps
set -uo pipefail

log() { echo "[cleanup] $*"; }

N="${1:-}"
[ -n "$N" ] || { echo "用法: $0 <N> [克隆目录]" >&2; exit 1; }
case "$N" in *[!A-Za-z0-9]*) echo "[cleanup][ERR] N 只能字母数字: $N" >&2; exit 1;; esac

CLONE_DIR="${2:-$HOME/Library/Application Support/WeChatMulti/Clones}"
APP="$CLONE_DIR/WeChatClone${N}.app"
NEW_ID="com.tencent.xinClone${N}"
TEAM="5A4RE8SF68"
DATA_C="$HOME/Library/Containers/${NEW_ID}"
GROUP_C="$HOME/Library/Group Containers/${TEAM}.${NEW_ID}"
GROUP_C2="$HOME/Library/Group Containers/${NEW_ID}"   # 早期无 team 前缀变体(兼容清理)

# 0) 先杀掉在跑的该克隆进程
pkill -f "WeChatClone${N}.app/Contents/MacOS/WeChat" 2>/dev/null && log "已结束在跑的克隆进程" || true
sleep 1

# 1) .app 本体
if [ -e "$APP" ]; then rm -rf "$APP" && log ".app 已删: $APP" || log "WARN .app 删除失败: $APP"; fi

# 2) group 容器(不受 FDA 限制)
for g in "$GROUP_C" "$GROUP_C2"; do
  if [ -e "$g" ]; then
    rm -rf "$g" & RP=$!; ( sleep 60; kill -9 $RP 2>/dev/null ) & WP=$!; wait $RP 2>/dev/null; kill $WP 2>/dev/null
    [ -e "$g" ] && log "WARN group 容器删除失败: $g" || log "group 容器已删: $g"
  fi
done

# 3) 数据容器(需 FDA)
if [ -e "$DATA_C" ]; then
  rm -rf "$DATA_C" & RP=$!; ( sleep 60; kill -9 $RP 2>/dev/null ) & WP=$!; wait $RP 2>/dev/null; kill $WP 2>/dev/null
  if [ -e "$DATA_C" ]; then
    log "WARN 数据容器未能删除(很可能本进程缺【完全磁盘访问】): $DATA_C"
    log "      请到 系统设置 > 隐私与安全性 > 完全磁盘访问 授予本 App 后重试,"
    log "      或在 访达 中手动删除该目录(会弹一次授权)。"
    exit 2
  else
    log "数据容器已删: $DATA_C"
  fi
fi

log "克隆 $N 残留清理完成。"
