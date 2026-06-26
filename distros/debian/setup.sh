#!/bin/sh
#
# distros/debian/setup.sh —— Debian chroot 内设置（systemd）
#   装工具 + 启用服务(systemctl) + root 密码 + 主机名 + 串口控制台(systemd)
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-passwd123}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-debian}"
SUITE="${SUITE:-stable}"
SERIAL_DEV="${SERIAL_DEV:-ttyS2}"
SERIAL_BAUD="${SERIAL_BAUD:-1500000}"

export DEBIAN_FRONTEND=noninteractive

# ---------- 第四步：安装必要工具 ----------
echo "[chroot] 更新 apt 索引 ..."
apt-get update

echo "[chroot] 安装必要工具 ..."
apt-get install -y --no-install-recommends \
    ncurses-bin ncurses-base \
    iproute2 iputils-ping ifupdown dhcpcd5 tzdata \
    openssh-server nano chrony \
    passwd systemd-sysv

# ---------- 第五步：系统设置 ----------
echo "[chroot] 设置 root 密码 ..."
echo "root:${ROOT_PASSWORD}" | /usr/sbin/chpasswd

echo "[chroot] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > /etc/hostname
# Debian 系惯例：/etc/hosts 里给主机名一条回环记录
if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> /etc/hosts
fi

echo "[chroot] 启用服务（systemctl）..."
systemctl enable ssh
systemctl enable chrony

echo "[chroot] 配置串口控制台 ${SERIAL_DEV} @ ${SERIAL_BAUD}（systemd）..."
# systemd 有 serial-getty@.service 模板，直接 enable 对应设备即可
# 覆盖默认 baud rate
mkdir -p /etc/systemd/system/serial-getty@"${SERIAL_DEV}".service.d
cat > /etc/systemd/system/serial-getty@"${SERIAL_DEV}".service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -L ${SERIAL_DEV} ${SERIAL_BAUD} vt100
EOF
systemctl enable serial-getty@"${SERIAL_DEV}".service

# ---------- 瘦身 ----------
echo "[chroot] 清理 apt 缓存 ..."
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb 2>/dev/null || true

echo "[chroot] setup 完成。"
