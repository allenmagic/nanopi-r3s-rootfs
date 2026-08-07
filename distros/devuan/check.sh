#
# distros/devuan/check.sh —— Devuan (sysvinit) 构建完整性检查
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

    # ---------- 3. sysvinit 服务启用 ----------
    _check_init() { _s_="$1"
        if [ -x "/etc/init.d/$_s_" ]; then
            _found=""
            for _r_ in /etc/rc?.d/S[0-9][0-9]$_s_; do
                [ -f "$_r_" ] && _found="yes"
            done
            [ -n "$_found" ] || _found=$(ls /etc/rc?.d/S[0-9][0-9]$_s_ 2>/dev/null || true)
            if [ -n "$_found" ]; then
                echo "  ✓ $_s_"; _OK=$((_OK + 1))
            else
                echo "  ✗ $_s_ init 脚本存在但未在 rc.d 注册"; _FAIL=$((_FAIL + 1))
            fi
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] sysvinit 服务:"
    _check_init ssh
    _check_init chrony
    _check_init nftables
    _check_init dnsmasq
    _check_init tailscaled
    _check_init cloudflared
    _check_init network-watchdog

    # sing-box 仅在 INFRA=sing-box 时检查
    case ",${INFRA:-base}," in *",sing-box,"*)
        _check_init sing-box
    ;; esac

    # ---------- 结果 ----------
    _TOTAL=$((_OK + _FAIL))
    echo "[check] === $_OK/$_TOTAL 通过 ==="
    [ "$_FAIL" -eq 0 ] || { echo "[check] 构建不完整，中止"; exit 1; }
}
