#!/bin/sh
#
# distros/debian/setup.sh —— Debian chroot 内设置（systemd）
#   安装包 + 部署配置 + 系统设置 + 启用服务
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-passwd123}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-debian}"
SUITE="${SUITE:-stable}"
REPO="${REPO:-http://deb.debian.org/debian}"
SERIAL_DEV="${SERIAL_DEV:-ttyS2}"
SERIAL_BAUD="${SERIAL_BAUD:-1500000}"

export DEBIAN_FRONTEND=noninteractive

. /download-helpers.sh

# ============================================================
#  1. 安装包 —— 按 package.list 三段安装
# ============================================================
echo "[setup] === 安装系统包 ==="

# 先更新 apt 索引
apt-get update

_PKG_LIST_="/package.list"
if [ -f "${_PKG_LIST_}" ]; then
    while read -r _line_; do
        [ -z "${_line_}" ] && continue

        case "${_line_}" in
            '# ========== base'*)
                _section_="base"
                echo "[setup] --- 段: base ---"
                continue
                ;;
            '# ========== router'*)
                _section_="router"
                echo "[setup] --- 段: router ---"
                continue
                ;;
            '# ========== landscape'*)
                _section_="landscape"
                echo "[setup] --- 段: landscape ---"
                continue
                ;;
            '#'*) continue ;;
        esac

        [ "${_section_}" = "landscape" ] && continue

        case "${_line_}" in
            '[pm]'*)
                _pkg_="${_line_#\[pm\] }"
                echo "[setup]   [pm] ${_pkg_}"
                apt-get install -y --no-install-recommends "${_pkg_}"
                ;;
            '[dl@'*)
                _line_="${_line_#\[dl@}"
                _url_="${_line_%%\] *}"
                _bin_="${_line_#*\] }"
                echo "[setup]   [dl@${_bin_}]"
                _dl_url "${_url_}" "${_bin_}"
                ;;
        esac
    done < "${_PKG_LIST_}"
else
    echo "[setup] 警告: ${_PKG_LIST_} 不存在" >&2
fi

# ============================================================
#  2. 部署配置文件
# ============================================================
echo "[setup] === 部署出厂配置 ==="
_CFG_="/infra/sing-box/config"

for _f_ in "${_CFG_}"/*; do
    _base_="$(basename "${_f_}")"
    [ "${_base_}" = "init" ] && continue
    cp -r "${_f_}" /etc/
done

find /etc \( -name '*.md' -o -name '*.example' \) -exec rm -f {} + 2>/dev/null || true

# 部署 systemd unit 文件
if [ -d "${_CFG_}/init/systemd" ]; then
    cp -f "${_CFG_}/init/systemd/"* /etc/systemd/system/ 2>/dev/null || true
fi

if [ ! -e /usr/local/bin/sing-box ] && [ -x /usr/bin/sing-box ]; then
    ln -s /usr/bin/sing-box /usr/local/bin/sing-box
fi

# ============================================================
#  3. 系统设置
# ============================================================
echo "[setup] === 系统设置 ==="

echo "[setup] 设置 root 密码 ..."
echo "root:${ROOT_PASSWORD}" | /usr/sbin/chpasswd

echo "[setup] 设置默认 shell 为 bash ..."
/usr/sbin/usermod -s /bin/bash root

echo "[setup] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > /etc/hostname
if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> /etc/hosts
fi

echo "[setup] 启用基础服务 ..."
systemctl enable ssh
systemctl enable chrony

echo "[setup] 配置串口控制台 ${SERIAL_DEV} @ ${SERIAL_BAUD} ..."
mkdir -p /etc/systemd/system/serial-getty@"${SERIAL_DEV}".service.d
cat > /etc/systemd/system/serial-getty@"${SERIAL_DEV}".service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -L ${SERIAL_DEV} ${SERIAL_BAUD} vt100
EOF
systemctl enable serial-getty@"${SERIAL_DEV}".service

# ============================================================
#  4. 启用路由器服务
# ============================================================
echo "[setup] === 启用服务 ==="
. /service.sh
enable_router_services

# ============================================================
#  5. 清理
# ============================================================
echo "[setup] 清理 apt 缓存 ..."
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb 2>/dev/null || true
echo "[setup] 完成。"
