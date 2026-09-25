#
# distros/gentoo/network.sh —— Gentoo (OpenRC/netifrc) 网络配置
#   被 setup.sh source 调用，运行在 stage3 环境内
#   操作目标为 TARGET_ROOTFS（/gentoo-rootfs），不是当前根文件系统
#

configure_network() {
    echo "[network] === 配置网络 (Gentoo/netifrc) ==="
    . /network.env

    _replace_placeholders

    # netifrc 配置：WAN DHCP + LAN static
    # modules="!plug"：否则 netifrc 用 busybox 的 ifplugd 把接口 background 掉，永久停摆
    # preup：LAN 口无 EEPROM，MAC 每次开机随机，配 IP 前先钉住
    cat > "${TARGET_ROOTFS}/etc/conf.d/net" << EOF
config_${WAN_IFACE}="dhcp"
config_${LAN_IFACE}="${LAN_IP}/${LAN_CIDR}"
modules="!plug"

preup() {
    [ "\${IFACE}" = "${LAN_IFACE}" ] || return 0
    LAN_IFACE="\${IFACE}" /usr/local/bin/lan-mac
    return 0
}
EOF

    # 激活 netifrc 接口（符号链接 /etc/init.d/net.lo -> net.<iface>）
    ln -sf net.lo "${TARGET_ROOTFS}/etc/init.d/net.${LAN_IFACE}"
    ln -sf net.lo "${TARGET_ROOTFS}/etc/init.d/net.${WAN_IFACE}"

    echo "[network] === 网络配置完成 ==="
}

# 通用占位符替换（所有 distro 共用逻辑）
_replace_placeholders() {
    # dnsmasq DHCP 配置
    for _f_ in "${TARGET_ROOTFS}"/etc/dnsmasq.d/*.conf; do
        [ -f "${_f_}" ] || continue
        sed -i \
            -e "s|__LAN_IFACE__|${LAN_IFACE}|g" \
            -e "s|__LAN_IP__|${LAN_IP}|g" \
            -e "s|__DHCP_RANGE_START__|${DHCP_RANGE_START}|g" \
            -e "s|__DHCP_RANGE_END__|${DHCP_RANGE_END}|g" \
            -e "s|__DHCP_LEASE_TIME__|${DHCP_LEASE_TIME}|g" \
            -e "s|__LAN_NETMASK__|${LAN_NETMASK}|g" \
            -e "s|__LAN_NETWORK__|${LAN_NETWORK}|g" \
            "${_f_}"
    done
    # nftables vars
    _NFT="${TARGET_ROOTFS}/etc/nftables.d/00-inet-vars.nft"
    if [ -f "${_NFT}" ]; then
        sed -i \
            -e "s|__WAN_IFACE__|${WAN_IFACE}|g" \
            -e "s|__LAN_IFACE__|${LAN_IFACE}|g" \
            -e "s|__ROUTER_LAN_IP__|${LAN_IP}|g" \
            -e "s|__LAN_NET__|${LAN_NETWORK}|g" \
            "${_NFT}"
    fi
}
