#
# distros/devuan/service.sh —— Devuan (sysvinit) 服务启用
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
    _enable_service ssh
    _enable_service chrony

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
    if command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d "${_svc_}" defaults >/dev/null 2>&1 || true
        echo "[service]   启用: ${_svc_}"
    fi
}

# nftables 开机加载
_enable_nftables() {
    echo "[service] 启用 nftables 开机加载 ..."
    update-rc.d nftables defaults >/dev/null 2>&1 || true
}

# sing-box 服务启用
_enable_singbox() {
    echo "[service] 启用 sing-box ..."
    update-rc.d sing-box defaults >/dev/null 2>&1 || true
}

# cloudflared 服务启用
_enable_cloudflared() {
    echo "[service] 启用 cloudflared ..."
    update-rc.d cloudflared defaults >/dev/null 2>&1 || true
}
