#!/bin/sh
#
# distros/devuan/setup.sh —— Devuan chroot 内设置（默认 sysvinit，不换 init）
#   装工具 + 启用服务(update-rc.d) + root 密码 + 主机名 + 串口控制台(/etc/inittab)
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-passwd123}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-devuan}"
SUITE="${SUITE:-daedalus}"
SERIAL_DEV="${SERIAL_DEV:-ttyS2}"
SERIAL_BAUD="${SERIAL_BAUD:-1500000}"

export DEBIAN_FRONTEND=noninteractive

# ---------- 第四步：安装必要工具 ----------
echo "[chroot] 更新 apt 索引 ..."
apt-get update

echo "[chroot] 安装必要工具 ..."
# 注：sysvinit 体系，这些 deb 包自带 /etc/init.d/ 脚本，开箱即用
apt-get install -y --no-install-recommends \
    ncurses-bin ncurses-base \
    iproute2 iputils-ping ifupdown dhcpcd5 tzdata \
    openssh-server nano chrony \
    passwd

# ---------- 第五步：系统设置 ----------
echo "[chroot] 设置 root 密码 ..."
echo "root:${ROOT_PASSWORD}" | /usr/sbin/chpasswd

echo "[chroot] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > /etc/hostname
# Debian 系惯例：/etc/hosts 里给主机名一条回环记录，避免 sudo/部分程序解析告警
if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> /etc/hosts
fi

echo "[chroot] 启用服务（sysvinit / update-rc.d）..."
# deb 包安装时通常已注册默认 runlevel；这里显式确保（幂等）
update-rc.d ssh defaults    >/dev/null 2>&1 || true
update-rc.d chrony defaults >/dev/null 2>&1 || true

echo "[chroot] 配置串口控制台 ${SERIAL_DEV} @ ${SERIAL_BAUD}（/etc/inittab）..."
# sysvinit 用 /etc/inittab 的 getty 行管理串口控制台
# id 取设备名去掉 tty 前缀的末段，保证唯一（如 ttyS2 → S2）
GETTY_ID="$(echo "${SERIAL_DEV}" | sed 's/^tty//')"
INITTAB_LINE="${GETTY_ID}:23:respawn:/sbin/getty -L ${SERIAL_DEV} ${SERIAL_BAUD} vt100"
touch /etc/inittab
# 移除同设备的旧行后重新追加（幂等）
sed -i "\#:/sbin/getty -L ${SERIAL_DEV} #d" /etc/inittab
sed -i "/^${GETTY_ID}:/d" /etc/inittab
echo "${INITTAB_LINE}" >> /etc/inittab

# ---------- 瘦身 ----------
echo "[chroot] 清理 apt 缓存 ..."
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb 2>/dev/null || true

echo "[chroot] setup 完成。"
