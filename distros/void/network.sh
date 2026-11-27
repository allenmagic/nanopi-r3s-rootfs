#
# distros/void/network.sh —— Void (runit/dhcpcd) 网络配置
#   被 setup.sh source 调用
#   定义 configure_network() 函数
#

configure_network() {
    echo "[network] === 配置网络 (Void/dhcpcd) ==="
    . /network.env

    _replace_placeholders

    # WAN: dhcpcd 默认接管所有接口并自动 DHCP，无需额外配置
    # LAN: 追加静态 IP 到 dhcpcd.conf，nodhcp 防止 dhcpcd 在 LAN 口发 DHCP 请求，
    #       nogateway 防止 dhcpcd 添加默认路由（WAN 口已经有一条）
    cat >> /etc/dhcpcd.conf << EOF
interface ${LAN_IFACE}
static ip_address=${LAN_IP}/${LAN_CIDR}
nodhcp
nogateway
EOF

    # dhcpcd 没有 ifupdown 的 pre-up；把 lan-mac 塞进服务启动脚本，
    # 保证 LAN 口在 dhcpcd 配置地址前就拿到稳定 MAC
    # （RTL8111H 无 EEPROM，否则每次开机 MAC 随机）。保留包自带启动参数。
    if [ -d /etc/sv/dhcpcd ]; then
        cat > /etc/sv/dhcpcd/run << EOF
#!/bin/sh
exec 2>&1
[ -r conf ] && . ./conf
[ -x /usr/local/bin/lan-mac ] && LAN_IFACE=${LAN_IFACE} /usr/local/bin/lan-mac
exec dhcpcd -B \${OPTS:--M -q} 1>&2
EOF
        chmod +x /etc/sv/dhcpcd/run
    fi

    echo "[network] === 网络配置完成 ==="
}

# 通用占位符替换（所有 distro 共用逻辑）
_replace_placeholders() {
    # dnsmasq DHCP 配置
    for _f_ in /etc/dnsmasq.d/*.conf; do
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
    _NFT="/etc/nftables.d/00-inet-vars.nft"
    if [ -f "${_NFT}" ]; then
        sed -i \
            -e "s|__WAN_IFACE__|${WAN_IFACE}|g" \
            -e "s|__LAN_IFACE__|${LAN_IFACE}|g" \
            -e "s|__ROUTER_LAN_IP__|${LAN_IP}|g" \
            -e "s|__LAN_NET__|${LAN_NETWORK}|g" \
            "${_NFT}"
    fi
    # sing-box config / rule sets（仅 INFRA=sing-box 时存在）
    for _f_ in /etc/sing-box/config.json /etc/sing-box/rules/*.json; do
        [ -f "${_f_}" ] || continue
        sed -i \
            -e "s|__LAN_IP__|${LAN_IP}|g" \
            -e "s|__LAN_NET__|${LAN_NETWORK}|g" \
            -e "s|__LAN_IFACE__|${LAN_IFACE}|g" \
            -e "s|__ROUTER_HOSTNAME__|${HOSTNAME_VAL}|g" \
            "${_f_}"
    done
    # sing-box Dashboard API：每个构建生成随机 Secret，写入 api.secret 供登录使用
    if [ -f /etc/sing-box/config.json ] && \
       grep -q '__SINGBOX_API_SECRET__' /etc/sing-box/config.json; then
        _sb_secret_="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        sed -i "s|__SINGBOX_API_SECRET__|${_sb_secret_}|g" /etc/sing-box/config.json
        printf '%s\n' "${_sb_secret_}" > /etc/sing-box/api.secret
        chmod 600 /etc/sing-box/api.secret
    fi
}
