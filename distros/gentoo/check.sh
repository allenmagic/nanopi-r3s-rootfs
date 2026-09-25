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

    # ---------- 结果 ----------
    _TOTAL=$((_OK + _FAIL))
    echo "[check] === $_OK/$_TOTAL 通过 ==="
    # 必须中止构建（与 alpine 链一致）：只警告的话 check_rootfs 恒返回 0，
    # 缺失二进制/服务的镜像照样出包。
    [ "$_FAIL" -eq 0 ] || { echo "[check] 构建不完整，中止"; exit 1; }
}
