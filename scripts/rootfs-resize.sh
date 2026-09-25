#!/bin/sh
#
# rootfs-resize —— 把根分区扩到 SD 卡的实际大小（幂等）
#
# 镜像里的分区只比 rootfs 大 256MB，dd 到大容量卡后其余空间全浪费；备份
# GPT 头也停在原镜像末尾。开机时把两者一并补齐。
#
# 依赖：util-linux、cloud-utils-growpart、e2fsprogs-extra（resize2fs）
#      内核需 CONFIG_BLK_DEV_WRITE_MOUNTED=y —— 关掉的话 resize2fs 连读超级块
#      都打不开已挂载的设备（EBUSY），在线扩容无从谈起。
#

set -e

# 传 /proc/mounts 里的原名（通常就是 /dev/root）给 resize2fs：它靠字符串比对
# 判断文件系统是否已挂载，名字对不上就会跑去走离线路径写一个已挂载的设备。
_root="$(findmnt -no SOURCE / 2>/dev/null)"
[ -n "$_root" ] || _root=/dev/root
_real="$(readlink -f "$_root")"

[ -b "$_real" ] || exit 0

_disk="/dev/$(lsblk -no PKNAME "$_real" 2>/dev/null)"
[ -b "$_disk" ] || exit 0

_pnum="${_real##*"$(basename "$_disk")"p}"
case "$_pnum" in ''|*[!0-9]*) exit 0 ;; esac

# 真实空闲 = 磁盘扇区数 - 分区起始 - 分区扇区数。
# 不能直接拿分区大小比磁盘大小 —— 分区从 32768 扇区才起，那 16MiB 起始偏移
# 会被当成未分配空间，导致每次开机都白跑一遍。
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
