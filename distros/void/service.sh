#
# distros/void/service.sh —— Void (runit) 服务启用
#   被 setup.sh source 调用
#   定义 enable_router_services() 函数
#

enable_router_services() {
    echo "[service] === 启用路由器服务 (INFRA=${INFRA:-base}) ==="

    # --- base 服务（按依赖顺序）---
    # 1. 防火墙（最先加载）
    _enable_nftables

    # 2. 核心网络服务
    _enable_service dnsmasq

    # 3. 基础应用服务
    _enable_service sshd
    _enable_service chronyd

    # 4. VPN 和隧道服务
    _enable_service tailscaled
    _enable_cloudflared

    # --- 根据 INFRA 启用组件服务 ---
    case ",${INFRA:-base}," in
        *",sing-box,"*)
            echo "[service] --- sing-box 服务 ---"
            _enable_singbox
            ;;
    esac

    echo "[service] === 服务启用完成 ==="
}

# 通用服务启用
_enable_service() {
    _svc_="$1"
    if [ -d "/etc/sv/${_svc_}" ]; then
        mkdir -p /etc/runit/runsvdir/default
        rm -f "/etc/runit/runsvdir/default/${_svc_}"
        ln -s "/etc/sv/${_svc_}" "/etc/runit/runsvdir/default/${_svc_}"
        echo "[service]   启用: ${_svc_}"
    else
        echo "[service]   警告: /etc/sv/${_svc_} 不存在" >&2
    fi
}

# nftables 开机加载
_enable_nftables() {
    echo "[service] 启用 nftables 开机加载 ..."
    mkdir -p /etc/runit/runsvdir/default
    rm -f /etc/runit/runsvdir/default/nftables
    ln -s /etc/sv/nftables /etc/runit/runsvdir/default/nftables
}

# sing-box 服务启用
_enable_singbox() {
    echo "[service] 启用 sing-box ..."
    mkdir -p /etc/runit/runsvdir/default
    rm -f /etc/runit/runsvdir/default/sing-box
    ln -s /etc/sv/sing-box /etc/runit/runsvdir/default/sing-box
}

# cloudflared 服务启用
_enable_cloudflared() {
    echo "[service] 启用 cloudflared ..."
    mkdir -p /etc/runit/runsvdir/default
    rm -f /etc/runit/runsvdir/default/cloudflared
    ln -s /etc/sv/cloudflared /etc/runit/runsvdir/default/cloudflared
}
