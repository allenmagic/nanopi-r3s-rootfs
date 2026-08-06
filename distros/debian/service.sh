#
# distros/debian/service.sh —— Debian (systemd) 服务启用
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
# systemctl enable 在 chroot（mmdebstrap）内常因无法连接 bus 失败，
# 失败时 fallback 手动创建 multi-user.target.wants 符号链接
_enable_service() {
    _svc_="$1"
    if command -v systemctl >/dev/null 2>&1 && systemctl enable "${_svc_}" 2>/dev/null; then
        echo "[service]   启用: ${_svc_} (systemctl)"
    else
        _sysd_link "${_svc_}" "systemctl enable 失败（chroot 无 bus），手动链接"
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

# 手动创建 systemd wants 符号链接（chroot 内 systemctl enable 不可用时的 fallback）
# 服务文件搜索顺序：/etc/systemd/system → /lib/systemd/system → /usr/lib/systemd/system
_sysd_link() {
    _svc_="$1"
    _reason_="$2"
    _wants_="/etc/systemd/system/multi-user.target.wants"
    _unit_=""
    for _d_ in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
        [ -f "${_d_}/${_svc_}.service" ] && { _unit_="${_d_}/${_svc_}.service"; break; }
    done
    if [ -n "${_unit_}" ]; then
        mkdir -p "${_wants_}"
        ln -sf "${_unit_}" "${_wants_}/${_svc_}.service"
        echo "[service]   启用: ${_svc_} (手动链接, ${_reason_})"
    else
        echo "[service]   警告: ${_svc_}.service 单元文件不存在" >&2
    fi
}
