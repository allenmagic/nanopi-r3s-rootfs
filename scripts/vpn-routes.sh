#!/bin/sh
set -eu

VPN_IFACE="${VPN_IFACE:-tun0}"
VPN_FAKEIP_CIDRS="${VPN_FAKEIP_CIDRS:-198.18.0.0/15}"
VPN_ROUTES_INTERVAL="${VPN_ROUTES_INTERVAL:-3}"

_add() {
    for _cidr_ in ${VPN_FAKEIP_CIDRS}; do
        ip route replace "${_cidr_}" dev "${VPN_IFACE}" 2>/dev/null || true
    done
}

_del() {
    for _cidr_ in ${VPN_FAKEIP_CIDRS}; do
        ip route del "${_cidr_}" dev "${VPN_IFACE}" 2>/dev/null || true
    done
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
