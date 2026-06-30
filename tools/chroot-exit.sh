#!/usr/bin/env bash
# chroot-exit.sh —— 清理 chroot 挂载点 + 收尾
set -uo pipefail

ROOTFS="${1:-$HOME/Downloads/devuan}"

# 自动 sudo 重入
[ "${EUID}" -eq 0 ] || exec sudo -E "$0" "$@"

# 规范化为绝对路径，去掉结尾斜杠（mount 列表里是绝对路径）
ROOTFS="$(readlink -f "$ROOTFS")"

echo "==> 目标 rootfs: $ROOTFS"

if [ ! -d "$ROOTFS" ]; then
  echo "ERROR: 目录不存在: $ROOTFS" >&2
  exit 1
fi

# 1) 卸载所有挂在 $ROOTFS 下的挂载点（先卸最深层的）
echo "==> 卸载挂载点..."
awk -v r="$ROOTFS" '$2 ~ ("^"r) {print $2}' /proc/mounts | sort -r > /tmp/chroot-mounts-$$.txt
if [ ! -s /tmp/chroot-mounts-$$.txt ]; then
  echo "    （没有发现挂载点，可能已清理）"
else
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    if sudo umount "$m" 2>/dev/null; then
      echo "    [OK]   $m"
    else
      if sudo umount -lf "$m" 2>/dev/null; then
        echo "    [LAZY] $m"
      else
        echo "    [FAIL] $m  （仍占用，请检查是否还有进程在用）" >&2
      fi
    fi
  done < /tmp/chroot-mounts-$$.txt
fi
rm -f /tmp/chroot-mounts-$$.txt

# 2) 删除拷进去的 qemu 模拟器
QEMU="$ROOTFS/usr/bin/qemu-aarch64-static"
if [ -e "$QEMU" ]; then
  echo "==> 删除 qemu 模拟器: $QEMU"
  sudo rm -f "$QEMU"
fi

# 3) 还原 resolv.conf
RESOLV="$ROOTFS/etc/resolv.conf"
if [ -e "$RESOLV" ]; then
  echo "==> 清空 chroot 阶段写入的 resolv.conf"
  : | sudo tee "$RESOLV" >/dev/null
fi

# 4) 最终校验
echo "==> 校验残留挂载..."
if awk -v r="$ROOTFS" '$2 ~ ("^"r)' /proc/mounts | grep -q .; then
  echo "WARNING: 仍有挂载点未清理：" >&2
  awk -v r="$ROOTFS" '$2 ~ ("^"r) {print "    "$2}' /proc/mounts >&2
  exit 1
else
  echo "    全部卸载完毕 ✅"
fi

echo "==> 清理完成，rootfs 可以安全打包。"
