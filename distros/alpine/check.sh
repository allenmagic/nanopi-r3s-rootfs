#
# distros/alpine/check.sh —— Alpine (openrc) 构建完整性检查
#   被 setup.sh source 调用，在清理步骤之前执行
#

check_rootfs() {
    echo "[check] === 构建完整性检查 ==="
    _OK=0; _FAIL=0

    # ---------- 1. 关键二进制 ----------
    _check_bin() { _b_="$1"; shift
        for _p_ in "$@"; do
            [ -x "${_p_}" ] && { echo "  ✓ $_b_"; _OK=$((_OK + 1)); return 0; }
        done
        if command -v "$_b_" >/dev/null 2>&1; then
            echo "  ✓ $_b_"; _OK=$((_OK + 1))
        else
            echo "  ✗ $_b_ 缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }

    _check_ca_certs() {
        if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
            echo "  ✓ ca-certificates.crt"; _OK=$((_OK + 1))
        else
            echo "  ✗ /etc/ssl/certs/ca-certificates.crt 缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }

    echo "[check] 二进制:"
    _check_bin bash
    _check_bin sshd
    _check_bin chronyd
    # base 网络栈在 landscape 模式下整段不装（见 package.list 的 base-net 段）
    case ",${INFRA:-base}," in
        *",landscape,"*) ;;
        *)
            _check_bin dnsmasq
            _check_bin nft
            _check_bin tailscaled
            _check_bin cloudflared
            ;;
    esac
    _check_bin network-watchdog
    _check_bin agetty /sbin/agetty
    _check_ca_certs
    if grep -qE "^${SERIAL_DEV:-ttyS[0-9]}:" /etc/inittab 2>/dev/null; then
        echo "  ✓ inittab 串口 getty 激活"; _OK=$((_OK + 1))
    else
        echo "  ✗ inittab 无激活串口 getty 行!"; _FAIL=$((_FAIL + 1))
    fi

    # sing-box 仅在 INFRA=sing-box 时检查
    case ",${INFRA:-base}," in *",sing-box,"*)
        _check_bin sing-box
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
    for _f_ in /etc/dnsmasq.d/*.conf /etc/nftables.d/*.nft; do
        [ -f "$_f_" ] && _check_no_placeholder "$_f_"
    done

    # ---------- 3. openrc 服务启用 ----------
    _check_openrc() { _s_="$1" _rl_="${2:-default}"
        if [ -x "/etc/init.d/$_s_" ]; then
            if [ -L "/etc/runlevels/$_rl_/$_s_" ]; then
                echo "  ✓ $_s_ ($_rl_)"; _OK=$((_OK + 1))
            else
                echo "  ✗ $_s_ init 脚本存在但未在 $_rl_ runlevel 注册"; _FAIL=$((_FAIL + 1))
            fi
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] openrc 系统服务:"
    _check_openrc sysfs sysinit
    _check_openrc devfs sysinit
    _check_openrc dmesg sysinit
    _check_openrc sysctl boot
    _check_openrc bootmisc boot
    _check_openrc loopback boot
    _check_openrc hostname boot
    _check_openrc hwdrivers boot
    _check_openrc syslog
    _check_openrc crond
    _check_openrc local
    _check_openrc networking

    echo "[check] openrc 应用服务:"
    _check_openrc sshd
    _check_openrc chronyd
    case ",${INFRA:-base}," in
        *",landscape,"*)
            echo "[check] (landscape 模式：base 网络栈服务不启用，跳过)"
            ;;
        *)
            _check_openrc nftables
            _check_openrc dnsmasq
            _check_openrc tailscale
            _check_openrc cloudflared
            _check_openrc network-watchdog
            ;;
    esac

    # sing-box 仅在 INFRA=sing-box 时检查
    case ",${INFRA:-base}," in *",sing-box,"*)
        _check_openrc sing-box
    ;; esac

    # landscape 仅在 INFRA=landscape 时检查
    case ",${INFRA:-base}," in *",landscape,"*)
        _check_file() { _f_="$1"
            if [ -f "$_f_" ]; then
                echo "  ✓ $_f_"; _OK=$((_OK + 1))
            else
                echo "  ✗ $_f_ 缺失!"; _FAIL=$((_FAIL + 1))
            fi
        }

        echo "[check] landscape:"
        _check_bin landscape-webserver /usr/local/bin/landscape-webserver
        _check_bin lan-mac /usr/local/bin/lan-mac
        _check_file /usr/share/landscape-router/static/index.html
        _check_file /var/lib/landscape-router/landscape_init.toml
        _check_openrc landscape-router
        _check_openrc localmount boot
        # 容器运行时用 podman 顶替 docker，靠它的 rootful API socket
        _check_openrc podman

        # landscape 走 docker.sock，得指向 podman；同时确认没混进 docker
        if grep -q 'podman\.sock' /etc/init.d/landscape-router 2>/dev/null; then
            echo "  ✓ landscape-router 把 docker.sock 指向 podman.sock"; _OK=$((_OK + 1))
        else
            echo "  ✗ landscape-router 没把 docker.sock 指向 podman"; _FAIL=$((_FAIL + 1))
        fi
        if [ -x /usr/bin/docker ] || [ -x /usr/bin/dockerd ] || [ -x /usr/local/bin/docker ]; then
            echo "  ✗ 镜像里有 docker（应改用 podman）"; _FAIL=$((_FAIL + 1))
        else
            echo "  ✓ 无 docker（容器运行时为 podman）"; _OK=$((_OK + 1))
        fi

        # frontend 与二进制同版本发布，缺了页面就白屏
        if [ -d /usr/share/landscape-router/static/assets ] || \
           [ -d /usr/share/landscape-router/static/scalar ]; then
            echo "  ✓ static 资源目录"; _OK=$((_OK + 1))
        else
            echo "  ✗ static 资源目录缺失"; _FAIL=$((_FAIL + 1))
        fi

        # landscape 的 DNS 要占 :53，dnsmasq 一起跑它就直接起不来
        if [ -e /etc/runlevels/default/dnsmasq ]; then
            echo "  ✗ dnsmasq 注册进了 default（会占住 :53）"; _FAIL=$((_FAIL + 1))
        else
            echo "  ✓ dnsmasq 未启用（:53 留给 landscape）"; _OK=$((_OK + 1))
        fi

        # 凭据文件默认 0644，必须是 0600
        if [ "$(stat -c '%a' /etc/conf.d/landscape-router 2>/dev/null)" = "600" ]; then
            echo "  ✓ conf.d 凭据权限 0600"; _OK=$((_OK + 1))
        else
            echo "  ✗ /etc/conf.d/landscape-router 权限不是 0600"; _FAIL=$((_FAIL + 1))
        fi

        # OpenRC 不自动挂 bpffs，漏了这行 landscape pin eBPF map 会报 ENOENT
        if grep -qE '^[^#]*[[:space:]]/sys/fs/bpf([[:space:]]|$)' /etc/fstab 2>/dev/null; then
            echo "  ✓ fstab 有 bpffs 挂载项"; _OK=$((_OK + 1))
        else
            echo "  ✗ fstab 缺 bpffs 挂载项"; _FAIL=$((_FAIL + 1))
        fi
    ;; esac

    # ---------- 结果 ----------
    _TOTAL=$((_OK + _FAIL))
    echo "[check] === $_OK/$_TOTAL 通过 ==="
    [ "$_FAIL" -eq 0 ] || { echo "[check] 构建不完整，中止"; exit 1; }
}
