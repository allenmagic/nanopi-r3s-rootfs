#!/bin/sh
# modules-load —— 补齐 Void 缺失的 modules-load(8)
#
# Void 的 runit core-service 02-kmods 会调用 `modules-load -v`，但 Void 的
# kmod 包并不提供这个命令（它来自 systemd）。没有它 /etc/modules-load.d/
# 里的 tun/wireguard/r8169 永远不会加载，R3S 的 LAN 口（PCIe RTL8111H）
# 也就不会出现。
#
# 行为与 systemd 保持一致：读取 /etc/modules-load.d/*.conf，每行一个模块名，
# # 开头为注释；-v/--verbose 时把模块名打印到 stdout（02-kmods 用输出展示
# 加载了哪些模块）。
#
set -eu

_verbose_=0
for _a_ in "$@"; do
    case "${_a_}" in
        -v|--verbose) _verbose_=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

for _f_ in /etc/modules-load.d/*.conf; do
    [ -f "${_f_}" ] || continue
    while IFS= read -r _line_ || [ -n "${_line_}" ]; do
        _line_="${_line_%%#*}"
        _line_="$(printf '%s' "${_line_}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "${_line_}" ] || continue
        [ "${_verbose_}" -eq 1 ] && printf '%s\n' "${_line_}"
        modprobe "${_line_}" 2>/dev/null || true
    done < "${_f_}"
done
