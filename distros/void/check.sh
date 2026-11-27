#
# distros/void/check.sh —— Void (runit) 构建完整性检查
#   被 setup.sh source 调用，在清理步骤之前执行
#

check_rootfs() {
    echo "[check] === 构建完整性检查 ==="
    _OK=0; _FAIL=0

    # ---------- 1. 关键二进制 ----------
    _check_bin() { _b_="$1"
        if command -v "$_b_" >/dev/null 2>&1; then
            echo "  ✓ $_b_"; _OK=$((_OK + 1))
        else
            echo "  ✗ $_b_ 缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] 二进制:"
    _check_bin bash
    _check_bin sshd
    _check_bin chronyd
    _check_bin dnsmasq
    _check_bin nft
    _check_bin tailscaled
    _check_bin cloudflared
    _check_bin network-watchdog
    _check_bin ip
    _check_bin dhcpcd
    _check_bin rsyslogd
    _check_bin podman
    _check_bin modules-load
    _check_bin lan-mac
    _check_bin rootfs-resize
    _check_bin vpn-routes
    _check_bin wan-mgmt
    _check_bin growpart
    _check_bin resize2fs

    # sing-box 仅在 INFRA=sing-box 时检查
    case ",${INFRA:-base}," in *",sing-box,"*)
        _check_bin sing-box
        _check_bin yunshu-domain
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

    # ---------- 3. runit 服务启用 ----------
    _check_sv() { _s_="$1"
        if [ -d "/etc/sv/$_s_" ] && [ -L "/etc/runit/runsvdir/default/$_s_" ]; then
            echo "  ✓ $_s_"; _OK=$((_OK + 1))
        else
            echo "  ✗ $_s_ 未启用!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] runit 服务:"
    _check_sv rsyslogd
    _check_sv dhcpcd
    _check_sv sshd
    _check_sv chronyd
    _check_sv nftables
    _check_sv dnsmasq
    _check_sv tailscaled
    _check_sv cloudflared
    _check_sv network-watchdog
    _check_sv wan-mgmt
    _check_sv yunshu
    _check_sv local-router

    # sing-box 仅在 INFRA=sing-box 时检查
    case ",${INFRA:-base}," in *",sing-box,"*)
        _check_sv sing-box
    ;; esac

    # ---------- 4. Alpine 对齐检查 ----------
    echo "[check] Alpine 对齐检查:"

    if [ -f /lib/firmware/rtl_nic/rtl8168h-2.fw ]; then
        echo "  ✓ rtl_nic/rtl8168h-2.fw"; _OK=$((_OK + 1))
    else
        echo "  ✗ rtl_nic/rtl8168h-2.fw 缺失"; _FAIL=$((_FAIL + 1))
    fi

    if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' /etc/ssh/sshd_config 2>/dev/null && \
       grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+yes' /etc/ssh/sshd_config 2>/dev/null; then
        echo "  ✓ sshd 允许密码登录"; _OK=$((_OK + 1))
    else
        echo "  ✗ sshd 未允许密码登录"; _FAIL=$((_FAIL + 1))
    fi

    if [ -z "${ROOT_PASSWORD:-}" ]; then
        if grep -q '^root:!:' /etc/shadow 2>/dev/null; then
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
        for _f_ in /root/.ssh/id_ed25519 /etc/tailscale/authkey /etc/cloudflared/config.yml; do
            if [ -e "${_f_}" ]; then
                echo "  ✗ 无 secret 构建却存在 ${_f_}"
                _FAIL=$((_FAIL + 1)); _leak_=1
            fi
        done
        [ "${_leak_}" -eq 0 ] && { echo "  ✓ 无个人密钥残留"; _OK=$((_OK + 1)); }
    else
        echo "  (提供了个人 key/token，跳过清洁检查)"; _OK=$((_OK + 1))
    fi

    if grep -q 'include "/etc/nftables.nft"' /etc/nftables.conf 2>/dev/null; then
        echo "  ✓ nftables 加载 /etc/nftables.nft"; _OK=$((_OK + 1))
    else
        echo "  ✗ nftables 未指向 /etc/nftables.nft"; _FAIL=$((_FAIL + 1))
    fi

    if grep -q 'firewall_driver = "nftables"' /etc/containers/containers.conf.d/50-netavark-nftables.conf 2>/dev/null; then
        echo "  ✓ netavark 使用 nftables"; _OK=$((_OK + 1))
    else
        echo "  ✗ netavark 未固定 nftables"; _FAIL=$((_FAIL + 1))
    fi

    if [ -x /etc/local.d/10-rootfs-resize.start ]; then
        echo "  ✓ local.d rootfs-resize"; _OK=$((_OK + 1))
    else
        echo "  ✗ local.d rootfs-resize 缺失"; _FAIL=$((_FAIL + 1))
    fi

    if grep -q '/run/messages' /etc/rsyslog.d/99-router.conf 2>/dev/null; then
        echo "  ✓ rsyslog 写 tmpfs /run/messages"; _OK=$((_OK + 1))
    else
        echo "  ✗ rsyslog 未指向 /run/messages"; _FAIL=$((_FAIL + 1))
    fi

    if grep -q 'lan-mac' /etc/sv/dhcpcd/run 2>/dev/null; then
        echo "  ✓ dhcpcd 启动前固定 LAN MAC"; _OK=$((_OK + 1))
    else
        echo "  ✗ dhcpcd 未调用 lan-mac"; _FAIL=$((_FAIL + 1))
    fi

    if grep -q "static ip_address=${LAN_IP:-192.168.8.1}/${LAN_CIDR:-24}" /etc/dhcpcd.conf 2>/dev/null; then
        echo "  ✓ dhcpcd.conf 配置 LAN 静态地址"; _OK=$((_OK + 1))
    else
        echo "  ✗ dhcpcd.conf 缺 LAN 静态地址"; _FAIL=$((_FAIL + 1))
    fi

    case ",${INFRA:-base}," in *",sing-box,"*)
        echo "[check] sing-box:"

        # 1.14+ 才支持 bridge outbound
        _v_="$(/usr/local/bin/sing-box version 2>/dev/null | head -n1 | \
               sed -n 's/.* \([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p')"
        if [ -n "${_v_}" ] && \
           printf '%s\n' "${_v_}" | awk -F. '{exit !($1>1 || ($1==1 && $2>=14))}'; then
            echo "  ✓ sing-box ${_v_} (>=1.14)"; _OK=$((_OK + 1))
        else
            echo "  ✗ sing-box 版本 ${_v_:-未知} < 1.14，bridge outbound 不可用"
            _FAIL=$((_FAIL + 1))
        fi

        for _f_ in /etc/sing-box/rules/yunshu-domains.json \
                    /etc/sing-box/rules/yunshu-domains.txt \
                    /etc/sing-box/rules/bypass-cidrs.json; do
            if [ -f "${_f_}" ]; then
                echo "  ✓ ${_f_}"; _OK=$((_OK + 1))
            else
                echo "  ✗ ${_f_} 缺失!"; _FAIL=$((_FAIL + 1))
            fi
        done

        if grep -q '"interface_name": "singtun0"' /etc/sing-box/config.json 2>/dev/null; then
            echo "  ✓ sing-box TUN = singtun0"; _OK=$((_OK + 1))
        else
            echo "  ✗ sing-box TUN 未使用 singtun0（会与 yunshu tun0 冲突）"
            _FAIL=$((_FAIL + 1))
        fi

        if grep -q '__ROUTER_HOSTNAME__' /etc/sing-box/config.json 2>/dev/null; then
            echo "  ✗ sing-box hostname 占位符未替换"; _FAIL=$((_FAIL + 1))
        elif [ -n "${HOSTNAME_VAL:-}" ] && \
             grep -q "\"hostname\": \"${HOSTNAME_VAL}\"" /etc/sing-box/config.json 2>/dev/null; then
            echo "  ✓ sing-box Tailscale hostname = ${HOSTNAME_VAL}"; _OK=$((_OK + 1))
        else
            echo "  ✗ sing-box Tailscale hostname 与 HOSTNAME_VAL 不一致"
            _FAIL=$((_FAIL + 1))
        fi

        if grep -q '"type": "bridge"' /etc/sing-box/config.json 2>/dev/null; then
            echo "  ✓ yunshu bridge outbound"; _OK=$((_OK + 1))
        else
            echo "  ✗ 缺少 yunshu bridge outbound"; _FAIL=$((_FAIL + 1))
        fi

        if grep -q '^port=0' /etc/dnsmasq.d/99-disable-dns-server.conf 2>/dev/null; then
            echo "  ✓ dnsmasq port=0（仅 DHCP）"; _OK=$((_OK + 1))
        else
            echo "  ✗ dnsmasq 未关闭 DNS（port=0）"; _FAIL=$((_FAIL + 1))
        fi

        if grep -qE '__LAN_(IP|NET|IFACE)__' \
                /etc/sing-box/config.json /etc/sing-box/rules/*.json 2>/dev/null; then
            echo "  ✗ sing-box 配置仍有 LAN 占位符残留"
            grep -nE '__LAN_(IP|NET|IFACE)__' \
                /etc/sing-box/config.json /etc/sing-box/rules/*.json 2>/dev/null
            _FAIL=$((_FAIL + 1))
        else
            echo "  ✓ sing-box 配置无 LAN 占位符残留"; _OK=$((_OK + 1))
        fi

        if grep -q '"level": "error"' /etc/sing-box/config.json 2>/dev/null && \
           grep -q '"output": "/dev/null"' /etc/sing-box/config.json 2>/dev/null && \
           ! grep -q '"experimental"' /etc/sing-box/config.json 2>/dev/null; then
            echo "  ✓ sing-box 日志 error + /dev/null，无 cache_file"; _OK=$((_OK + 1))
        else
            echo "  ✗ sing-box 日志/缓存配置不符合预期"; _FAIL=$((_FAIL + 1))
        fi

        if /usr/local/bin/sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
            echo "  ✓ sing-box check"; _OK=$((_OK + 1))
        else
            echo "  ✗ sing-box check 失败"
            /usr/local/bin/sing-box check -c /etc/sing-box/config.json 2>&1 | tail -20
            _FAIL=$((_FAIL + 1))
        fi
        if grep -q '"type": "api"' /etc/sing-box/config.json 2>/dev/null && \
           ! grep -q '__SINGBOX_API_SECRET__' /etc/sing-box/config.json 2>/dev/null && \
           [ -f /etc/sing-box/api.secret ] && \
           [ "$(stat -c '%a' /etc/sing-box/api.secret 2>/dev/null)" = "600" ]; then
            echo "  ✓ Dashboard API 已启用（Secret 0600）"; _OK=$((_OK + 1))
        else
            echo "  ✗ Dashboard API/Secret 配置不完整"; _FAIL=$((_FAIL + 1))
        fi
    ;; esac

    # ---------- 结果 ----------
    _TOTAL=$((_OK + _FAIL))
    echo "[check] === $_OK/$_TOTAL 通过 ==="
    [ "$_FAIL" -eq 0 ] || { echo "[check] 构建不完整，中止"; exit 1; }
}
