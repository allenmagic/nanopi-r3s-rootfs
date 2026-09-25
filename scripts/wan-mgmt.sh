#!/bin/sh
set -eu

NFT_SET="inet filter wan_mgmt_nets"
STATE_FILE="${WAN_MGMT_STATE:-/run/wan-mgmt.state}"
INTERVAL="${WAN_MGMT_INTERVAL:-30}"

_wan_iface() {
    if [ -n "${WAN_IFACE:-}" ]; then
        printf '%s\n' "${WAN_IFACE}"
        return 0
    fi
    _i_="$(sed -n 's/^define[[:space:]]\+WAN[[:space:]]*=[[:space:]]*//p' \
            /etc/nftables.d/00-inet-vars.nft 2>/dev/null | head -n1)"
    printf '%s\n' "${_i_:-eth0}"
}

_want() {
    ip -4 route show dev "$(_wan_iface)" scope link 2>/dev/null \
        | awk '{print $1}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
        | sort
}

_sync() {
    _w_="$(_want)"
    _c_="$(cat "${STATE_FILE}" 2>/dev/null || true)"
    [ "${_w_}" = "${_c_}" ] && return 0

    {
        echo "flush set ${NFT_SET}"
        for _n_ in ${_w_}; do
            echo "add element ${NFT_SET} { ${_n_} }"
        done
    } | nft -f - || return 1

    printf '%s\n' "${_w_}" > "${STATE_FILE}"
}

case "${1:-update}" in
    update) _sync ;;
    daemon)
        while :; do
            _sync || true
            sleep "${INTERVAL}"
        done
        ;;
    *)
        echo "用法: $0 {update|daemon}" >&2
        exit 2
        ;;
esac
