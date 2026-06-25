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
    iproute2 iputils ifupdown dhcpcd tzdata openssh nano

# ---------- 第五步：系统设置 ----------
echo "[chroot] xbps-reconfigure -a ..."
xbps-reconfigure -a

echo "[chroot] 设置 root 密码 ..."
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "[chroot] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > /etc/hostname

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
ln -sf "/etc/sv/agetty-${SERIAL_DEV}" "/etc/runit/runsvdir/default/agetty-${SERIAL_DEV}"
[ -d /etc/sv/sshd ] && ln -sf /etc/sv/sshd /etc/runit/runsvdir/default/sshd

rm -rf /var/cache/xbps/* 2>/dev/null || true
echo "[chroot] setup 完成。"
