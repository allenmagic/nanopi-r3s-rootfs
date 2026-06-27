#!/bin/sh
#
# distros/void/setup.sh —— Void chroot 内设置
#   装工具 + xbps-reconfigure + root 密码 + 主机名 + 串口控制台
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-void}"
REPO="${REPO:-https://repo-default.voidlinux.org/current/aarch64}"
SERIAL_DEV="${SERIAL_DEV:-ttyS2}"
SERIAL_BAUD="${SERIAL_BAUD:-1500000}"

# ---------- 第四步：安装必要工具 ----------
echo "[chroot] 安装必要工具 ..."
# 兜底公钥导入交互；补 ncurses-base（terminfo 数据库，clear/tput 依赖）
xbps-install -y -S -R "${REPO}" \
    ncurses ncurses-base \
    iproute2 iputils ifupdown dhcpcd tzdata openssh nano chrony bash curl

# ---------- 第五步：系统设置 ----------
echo "[chroot] xbps-reconfigure -a ..."
xbps-reconfigure -a

echo "[chroot] 设置 root 密码 ..."
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "[chroot] 设置默认 shell 为 bash ..."
/usr/sbin/usermod -s /bin/bash root

echo "[chroot] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > /etc/hostname
# 在 /etc/hosts 加主机名记录，避免 sudo 等程序 unresolved host 警告
if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> /etc/hosts
fi

echo "[chroot] 配置串口控制台 ${SERIAL_DEV} @ ${SERIAL_BAUD} ..."
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
# runit 服务是目录，ln -sf 不会覆盖已有目录，需先移除
mkdir -p /etc/runit/runsvdir/default
rm -f "/etc/runit/runsvdir/default/agetty-${SERIAL_DEV}"
ln -s "/etc/sv/agetty-${SERIAL_DEV}" "/etc/runit/runsvdir/default/agetty-${SERIAL_DEV}"
if [ -d /etc/sv/sshd ]; then
    rm -f /etc/runit/runsvdir/default/sshd
    ln -s /etc/sv/sshd /etc/runit/runsvdir/default/sshd
fi

# ---------- 第六步：安装路由器软件 ----------
echo "[chroot] 执行 install_router_software ..."
. /install-router-software.sh
install_router_software

# ---------- 第七步：启用路由器服务 ----------
echo "[chroot] 执行 enable_router_services ..."
enable_router_services

rm -rf /var/cache/xbps/* 2>/dev/null || true
echo "[chroot] setup 完成。"
