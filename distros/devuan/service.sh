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

    # 5. 监控服务
    _enable_service network-watchdog

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
# update-rc.d 在 chroot 内可能失败（缺 LSB header / 依赖解析），
# 失败时 fallback 手动创建 rc2.d 符号链接
_enable_service() {
    _svc_="$1"
    if command -v update-rc.d >/dev/null 2>&1 && update-rc.d "${_svc_}" defaults >/dev/null 2>&1; then
        echo "[service]   启用: ${_svc_} (update-rc.d)"
    else
        _sysv_link "${_svc_}" "update-rc.d 失败，手动链接"
    fi
}

# nftables 开机加载
_enable_nftables() {
    echo "[service] 启用 nftables 开机加载 ..."
    _enable_service nftables
}

# sing-box 服务启用
_enable_singbox() {
    echo "[service] 启用 sing-box ..."
    _enable_service sing-box
}

# cloudflared 服务启用
_enable_cloudflared() {
    echo "[service] 启用 cloudflared ..."
    _enable_service cloudflared
}

# 手动创建 sysvinit rc2.d 符号链接（update-rc.d 不可用/失败时的 fallback）
_sysv_link() {
    _svc_="$1"
    _reason_="$2"
    if [ -f "/etc/init.d/${_svc_}" ]; then
        mkdir -p /etc/rc2.d
        ln -sf "../init.d/${_svc_}" "/etc/rc2.d/S99${_svc_}"
        echo "[service]   启用: ${_svc_} (手动链接, ${_reason_})"
    else
        echo "[service]   警告: /etc/init.d/${_svc_} 不存在" >&2
    fi
}
