#!/bin/sh
# lan-mac —— 用 SoC 唯一 ID 给 LAN 口（RTL8111H，无 EEPROM）派生稳定 MAC

IFACE="${LAN_IFACE:-eth1}"

[ -e "/sys/class/net/${IFACE}" ] || exit 0

_sn="$(cat /proc/device-tree/serial-number 2>/dev/null | tr -d '\0')"
[ ${#_sn} -ge 10 ] || exit 0

_mac="02:$(echo "$_sn" | cut -c1-2):$(echo "$_sn" | cut -c3-4):$(echo "$_sn" | cut -c5-6):$(echo "$_sn" | cut -c7-8):$(echo "$_sn" | cut -c9-10)"

[ "$(cat "/sys/class/net/${IFACE}/address")" = "$_mac" ] && exit 0

# up 着的接口改 MAC 报 EBUSY 得先 down；直接试一次比判断 ip 是 busybox 还是 iproute2 稳
if ! ip link set "$IFACE" address "$_mac" 2>/dev/null; then
    ip link set "$IFACE" down
    ip link set "$IFACE" address "$_mac"
    ip link set "$IFACE" up
fi

echo "[lan-mac] ${IFACE} -> ${_mac}"
