#
# distros/devuan/service.sh —— Devuan (sysvinit) 服务启用
#   被 setup.sh source 调用
#   定义 enable_router_services() 函数
#

enable_router_services() {
    echo "[service] === 启用路由器服务 ==="

    # --- 包管理器安装的服务 ---
    _enable_service dnsmasq
    _enable_service ssh
    _enable_service chrony
    _enable_service tailscaled
    _enable_nftables

    # --- 自定义服务（下载安装） ---
    _enable_singbox
    _enable_cloudflared

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
