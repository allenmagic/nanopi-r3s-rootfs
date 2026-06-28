#!/usr/bin/env bash
# chroot-in.sh <rootfs_dir>  —— 通用 aarch64 rootfs chroot
set -euo pipefail

ROOTFS="$(readlink -f "${1:-$HOME/Downloads/devuan}")"
[ -d "$ROOTFS" ] || { echo "ERROR: $ROOTFS 不存在" >&2; exit 1; }

# 探测 shell（兼容 Alpine 无 bash）
if   [ -x "$ROOTFS/bin/bash" ]; then SHELL_IN=/bin/bash
elif [ -x "$ROOTFS/bin/sh"  ]; then SHELL_IN=/bin/sh
else echo "ERROR: rootfs 内无可用 shell" >&2; exit 1; fi
echo "==> rootfs: $ROOTFS  (shell: $SHELL_IN)"

# 拷 qemu（名字兜底）
QEMU_BIN="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
if [ -n "$QEMU_BIN" ] && [ ! -e "$ROOTFS/usr/bin/qemu-aarch64-static" ]; then
  sudo cp "$QEMU_BIN" "$ROOTFS/usr/bin/qemu-aarch64-static"
fi

# 挂载（幂等）
mnt() { mountpoint -q "$2" || { sudo mkdir -p "$2"; sudo mount "${@:3}" "$1" "$2" && echo "  挂载 $2"; }; }
mnt proc     "$ROOTFS/proc"    -t proc
mnt sysfs    "$ROOTFS/sys"     -t sysfs
mnt /dev     "$ROOTFS/dev"     --bind
mnt /dev/pts "$ROOTFS/dev/pts" --bind

sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true

echo "==> 进入 chroot（exit 后跑 chroot-exit.sh $ROOTFS 清理）"
sudo chroot "$ROOTFS" /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  TERM="$TERM" \
  HOME=/root \
  "$SHELL_IN" -i
