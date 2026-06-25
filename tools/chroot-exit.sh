#!/usr/bin/env bash
# devuan-chroot-exit.sh —— 清理 chroot 挂载点 + 收尾
set -uo pipefail

ROOTFS="${1:-$HOME/Downloads/devuan}"

# 规范化为绝对路径，去掉结尾斜杠（mount 列表里是绝对路径）
ROOTFS="$(readlink -f "$ROOTFS")"

echo "==> 目标 rootfs: $ROOTFS"

if [ ! -d "$ROOTFS" ]; then
  echo "ERROR: 目录不存在: $ROOTFS" >&2
  exit 1
fi

# 1) 卸载所有挂在 $ROOTFS 下的挂载点（按路径长度倒序，先卸最深的）
echo "==> 卸载挂载点..."
# 从 /proc/mounts 抓出所有以 $ROOTFS 开头的挂载点
mapfile -t MNTS < <(awk -v r="$ROOTFS" '$2 ~ ("^"r) {print $2}' /proc/mounts \
                    | sort -r)   # 倒序：dev/pts 在 dev 前面先卸

if [ "${#MNTS[@]}" -eq 0 ]; then
  echo "    （没有发现挂载点，可能已清理）"
else
  for m in "${MNTS[@]}"; do
    if sudo umount "$m" 2>/dev/null; then
      echo "    [OK]   $m"
    else
      # 普通卸载失败（busy），用 lazy 兜底
      if sudo umount -lf "$m" 2>/dev/null; then
        echo "    [LAZY] $m"
      else
        echo "    [FAIL] $m  （仍占用，请检查是否还有进程在用）" >&2
      fi
    fi
  done
fi

# 2) 删除拷进去的 qemu 模拟器（避免留在最终 rootfs 里）
QEMU="$ROOTFS/usr/bin/qemu-aarch64-static"
if [ -e "$QEMU" ]; then
  echo "==> 删除 qemu 模拟器: $QEMU"
  sudo rm -f "$QEMU"
fi

# 3) 还原 resolv.conf（chroot 时我们覆盖过它；可选，保持 rootfs 干净）
#    如果你希望 rootfs 自带某个 resolv.conf，这里按需调整或注释掉
RESOLV="$ROOTFS/etc/resolv.conf"
if [ -e "$RESOLV" ]; then
  echo "==> 清空 chroot 阶段写入的 resolv.conf（留空给目标系统自管）"
  : | sudo tee "$RESOLV" >/dev/null
fi

# 4) 最终校验：确认没有任何残留挂载
echo "==> 校验残留挂载..."
if awk -v r="$ROOTFS" '$2 ~ ("^"r)' /proc/mounts | grep -q .; then
  echo "WARNING: 仍有挂载点未清理：" >&2
  awk -v r="$ROOTFS" '$2 ~ ("^"r) {print "    "$2}' /proc/mounts >&2
  exit 1
else
  echo "    全部卸载完毕 ✅"
fi

echo "==> 清理完成，rootfs 可以安全打包。"
