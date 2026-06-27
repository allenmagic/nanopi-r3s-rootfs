#
# distros/debian/service.sh —— Debian (systemd) 服务启用
#   被 setup.sh source 调用
#   定义 enable_router_services() 函数
#

enable_router_services() {
    echo "[service] === 启用路由器服务 (INFRA=${INFRA:-sing-box}) ==="

    # --- base 服务 ---
    _enable_service ssh
    _enable_service chrony
    _enable_nftables

    # --- 根据 INFRA 启用组件服务 ---
    case ",${INFRA:-sing-box}," in
        *",sing-box,"*)
            echo "[service] --- sing-box 服务 ---"
            _enable_service dnsmasq
            _enable_service tailscaled
            _enable_singbox
            _enable_cloudflared
            ;;
        *",landscape,"*)
            echo "[service] --- landscape 服务 ---"
            # TODO: landscape services
            ;;
    esac

    echo "[service] === 服务启用完成 ==="
}

# 通用服务启用
_enable_service() {
    _svc_="$1"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable "${_svc_}" 2>/dev/null || true
        echo "[service]   启用: ${_svc_}"
    fi
}

# nftables 开机加载
_enable_nftables() {
    echo "[service] 启用 nftables 开机加载 ..."
    systemctl enable nftables 2>/dev/null || true
}

# sing-box 服务启用
_enable_singbox() {
    echo "[service] 启用 sing-box ..."
    systemctl enable sing-box 2>/dev/null || true
}

# cloudflared 服务启用
_enable_cloudflared() {
    echo "[service] 启用 cloudflared ..."
    systemctl enable cloudflared 2>/dev/null || true
}
