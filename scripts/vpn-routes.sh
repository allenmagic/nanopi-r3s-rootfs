#!/bin/sh
# vpn-routes —— 为 yunshu 的 tun0 维护 fake-IP / DNS 主机路由
#
# 只加路由，不再加 priority 1000 的 ip rule：
#   - sing-box 运行时，auto_route 的 9000 规则优先把 198.18/15 送进 singtun0；
#   - sing-box 停止时，main 表里的 198.18/15 dev tun0 自动兜底；
#   - 旧版本遗留的 priority 1000 规则会让 fake-IP 绕过 sing-box/bridge，必须清掉。
set -eu

VPN_IFACE="${VPN_IFACE:-tun0}"
VPN_FAKEIP_CIDRS="${VPN_FAKEIP_CIDRS:-198.18.0.0/15}"
VPN_DNS_UPSTREAM="${VPN_DNS_UPSTREAM:-10.251.1.1}"
VPN_ROUTES_INTERVAL="${VPN_ROUTES_INTERVAL:-3}"

_cleanup_legacy_rules() {
    for _cidr_ in ${VPN_FAKEIP_CIDRS} "${VPN_DNS_UPSTREAM}/32"; do
        while ip rule del to "${_cidr_}" lookup main 2>/dev/null; do :; done
    done
}

_add() {
    for _cidr_ in ${VPN_FAKEIP_CIDRS}; do
        ip route replace "${_cidr_}" dev "${VPN_IFACE}" 2>/dev/null || true
    done
    if [ -n "${VPN_DNS_UPSTREAM:-}" ]; then
        ip route replace "${VPN_DNS_UPSTREAM}/32" dev "${VPN_IFACE}" 2>/dev/null || true
    fi
    _cleanup_legacy_rules
}

_del() {
    for _cidr_ in ${VPN_FAKEIP_CIDRS}; do
        ip route del "${_cidr_}" dev "${VPN_IFACE}" 2>/dev/null || true
    done
    if [ -n "${VPN_DNS_UPSTREAM:-}" ]; then
        ip route del "${VPN_DNS_UPSTREAM}/32" dev "${VPN_IFACE}" 2>/dev/null || true
    fi
    _cleanup_legacy_rules
}

_daemon() {
    while :; do
        if ip link show "${VPN_IFACE}" >/dev/null 2>&1; then
            _add
        fi
        sleep "${VPN_ROUTES_INTERVAL}"
    done
}

case "${1:-daemon}" in
    daemon) _daemon ;;
    add)    _add ;;
    del)    _del ;;
    *)      echo "用法: $0 {daemon|add|del}" >&2; exit 2 ;;
esac
