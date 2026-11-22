#!/bin/sh
# enable-ssh-password.sh [root-prefix]
#
# 允许 SSH 密码登录（路由器默认只有 root 用户，密码由 setup 设置）。
# WAN 侧仍然由 nftables 拒绝，只放行 LAN / VPN / TUN / WAN 同网段管理。
#
# chroot 内调用：/bin/sh /scripts/enable-ssh-password.sh
# Gentoo 宿主机调用：/bin/sh scripts/enable-ssh-password.sh "$TARGET_ROOTFS"
set -eu

ROOT="${1:-}"
CFG="${ROOT}/etc/ssh/sshd_config"

[ -f "${CFG}" ] || exit 0

_set_opt() {
    _opt_="$1"
    _val_="$2"

    if grep -qE "^[[:space:]]*${_opt_}([[:space:]]|$)" "${CFG}"; then
        sed -i "s|^[[:space:]]*${_opt_}.*|${_opt_} ${_val_}|" "${CFG}"
        return 0
    fi

    # 插在第一个生效的 Match 之前，避免配置落进 Match 块
    if grep -qE '^[[:space:]]*Match[[:space:]]' "${CFG}"; then
        awk -v ins="${_opt_} ${_val_}" '
            BEGIN { done = 0 }
            /^[[:space:]]*Match[[:space:]]/ && !done { print ins; done = 1 }
            { print }
            END { if (!done) print ins }
        ' "${CFG}" > "${CFG}.tmp" && mv -f "${CFG}.tmp" "${CFG}"
    else
        printf '\n%s %s\n' "${_opt_}" "${_val_}" >> "${CFG}"
    fi
}

_set_opt PasswordAuthentication yes
_set_opt PermitRootLogin yes

echo "[ssh] ${CFG}: PasswordAuthentication=yes PermitRootLogin=yes"
