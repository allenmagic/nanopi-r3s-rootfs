#
# infra/sing-box/service.sh —— sing-box 栈服务启用
#   被 lib/install-router-software.sh source 调用
#   定义 enable_sing_box() 函数
#
# 根据 $DISTRO 选择对应 init 系统：
#   void   → runit          (ln -s /etc/sv/ → /etc/runit/runsvdir/default/)
#   devuan → sysvinit       (update-rc.d)
#   debian → systemd        (systemctl enable)
#   alpine → OpenRC         (rc-update add)
#
# 注意：本文件只做服务启用，不做任何文件生成。
# 服务单元文件（runit run 脚本 / sysvinit 脚本 / systemd unit / OpenRC 脚本）
# 由 install.sh 的配置部署阶段负责复制。
#
# 可用变量：$DISTRO
#

enable_sing_box() {
    echo "[sing-box] === 启用 sing-box 体系服务 ==="

    # 既有的包服务
    _enable_service dnsmasq
    _enable_service tailscaled
    _enable_nftables

    # 自定义服务
    _enable_singbox_service
    _enable_cloudflared_service

    echo "[sing-box] === 服务启用完成 ==="
}

# ============================================================
#  启用已有包服务
# ============================================================
_enable_service() {
    _svc_="$1"
    echo "[sing-box] 启用服务: ${_svc_}"

    case "${DISTRO:-void}" in
        void)
            if [ -d "/etc/sv/${_svc_}" ]; then
                mkdir -p /etc/runit/runsvdir/default
                rm -f "/etc/runit/runsvdir/default/${_svc_}"
                ln -s "/etc/sv/${_svc_}" "/etc/runit/runsvdir/default/${_svc_}"
            else
                echo "[sing-box]   警告: /etc/sv/${_svc_} 不存在" >&2
            fi
            ;;
        devuan)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "${_svc_}" defaults >/dev/null 2>&1 || true
            else
                echo "[sing-box]   警告: update-rc.d 不存在" >&2
            fi
            ;;
        debian)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable "${_svc_}" 2>/dev/null || true
            fi
            ;;
        alpine)
            if command -v rc-update >/dev/null 2>&1; then
                rc-update add "${_svc_}" default 2>/dev/null || true
            else
                echo "[sing-box]   警告: rc-update 不存在" >&2
            fi
            ;;
    esac
}

# ============================================================
#  nftables —— 确保规则集在启动时加载
# ============================================================
_enable_nftables() {
    echo "[sing-box] 启用 nftables 开机加载 ..."

    case "${DISTRO:-void}" in
        void)
            # runit-nftables 包已提供 /etc/sv/nftables/
            mkdir -p /etc/runit/runsvdir/default
            rm -f /etc/runit/runsvdir/default/nftables
            ln -s /etc/sv/nftables /etc/runit/runsvdir/default/nftables
            ;;
        devuan)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d nftables defaults >/dev/null 2>&1 || true
            fi
            ;;
        debian)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable nftables 2>/dev/null || true
            fi
            ;;
        alpine)
            if command -v rc-update >/dev/null 2>&1; then
                rc-update add nftables default 2>/dev/null || true
            fi
            ;;
    esac
}

# ============================================================
#  sing-box 自定义服务启用
# ============================================================
_enable_singbox_service() {
    echo "[sing-box] 启用 sing-box 服务 ..."

    case "${DISTRO:-void}" in
        void)
            mkdir -p /etc/runit/runsvdir/default
            rm -f /etc/runit/runsvdir/default/sing-box
            ln -s /etc/sv/sing-box /etc/runit/runsvdir/default/sing-box
            ;;
        devuan)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d sing-box defaults >/dev/null 2>&1 || true
            fi
            ;;
        debian)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable sing-box 2>/dev/null || true
            fi
            ;;
        alpine)
            if command -v rc-update >/dev/null 2>&1; then
                rc-update add sing-box default 2>/dev/null || true
            fi
            ;;
    esac
}

# ============================================================
#  cloudflared 自定义服务启用
# ============================================================
_enable_cloudflared_service() {
    echo "[sing-box] 启用 cloudflared 服务 ..."

    case "${DISTRO:-void}" in
        void)
            mkdir -p /etc/runit/runsvdir/default
            rm -f /etc/runit/runsvdir/default/cloudflared
            ln -s /etc/sv/cloudflared /etc/runit/runsvdir/default/cloudflared
            ;;
        devuan)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d cloudflared defaults >/dev/null 2>&1 || true
            fi
            ;;
        debian)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable cloudflared 2>/dev/null || true
            fi
            ;;
        alpine)
            if command -v rc-update >/dev/null 2>&1; then
                rc-update add cloudflared default 2>/dev/null || true
            fi
            ;;
    esac
}
