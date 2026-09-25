#!/bin/sh
# rootfs-resize —— 把根分区扩到 SD 卡实际大小（幂等）
# 依赖 growpart / resize2fs；内核需 BLK_DEV_WRITE_MOUNTED=y

set -e

# openrc 的 local 服务 PATH 不含 sbin，而 gentoo 的 growpart 装在 /usr/sbin
PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH}"
export PATH

# 必须传 /proc/mounts 里的原名：resize2fs 靠字符串比对判断是否已挂载
_root="$(findmnt -no SOURCE / 2>/dev/null)"
[ -n "$_root" ] || _root=/dev/root
_real="$(readlink -f "$_root")"

[ -b "$_real" ] || exit 0

_disk="/dev/$(lsblk -no PKNAME "$_real" 2>/dev/null)"
[ -b "$_disk" ] || exit 0

_pnum="${_real##*"$(basename "$_disk")"p}"
case "$_pnum" in ''|*[!0-9]*) exit 0 ;; esac

# 真实空闲须减去分区起始扇区，否则起始偏移会被当成未分配空间
_pname="$(basename "$_real")"
_free_sectors=$(( $(cat "/sys/class/block/$(basename "$_disk")/size") \
                  - $(cat "/sys/class/block/$_pname/start") \
                  - $(cat "/sys/class/block/$_pname/size") ))

# 给备份 GPT 留 1MiB
if [ "$_free_sectors" -lt 2048 ]; then
    exit 0
fi

echo "[rootfs-resize] ${_disk} 未分配 $(( _free_sectors / 2048 )) MiB，开始扩容"

# 分区扩到磁盘末尾（起始扇区不变，内核视图一并更新）
growpart "$_disk" "$_pnum" || true

[ -e "$_root" ] || ln -sf "$_real" "$_root"

if resize2fs "$_root" >/dev/null 2>&1; then
    echo "[rootfs-resize] 完成，/ 现有 $(df -h / | awk 'NR==2{print $2}')"
else
    echo "[rootfs-resize] resize2fs 失败"
    exit 1
fi
