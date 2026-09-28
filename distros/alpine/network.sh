#
# distros/alpine/network.sh —— Alpine (OpenRC/ifupdown) 网络配置
#   被 setup.sh source 调用
#   定义 configure_network() 函数
#

configure_network() {
    echo "[network] === 配置网络 (Alpine/ifupdown) ==="
    . /network.env

    _replace_placeholders

    # landscape 自己建 br_lan、自己跑 WAN 的 DHCP 客户端；ifupdown 再碰 eth0/eth1
    # 就是两边抢着改地址和路由。只留 lo，networking 服务照常启用。
    # eth1 的 MAC 由 landscape-router 的 start_pre 调 lan-mac 处理。
    case ",${INFRA:-base}," in
        *",landscape,"*)
            cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback
EOF
            echo "[network] landscape 模式：ifupdown 仅配置 lo"
            echo "[network] === 网络配置完成 ==="
            return 0
            ;;
    esac

    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto ${WAN_IFACE}
iface ${WAN_IFACE} inet dhcp

auto ${LAN_IFACE}
iface ${LAN_IFACE} inet static
    pre-up /usr/local/bin/lan-mac
    address ${LAN_IP}
    netmask ${LAN_NETMASK}
EOF

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
}
