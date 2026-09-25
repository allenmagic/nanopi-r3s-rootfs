#!/bin/sh
#
# lan-mac —— 给 LAN 口（PCIe RTL8111H）派生稳定 MAC
#
# 该芯片没有 EEPROM，内核读不到 MAC 会每次开机随机生成一个
# （dmesg: "can't read MAC address, setting random one"），
# 破坏 ARP 缓存和按 MAC 的绑定。这里用 SoC 唯一 ID 派生本地管理地址。
#

IFACE="${LAN_IFACE:-eth1}"

[ -e "/sys/class/net/${IFACE}" ] || exit 0

_sn="$(cat /proc/device-tree/serial-number 2>/dev/null | tr -d '\0')"
[ ${#_sn} -ge 10 ] || exit 0

_mac="02:$(echo "$_sn" | cut -c1-2):$(echo "$_sn" | cut -c3-4):$(echo "$_sn" | cut -c5-6):$(echo "$_sn" | cut -c7-8):$(echo "$_sn" | cut -c9-10)"

[ "$(cat "/sys/class/net/${IFACE}/address")" = "$_mac" ] && exit 0

# 在 ifupdown 的 pre-up 阶段调用时接口本就是 down 的，改完不主动 up，
# 交回给调用方；独立运行时才恢复原状态。
_was_up=0
ip link show "$IFACE" 2>/dev/null | grep -q "state UP" && _was_up=1

ip link set "$IFACE" down
ip link set "$IFACE" address "$_mac"
[ "$_was_up" -eq 1 ] && ip link set "$IFACE" up

echo "[lan-mac] ${IFACE} -> ${_mac}"
