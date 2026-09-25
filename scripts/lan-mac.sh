#!/bin/sh
# lan-mac —— 用 SoC 唯一 ID 给 LAN 口（RTL8111H，无 EEPROM）派生稳定 MAC

IFACE="${LAN_IFACE:-eth1}"

[ -e "/sys/class/net/${IFACE}" ] || exit 0

_sn="$(cat /proc/device-tree/serial-number 2>/dev/null | tr -d '\0')"
[ ${#_sn} -ge 10 ] || exit 0

_mac="02:$(echo "$_sn" | cut -c1-2):$(echo "$_sn" | cut -c3-4):$(echo "$_sn" | cut -c5-6):$(echo "$_sn" | cut -c7-8):$(echo "$_sn" | cut -c9-10)"

[ "$(cat "/sys/class/net/${IFACE}/address")" = "$_mac" ] && exit 0

# 在 ifupdown 的 pre-up 阶段调用时接口本就是 down 的，改完不主动 up，
# 交回给调用方；独立运行时才恢复原状态。
# pre-up 阶段接口本就是 down，别多发 down/up 触发服务重载
_was_up=0
ip link show "$IFACE" 2>/dev/null | grep -q "state UP" && _was_up=1

if [ "$_was_up" -eq 1 ]; then
    ip link set "$IFACE" down
    ip link set "$IFACE" address "$_mac"
    ip link set "$IFACE" up
else
    ip link set "$IFACE" address "$_mac"
fi

echo "[lan-mac] ${IFACE} -> ${_mac}"
