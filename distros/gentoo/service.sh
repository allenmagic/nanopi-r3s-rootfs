#
# distros/gentoo/service.sh —— Gentoo (OpenRC) 服务启用
#   被 setup.sh source 调用
#   定义 enable_router_services() 函数
#   注意：Gentoo 构建模式下，setup.sh 在 stage3 内运行，但直接操作 TARGET_ROOTFS
#

enable_router_services() {
    echo "[service] === 启用路由器服务 (INFRA=${INFRA:-base}) ==="

    # --- 系统基础服务 ---
    # sysctl 必须显式注册：base/sysctl.d/90-router.conf 的 ip_forward=1 靠它应用，
    # 不注册则 ip_forward 保持 0 → 转发/NAT 全失效（且启动日志无任何迹象）。
    # 用 base/init/openrc/sysctl（覆盖发行版自带版本，见该文件注释）。
    _enable_service sysctl boot
    _enable_service bootmisc boot
    # 服务名是 syslog 不是 syslogd：init 脚本由 ../gentoo/setup.sh 生成为
    # /etc/init.d/syslog（busybox syslogd 的包装）。写成 syslogd 时
    # _enable_service 因找不到该文件而静默跳过，check.sh 随后以
    # 「init 脚本存在但未在 default runlevel 注册」中止构建。
    _enable_service syslog
    _enable_service crond

    # --- 网络接口服务 ---
    # 从 network.env 读取接口配置
    . /network.env 2>/dev/null || true
    _enable_service net.lo boot
    _enable_service "net.${WAN_IFACE:-eth0}"
    # LAN 接口：仅在设置且不同于 WAN 时才启用独立服务
    if [ -n "${LAN_IFACE:-}" ] && [ "${LAN_IFACE}" != "${WAN_IFACE:-eth0}" ]; then
        _enable_service "net.${LAN_IFACE}"
    fi

    # --- base 应用服务（按依赖顺序）---
    # 1. 防火墙（最先加载）
    _enable_service nftables

    # 2. 核心网络服务
    _enable_service dnsmasq

    # 3. 基础应用服务
    _enable_service sshd
    _enable_service busybox-ntpd

    # 4. VPN 和隧道服务
    _enable_service tailscale
    _enable_service cloudflared

    # 5. 监控服务
    _enable_service network-watchdog
    _enable_service wan-mgmt

    # 6. 容器服务
    _enable_service yunshu

    # --- 根据 INFRA 启用组件服务 ---
    case ",${INFRA:-base}," in
        *",sing-box,"*)
            echo "[service] --- sing-box 服务 ---"
            _enable_service sing-box
            ;;
    esac

    # 移除 headless 路由器不需要的键盘服务（依赖未安装的 kbd 包）
    rm -f "${TARGET_ROOTFS}/etc/runlevels/boot/keymaps" \
          "${TARGET_ROOTFS}/etc/runlevels/boot/save-keymaps" \
          "${TARGET_ROOTFS}/etc/runlevels/default/keymaps" \
          "${TARGET_ROOTFS}/etc/runlevels/default/save-keymaps" \
          "${TARGET_ROOTFS}/etc/runlevels/boot/termencoding" \
          "${TARGET_ROOTFS}/etc/runlevels/boot/save-termencoding" 2>/dev/null || true

    echo "[service] === 服务启用完成 ==="
}

# 通用服务启用（直接操作 TARGET_ROOTFS 符号链接）
# _enable_service <name> [runlevel]
#   runlevel 可选，默认 default
_enable_service() {
    _svc_="$1"
    _rl_="${2:-default}"
    if [ -f "${TARGET_ROOTFS}/etc/init.d/${_svc_}" ]; then
        mkdir -p "${TARGET_ROOTFS}/etc/runlevels/${_rl_}"
        ln -sf "/etc/init.d/${_svc_}" "${TARGET_ROOTFS}/etc/runlevels/${_rl_}/${_svc_}" 2>/dev/null || true
        echo "[service]   启用: ${_svc_} (${_rl_})"
    else
        # 静默跳过会让「服务名写错」一路无声通过，直到 check.sh 才以
        # 「init 脚本存在但未在 runlevel 注册」中止构建，排查成本高得多
        # （syslog/syslogd 那次就是）。
        # 这里只警告不中止：有些服务在特定配置下本就可能不存在
        # （sing-box 仅在 INFRA=sing-box 等），必需集合交给 check.sh 把关。
        echo "[service]   ⚠ 跳过 ${_svc_}: ${TARGET_ROOTFS}/etc/init.d/${_svc_} 不存在（服务名写错？）" >&2
    fi
}
