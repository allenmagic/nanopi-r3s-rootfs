#!/bin/sh
#
# distros/devuan/setup.sh —— Devuan chroot 内设置（sysvinit）
#   安装包 + 部署配置 + 系统设置 + 启用服务
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-passwd123}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-devuan}"
SUITE="${SUITE:-excalibur}"
REPO="${REPO:-http://deb.devuan.org/merged}"
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
            '# ========== sing-box'*)
                case ",${INFRA:-sing-box}," in *",sing-box,"*) _section_="packages" ;; *) _section_="skip" ;; esac
                continue
                ;;
            '# ========== landscape'*)
                case ",${INFRA:-sing-box}," in *",landscape,"*) _section_="packages" ;; *) _section_="skip" ;; esac
                continue
                ;;
            '#'*) continue ;;
        esac

        [ "${_section_}" = "skip" ] && continue

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
_OLD_IFS_="${IFS}"; IFS=","
for _comp_ in ${INFRA:-sing-box}; do
    IFS="${_OLD_IFS_}"
    _comp_="$(echo "${_comp_}" | tr -d '[:space:]')"
    [ -z "${_comp_}" ] && continue
    _CFG_="/infra/${_comp_}/config"
    [ ! -d "${_CFG_}" ] && continue
    echo "[setup]   部署 /infra/${_comp_}/config/ ..."
    for _f_ in "${_CFG_}"/*; do
        [ ! -e "${_f_}" ] && continue
        _base_="$(basename "${_f_}")"
        [ "${_base_}" = "init" ] && continue
        cp -r "${_f_}" /etc/
    done
    if [ -d "${_CFG_}/init/sysvinit" ]; then
        cp -f "${_CFG_}/init/sysvinit/"* /etc/init.d/ 2>/dev/null || true
        chmod +x /etc/init.d/* 2>/dev/null || true
    fi
done
IFS="${_OLD_IFS_}"

find /etc \( -name '*.md' -o -name '*.example' \) -exec rm -f {} + 2>/dev/null || true

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
grep -qx '/bin/bash' /etc/shells 2>/dev/null || echo '/bin/bash' >> /etc/shells
chsh -s /bin/bash root 2>/dev/null || \
    sed -i '/^root:/ s|:[^:]*$|:/bin/bash|' /etc/passwd

echo "[setup] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > /etc/hostname
if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> /etc/hosts
fi

echo "[setup] 启用基础服务 ..."
update-rc.d ssh defaults >/dev/null 2>&1 || true
update-rc.d chrony defaults >/dev/null 2>&1 || true

echo "[setup] 配置串口控制台 ${SERIAL_DEV} @ ${SERIAL_BAUD} ..."
GETTY_ID="$(echo "${SERIAL_DEV}" | sed 's/^tty//')"
INITTAB_LINE="${GETTY_ID}:23:respawn:/sbin/getty -L ${SERIAL_DEV} ${SERIAL_BAUD} vt100"
touch /etc/inittab
sed -i "\#:/sbin/getty -L ${SERIAL_DEV} #d" /etc/inittab
sed -i "/^${GETTY_ID}:/d" /etc/inittab
echo "${INITTAB_LINE}" >> /etc/inittab

# ============================================================
#  4. 启用路由器服务
# ============================================================
echo "[setup] === 启用服务 ==="
. /service.sh
enable_router_services

# 密钥注入
[ -x /inject-secrets.sh ] && /bin/sh /inject-secrets.sh

# ============================================================
#  5. 清理
# ============================================================
echo "[setup] 清理 apt 缓存 ..."
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb 2>/dev/null || true
echo "[setup] 完成。"
