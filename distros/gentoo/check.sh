#
# distros/gentoo/check.sh —— Gentoo (openrc) 构建完整性检查
#   被 setup.sh source 调用，运行在 stage3 环境内
#   检查目标为 TARGET_ROOTFS（/gentoo-rootfs），不是当前根文件系统
#

check_rootfs() {
    echo "[check] === 构建完整性检查 ==="
    _OK=0; _FAIL=0

    # ---------- 1. 关键二进制（在 TARGET_ROOTFS 内查找）----------
    _check_bin() { _b_="$1"; shift
        for _p_ in "$@"; do
            if [ -x "${TARGET_ROOTFS}${_p_}" ]; then
                echo "  ✓ $_b_"; _OK=$((_OK + 1)); return 0
            fi
        done
        echo "  ✗ $_b_ 缺失!"; _FAIL=$((_FAIL + 1))
    }
    _check_ca_certs() {
        if [ -f "${TARGET_ROOTFS}/etc/ssl/certs/ca-certificates.crt" ]; then
            echo "  ✓ ca-certificates.crt"; _OK=$((_OK + 1))
        else
            echo "  ✗ ${TARGET_ROOTFS}/etc/ssl/certs/ca-certificates.crt 缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }

    echo "[check] 二进制:"
    _check_bin init     /sbin/init
    _check_bin bash     /bin/bash
    _check_bin busybox  /bin/busybox
    _check_bin sshd     /usr/sbin/sshd
    _check_bin dnsmasq  /usr/sbin/dnsmasq /usr/bin/dnsmasq
    _check_bin nft      /usr/sbin/nft /sbin/nft
    _check_bin tailscaled /usr/local/bin/tailscaled
    _check_bin cloudflared /usr/local/bin/cloudflared
    _check_bin network-watchdog /usr/local/bin/network-watchdog
    # podman-compose 是指向 python-exec2 的软链，-x 会跟着查目标；解释器被删时这里报错
    _check_bin podman-compose /usr/bin/podman-compose /usr/local/bin/podman-compose
    _check_bin lan-mac  /usr/local/bin/lan-mac
    _check_bin rootfs-resize /usr/local/bin/rootfs-resize
    _check_bin resize2fs /sbin/resize2fs /usr/sbin/resize2fs
    _check_bin growpart /usr/sbin/growpart /usr/bin/growpart
    _check_bin agetty   /sbin/agetty /usr/sbin/agetty
    _check_ca_certs
    if grep -qE ":respawn:/sbin/agetty.*[[:space:]]${SERIAL_DEV:-ttyS[0-9]}([[:space:]]|$)" "${TARGET_ROOTFS}/etc/inittab" 2>/dev/null; then
        echo "  ✓ inittab 串口 getty 激活"; _OK=$((_OK + 1))
    else
        echo "  ✗ inittab 无激活串口 getty 行!"; _FAIL=$((_FAIL + 1))
    fi
    if grep -qE ":respawn:/sbin/agetty .*-L([[:space:]]|$)" "${TARGET_ROOTFS}/etc/inittab" 2>/dev/null; then
        echo "  ✓ 串口 getty 忽略 DCD (-L)"; _OK=$((_OK + 1))
    else
        echo "  ✗ 串口 getty 缺 -L，载波抖动会导致登录 respawn 循环"; _FAIL=$((_FAIL + 1))
    fi
    # l6 只负责停服务，真正发起重启的是 l6r；漏了它会卡在「根只读、内核不重启」
    if grep -qE "^l6r:6:.*reboot" "${TARGET_ROOTFS}/etc/inittab" 2>/dev/null; then
        echo "  ✓ inittab 有 l6r 重启行"; _OK=$((_OK + 1))
    else
        echo "  ✗ inittab 缺 l6r 行 —— reboot 会变成 halt"; _FAIL=$((_FAIL + 1))
    fi

    # sing-box 仅在 INFRA=sing-box 时检查
    case ",${INFRA:-base}," in *",sing-box,"*)
        _check_bin sing-box /usr/local/bin/sing-box
    ;; esac

    # ---------- 2. 配置文件占位符残留 ----------
    _check_no_placeholder() { _f_="$1"
        [ -f "$_f_" ] || { echo "  ✗ $_f_ 不存在!"; _FAIL=$((_FAIL + 1)); return; }
        if grep -q '__[A-Z_]\+__' "$_f_" 2>/dev/null; then
            echo "  ✗ $_f_ 有未替换占位符!"; _FAIL=$((_FAIL + 1))
            grep -n '__[A-Z_]\+__' "$_f_"
        else
            echo "  ✓ $_f_"; _OK=$((_OK + 1))
        fi
    }
    echo "[check] 配置占位符:"
    for _f_ in "${TARGET_ROOTFS}"/etc/dnsmasq.d/*.conf "${TARGET_ROOTFS}"/etc/nftables.d/*.nft; do
        [ -f "$_f_" ] && _check_no_placeholder "$_f_"
    done

    # ---------- 3. openrc 服务启用 ----------
    _check_openrc() { _s_="$1" _rl_="${2:-default}"
        if [ -x "${TARGET_ROOTFS}/etc/init.d/$_s_" ]; then
            if [ -L "${TARGET_ROOTFS}/etc/runlevels/$_rl_/$_s_" ]; then
                echo "  ✓ $_s_ ($_rl_)"; _OK=$((_OK + 1))
            else
                echo "  ✗ $_s_ init 脚本存在但未在 $_rl_ runlevel 注册"; _FAIL=$((_FAIL + 1))
            fi
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] openrc 系统服务:"
    _check_openrc bootmisc boot
    _check_openrc syslog default
    _check_openrc crond default

    echo "[check] openrc 网络服务:"
    # 漏注册则开机无网，构建却全绿
    . /network.env 2>/dev/null || true
    _check_openrc net.lo boot
    _check_openrc "net.${WAN_IFACE:-eth0}" default
    _check_openrc "net.${LAN_IFACE:-eth1}" default
    # 未排除 plug 时 netifrc 用 ifplugd 把接口 background 掉
    if grep -q '^modules="!plug"' "${TARGET_ROOTFS}/etc/conf.d/net" 2>/dev/null; then
        echo "  ✓ conf.d/net 排除 ifplugd"; _OK=$((_OK + 1))
    else
        echo "  ✗ conf.d/net 未排除 ifplugd（接口会 background 后停摆）"; _FAIL=$((_FAIL + 1))
    fi
    _check_openrc cgroups sysinit

    echo "[check] openrc 应用服务:"
    _check_openrc sshd default
    _check_openrc busybox-ntpd default
    _check_openrc nftables default
    _check_openrc dnsmasq default
    _check_openrc tailscale default
    _check_openrc cloudflared default
    _check_openrc network-watchdog
    _check_openrc yunshu default

    # sing-box 仅在 INFRA=sing-box 时检查
    case ",${INFRA:-base}," in *",sing-box,"*)
        _check_openrc sing-box default
    ;; esac

    # ---------- 4. 额外检查：自定义 init 脚本完整性 ----------
    echo "[check] Gentoo 自定义 init 脚本:"
    for _s_ in busybox-ntpd syslog crond; do
        if [ -x "${TARGET_ROOTFS}/etc/init.d/$_s_" ]; then
            echo "  ✓ $_s_"; _OK=$((_OK + 1))
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    done

    # ---------- 5. busybox 软链没遮住真身 ----------
    case "$(readlink "${TARGET_ROOTFS}/sbin/ip" 2>/dev/null)" in
        *busybox)
            echo "  ✗ /sbin/ip 仍是 busybox 软链（遮蔽 iproute2 的 /bin/ip）"; _FAIL=$((_FAIL + 1)) ;;
        *)
            echo "  ✓ /sbin/ip 未被 busybox 遮蔽"; _OK=$((_OK + 1)) ;;
    esac

    # ---------- 6. cgroup v2 ----------
    if grep -q '^rc_cgroup_mode="unified"' "${TARGET_ROOTFS}/etc/rc.conf" 2>/dev/null; then
        echo "  ✓ rc_cgroup_mode=unified"; _OK=$((_OK + 1))
    else
        echo "  ✗ rc_cgroup_mode 未设 unified（podman 看不到控制器）"; _FAIL=$((_FAIL + 1))
    fi

    # ---------- 7. Alpine 对齐检查 ----------
    echo "[check] Alpine 对齐检查:"

    # 7.1 运行时二进制
    _check_bin podman /usr/bin/podman
    _check_bin wan-mgmt /usr/local/bin/wan-mgmt
    _check_bin vpn-routes /usr/local/bin/vpn-routes

    # 7.2 RTL8169 固件
    if [ -f "${TARGET_ROOTFS}/lib/firmware/rtl_nic/rtl8168h-2.fw" ]; then
        echo "  ✓ rtl_nic/rtl8168h-2.fw"; _OK=$((_OK + 1))
    else
        echo "  ✗ rtl_nic/rtl8168h-2.fw 缺失"; _FAIL=$((_FAIL + 1))
    fi

    # 7.3 SSH / root / secret
    if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "${TARGET_ROOTFS}/etc/ssh/sshd_config" 2>/dev/null && \
       grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+yes' "${TARGET_ROOTFS}/etc/ssh/sshd_config" 2>/dev/null; then
        echo "  ✓ sshd 允许密码登录"; _OK=$((_OK + 1))
    else
        echo "  ✗ sshd 未允许密码登录"; _FAIL=$((_FAIL + 1))
    fi
    if [ -z "${ROOT_PASSWORD:-}" ]; then
        if grep -q '^root:!:' "${TARGET_ROOTFS}/etc/shadow" 2>/dev/null; then
            echo "  ✓ root 已锁定（rootfs 不写密码）"; _OK=$((_OK + 1))
        else
            echo "  ✗ root 密码未锁定!"; _FAIL=$((_FAIL + 1))
        fi
    else
        echo "  (ROOT_PASSWORD 已提供，跳过 root 锁定检查)"; _OK=$((_OK + 1))
    fi
    _has_secret=0
    [ -n "${SSH_PRIVATE_KEY:-}" ] && _has_secret=1
    [ -n "${SSH_PUBLIC_KEY:-}" ] && _has_secret=1
    [ -n "${TAILSCALE_AUTH_KEY:-}" ] && _has_secret=1
    [ -n "${HEADSCALE_AUTH_KEY:-}" ] && _has_secret=1
    [ -n "${CLOUDFLARED_TOKEN:-}" ] && _has_secret=1
    if [ "${_has_secret}" -eq 0 ]; then
        _leak_=0
        for _f_ in "${TARGET_ROOTFS}/root/.ssh/id_ed25519" \
                    "${TARGET_ROOTFS}/etc/tailscale/authkey" \
                    "${TARGET_ROOTFS}/etc/cloudflared/config.yml"; do
            if [ -e "${_f_}" ]; then
                echo "  ✗ 无 secret 构建却存在 ${_f_}"
                _FAIL=$((_FAIL + 1)); _leak_=1
            fi
        done
        [ "${_leak_}" -eq 0 ] && { echo "  ✓ 无个人密钥残留"; _OK=$((_OK + 1)); }
    else
        echo "  (提供了个人 key/token，跳过清洁检查)"; _OK=$((_OK + 1))
    fi

    # 7.4 日志与关键配置
    # busybox syslogd 的 -s 只接受纯数字（单位 KB），"-s 1M" 会让它启动失败
    if grep -q 'SYSLOGD_OPTS=.*-O /var/log/messages' "${TARGET_ROOTFS}/etc/conf.d/syslog" 2>/dev/null && \
       grep -qE 'SYSLOGD_OPTS=.*-s [0-9]+([[:space:]]|")' "${TARGET_ROOTFS}/etc/conf.d/syslog" 2>/dev/null && \
       grep -q '/etc/conf.d/syslog' "${TARGET_ROOTFS}/etc/init.d/syslog" 2>/dev/null; then
        echo "  ✓ syslogd 输出到 /var/log/messages（持久化，-s 为 KB 数字）"; _OK=$((_OK + 1))
    else
        echo "  ✗ syslogd 未正确输出到 /var/log/messages（-s 必须是 KB 数字）"; _FAIL=$((_FAIL + 1))
    fi
    # WAN 拿不到 DHCP 时不能把 LAN 一起拖死
    if grep -q 'udhcpc_.*="-b' "${TARGET_ROOTFS}/etc/conf.d/net" 2>/dev/null; then
        echo "  ✓ udhcpc -b（无 lease 后台重试，net.eth0 不失败）"; _OK=$((_OK + 1))
    else
        echo "  ✗ udhcpc 未启用 -b，WAN 无 DHCP 时 net.eth0 会失败"; _FAIL=$((_FAIL + 1))
    fi
    if grep -q 'need localmount net\.' "${TARGET_ROOTFS}/etc/init.d/dnsmasq" 2>/dev/null; then
        echo "  ✓ dnsmasq 只依赖 LAN 接口（不再 need net）"; _OK=$((_OK + 1))
    else
        echo "  ✗ dnsmasq 仍 need net（WAN 故障会拖死 LAN DHCP/DNS）"; _FAIL=$((_FAIL + 1))
    fi
    if grep -q '^previous_dmesg=yes' "${TARGET_ROOTFS}/etc/conf.d/bootmisc" 2>/dev/null; then
        echo "  ✓ bootmisc 保留上次启动 dmesg"; _OK=$((_OK + 1))
    else
        echo "  ✗ bootmisc 未保留上次启动 dmesg"; _FAIL=$((_FAIL + 1))
    fi
    if [ -f "${TARGET_ROOTFS}/var/log/btmp" ]; then
        echo "  ✓ /var/log/btmp 存在（pam_lastlog）"; _OK=$((_OK + 1))
    else
        echo "  ✗ /var/log/btmp 缺失（SSH 登录会报 pam_lastlog 错误）"; _FAIL=$((_FAIL + 1))
    fi
    if grep -vE '^[[:space:]]*#' "${TARGET_ROOTFS}/etc/init.d/crond" 2>/dev/null | grep -q '/var/log/crond.log'; then
        echo "  ✗ crond 仍写 /var/log/crond.log"; _FAIL=$((_FAIL + 1))
    else
        echo "  ✓ crond 日志走 syslog"; _OK=$((_OK + 1))
    fi
    if [ -d "${TARGET_ROOTFS}/var/spool/cron/crontabs" ]; then
        echo "  ✓ crond spool 目录存在"; _OK=$((_OK + 1))
    else
        echo "  ✗ crond spool 目录缺失（crond 会启动失败）"; _FAIL=$((_FAIL + 1))
    fi
    if grep -q '^port=0' "${TARGET_ROOTFS}/etc/dnsmasq.d/99-disable-dns-server.conf" 2>/dev/null; then
        echo "  ✓ dnsmasq port=0（仅 DHCP）"; _OK=$((_OK + 1))
    else
        echo "  ✗ dnsmasq 未关闭 DNS（port=0）"; _FAIL=$((_FAIL + 1))
    fi
    if grep -q 'firewall_driver = "nftables"' "${TARGET_ROOTFS}/etc/containers/containers.conf.d/50-netavark-nftables.conf" 2>/dev/null; then
        echo "  ✓ netavark 使用 nftables"; _OK=$((_OK + 1))
    else
        echo "  ✗ netavark 未固定 nftables"; _FAIL=$((_FAIL + 1))
    fi
    if grep -q 'NFTABLES_SAVE="/etc/nftables.nft"' "${TARGET_ROOTFS}/etc/conf.d/nftables" 2>/dev/null && \
       grep -q 'SAVE_ON_STOP="no"' "${TARGET_ROOTFS}/etc/conf.d/nftables" 2>/dev/null; then
        echo "  ✓ nftables 加载 /etc/nftables.nft"; _OK=$((_OK + 1))
    else
        echo "  ✗ nftables 未指向 /etc/nftables.nft"; _FAIL=$((_FAIL + 1))
    fi
    if [ -x "${TARGET_ROOTFS}/etc/local.d/10-rootfs-resize.start" ]; then
        echo "  ✓ local.d rootfs-resize"; _OK=$((_OK + 1))
    else
        echo "  ✗ local.d rootfs-resize 缺失"; _FAIL=$((_FAIL + 1))
    fi

    # 7.5 OpenRC 对齐服务
    _check_openrc hostname boot
    _check_openrc local default
    _check_openrc wan-mgmt

    # 7.6 sing-box 细节
    case ",${INFRA:-base}," in *",sing-box,"*)
        echo "[check] sing-box:"
        _check_bin yunshu-domain /usr/local/bin/yunshu-domain

        _v_="$("${TARGET_ROOTFS}/usr/local/bin/sing-box" version 2>/dev/null | head -n1 | \
               sed -n 's/.* \([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p')"
        if [ -n "${_v_}" ] && \
           printf '%s\n' "${_v_}" | awk -F. '{exit !($1>1 || ($1==1 && $2>=14))}'; then
            echo "  ✓ sing-box ${_v_} (>=1.14)"; _OK=$((_OK + 1))
        else
            echo "  ✗ sing-box 版本 ${_v_:-未知} < 1.14"; _FAIL=$((_FAIL + 1))
        fi

        for _f_ in /etc/sing-box/rules/yunshu-domains.json \
                    /etc/sing-box/rules/yunshu-domains.txt \
                    /etc/sing-box/rules/bypass-cidrs.json; do
            if [ -f "${TARGET_ROOTFS}${_f_}" ]; then
                echo "  ✓ ${_f_}"; _OK=$((_OK + 1))
            else
                echo "  ✗ ${_f_} 缺失!"; _FAIL=$((_FAIL + 1))
            fi
        done

        if grep -q '"interface_name": "singtun0"' "${TARGET_ROOTFS}/etc/sing-box/config.json" 2>/dev/null; then
            echo "  ✓ sing-box TUN = singtun0"; _OK=$((_OK + 1))
        else
            echo "  ✗ sing-box TUN 未使用 singtun0"; _FAIL=$((_FAIL + 1))
        fi

        if grep -q '__ROUTER_HOSTNAME__' "${TARGET_ROOTFS}/etc/sing-box/config.json" 2>/dev/null; then
            echo "  ✗ sing-box hostname 占位符未替换"; _FAIL=$((_FAIL + 1))
        elif [ -n "${HOSTNAME_VAL:-}" ] && \
             grep -q "\"hostname\": \"${HOSTNAME_VAL}\"" "${TARGET_ROOTFS}/etc/sing-box/config.json" 2>/dev/null; then
            echo "  ✓ sing-box Tailscale hostname = ${HOSTNAME_VAL}"; _OK=$((_OK + 1))
        else
            echo "  ✗ sing-box Tailscale hostname 与 HOSTNAME_VAL 不一致"; _FAIL=$((_FAIL + 1))
        fi

        if grep -q '"type": "bridge"' "${TARGET_ROOTFS}/etc/sing-box/config.json" 2>/dev/null; then
            echo "  ✓ yunshu bridge outbound"; _OK=$((_OK + 1))
        else
            echo "  ✗ 缺少 yunshu bridge outbound"; _FAIL=$((_FAIL + 1))
        fi

        if grep -q '"level": "error"' "${TARGET_ROOTFS}/etc/sing-box/config.json" 2>/dev/null && \
           grep -q '"output": "/dev/null"' "${TARGET_ROOTFS}/etc/sing-box/config.json" 2>/dev/null && \
           ! grep -q '"experimental"' "${TARGET_ROOTFS}/etc/sing-box/config.json" 2>/dev/null; then
            echo "  ✓ sing-box 日志 error + /dev/null，无 cache_file"; _OK=$((_OK + 1))
        else
            echo "  ✗ sing-box 日志/缓存配置不符合预期"; _FAIL=$((_FAIL + 1))
        fi

        if [ -x "${TARGET_ROOTFS}/usr/local/bin/sing-box" ]; then
            [ -e "${TARGET_ROOTFS}/dev/null" ] || mknod "${TARGET_ROOTFS}/dev/null" c 1 3 2>/dev/null || true
            [ -e "${TARGET_ROOTFS}/dev/urandom" ] || mknod "${TARGET_ROOTFS}/dev/urandom" c 1 9 2>/dev/null || true
            [ -e "${TARGET_ROOTFS}/dev/random" ] || mknod "${TARGET_ROOTFS}/dev/random" c 1 8 2>/dev/null || true
            if chroot "${TARGET_ROOTFS}" /usr/local/bin/sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
                echo "  ✓ sing-box check"; _OK=$((_OK + 1))
            else
                echo "  ✗ sing-box check 失败"; _FAIL=$((_FAIL + 1))
            fi
        fi
        if grep -q '"type": "api"' "${TARGET_ROOTFS}/etc/sing-box/config.json" 2>/dev/null && \
           ! grep -q '__SINGBOX_API_SECRET__' "${TARGET_ROOTFS}/etc/sing-box/config.json" 2>/dev/null && \
           [ -f "${TARGET_ROOTFS}/etc/sing-box/api.secret" ] && \
           [ "$(stat -c '%a' "${TARGET_ROOTFS}/etc/sing-box/api.secret" 2>/dev/null)" = "600" ]; then
            echo "  ✓ Dashboard API 已启用（Secret 0600）"; _OK=$((_OK + 1))
        else
            echo "  ✗ Dashboard API/Secret 配置不完整"; _FAIL=$((_FAIL + 1))
        fi
    ;; esac

    # ---------- 结果 ----------
    _TOTAL=$((_OK + _FAIL))
    echo "[check] === $_OK/$_TOTAL 通过 ==="
    # 必须中止构建（与 alpine 链一致）：只警告的话 check_rootfs 恒返回 0，
    # 缺失二进制/服务的镜像照样出包。
    [ "$_FAIL" -eq 0 ] || { echo "[check] 构建不完整，中止"; exit 1; }
}
