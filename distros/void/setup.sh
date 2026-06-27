#!/bin/sh
#
# distros/void/setup.sh —— Void chroot 内设置
#   安装包 + 部署配置 + 系统设置 + 启用服务
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-void}"
REPO="${REPO:-https://repo-default.voidlinux.org/current/aarch64}"
SERIAL_DEV="${SERIAL_DEV:-ttyS2}"
SERIAL_BAUD="${SERIAL_BAUD:-1500000}"

. /download-helpers.sh

# ============================================================
#  1. 安装包 —— 按 package.list 三段安装
# ============================================================
echo "[setup] === 安装系统包 ==="
_PKG_LIST_="/package.list"
if [ -f "${_PKG_LIST_}" ]; then
    while read -r _line_; do
        # 空行
        [ -z "${_line_}" ] && continue

        # 检查是否为 section header：# ========== xxx ==========
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
            '#'*) continue ;;  # 其他注释行跳过
        esac

        # 跳过非当前 section 的行（landscape 暂不处理）
        [ "${_section_}" = "landscape" ] && continue

        # 解析安装标记
        case "${_line_}" in
            '[pm]'*)
                _pkg_="${_line_#\[pm\] }"
                echo "[setup]   [pm] ${_pkg_}"
                xbps-install -y -S -R "${REPO}" "${_pkg_}"
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

# 递归复制配置到 /etc/（不含 init/ 子目录）
for _f_ in "${_CFG_}"/*; do
    _base_="$(basename "${_f_}")"
    [ "${_base_}" = "init" ] && continue
    cp -r "${_f_}" /etc/
done

# 清理文档文件
find /etc \( -name '*.md' -o -name '*.example' \) -exec rm -f {} + 2>/dev/null || true

# 部署 runit 服务文件
if [ -d "${_CFG_}/init/runit" ]; then
    for _sv_dir_ in "${_CFG_}/init/runit/"*/; do
        [ -d "${_sv_dir_}" ] && cp -r "${_sv_dir_}" /etc/sv/
    done
fi

# 统一路径：包管理器装的 sing-box 在 /usr/bin/，ln -s 到 /usr/local/bin/
if [ ! -e /usr/local/bin/sing-box ] && [ -x /usr/bin/sing-box ]; then
    ln -s /usr/bin/sing-box /usr/local/bin/sing-box
fi

# ============================================================
#  3. 系统设置
# ============================================================
echo "[setup] === 系统设置 ==="

echo "[setup] xbps-reconfigure -a ..."
xbps-reconfigure -a

echo "[setup] 设置 root 密码 ..."
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "[setup] 设置默认 shell 为 bash ..."
/usr/sbin/usermod -s /bin/bash root

echo "[setup] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > /etc/hostname
if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> /etc/hosts
fi

echo "[setup] 配置串口控制台 ${SERIAL_DEV} @ ${SERIAL_BAUD} ..."
SVC_DIR="/etc/sv/agetty-${SERIAL_DEV}"
mkdir -p "${SVC_DIR}"
cat > "${SVC_DIR}/run" <<EOF
#!/bin/sh
exec 2>&1
[ -r conf ] && . ./conf
exec setsid /sbin/agetty --keep-baud "${SERIAL_DEV}" "\${baud_rate:-${SERIAL_BAUD}}" "\${term:-linux}"
EOF
chmod +x "${SVC_DIR}/run"
cat > "${SVC_DIR}/conf" <<EOF
baud_rate=${SERIAL_BAUD}
term=linux
EOF
mkdir -p /etc/runit/runsvdir/default
rm -f "/etc/runit/runsvdir/default/agetty-${SERIAL_DEV}"
ln -s "${SVC_DIR}" "/etc/runit/runsvdir/default/agetty-${SERIAL_DEV}"

# ============================================================
#  4. 启用路由器服务
# ============================================================
echo "[setup] === 启用服务 ==="
. /service.sh
enable_router_services

# ============================================================
#  5. 清理
# ============================================================
rm -rf /var/cache/xbps/* 2>/dev/null || true
echo "[setup] 完成。"
