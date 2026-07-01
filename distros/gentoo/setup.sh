#!/bin/sh
#
# distros/gentoo/setup.sh —— Gentoo chroot 内设置（在 stage3 环境中运行）
#   用 ROOT= emerge 安装包到目标 rootfs + 部署配置 + 系统设置 + 启用服务
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-gentoo}"
TARGET_ROOTFS="${TARGET_ROOTFS:-/gentoo-rootfs}"
SERIAL_DEV="${SERIAL_DEV:-ttyS2}"
SERIAL_BAUD="${SERIAL_BAUD:-1500000}"
GENTOO_MIRROR_BASE="${GENTOO_MIRROR_BASE:-https://distfiles.gentoo.org}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /download-helpers.sh

# ============================================================
#  0. 初始化目标 rootfs 基础目录结构
# ============================================================
echo "[setup] === 初始化目标 rootfs: ${TARGET_ROOTFS} ==="
mkdir -p "${TARGET_ROOTFS}"/{dev,proc,sys,run,tmp,var,etc,usr,root,home}
mkdir -p "${TARGET_ROOTFS}"/var/{cache,lib,log,run,empty,tmp/portage}
mkdir -p "${TARGET_ROOTFS}"/usr/{bin,sbin,lib,local}
mkdir -p "${TARGET_ROOTFS}"/usr/local/{bin,sbin}
mkdir -p "${TARGET_ROOTFS}"/etc/{init.d,conf.d,portage,env.d}

# 创建基础系统文件（emerge acct-group/* 需要这些文件存在）
echo "[setup] 创建基础系统文件 ..."
cat > "${TARGET_ROOTFS}/etc/group" <<'EOF'
root:x:0:
bin:x:1:
daemon:x:2:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
lp:x:7:
mem:x:8:
kmem:x:9:
wheel:x:10:
cdrom:x:11:
dialout:x:18:
floppy:x:19:
audio:x:29:
video:x:27:
input:x:24:
kvm:x:78:
render:x:999:
sgx:x:998:
shadow:x:997:
EOF

cat > "${TARGET_ROOTFS}/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF

cat > "${TARGET_ROOTFS}/etc/shadow" <<'EOF'
root:!:19000:0:99999:7:::
EOF
chmod 640 "${TARGET_ROOTFS}/etc/shadow"

cat > "${TARGET_ROOTFS}/etc/gshadow" <<'EOF'
root:::
EOF
chmod 640 "${TARGET_ROOTFS}/etc/gshadow"

# ============================================================
#  1. 配置 Portage（在 stage3 环境内）
# ============================================================
echo "[setup] === 配置 Portage ==="

# 计算 CPU 核心数
_NPROC_="$(nproc 2>/dev/null || echo 4)"

# Portage 配置（动态适配：原生 ARM64 多核编译，QEMU 保守单核）
mkdir -p /etc/portage

# 检测是否在 QEMU 用户态模拟下运行
# HOST_ARCH 由 build.sh 传入（宿主的架构）
# 若宿主本身是 aarch64，则为原生 ARM64 编译，可安全多核
# 若宿主是 x86_64 等，则为 QEMU 跨架构编译，需限制并发
if [ "${HOST_ARCH:-}" = "aarch64" ] || [ "${HOST_ARCH:-}" = "arm64" ]; then
    _NATIVE_ARM_="1"
    _MAKEOPTS_="-j${_NPROC_}"
    _EMERGE_JOBS_="${_NPROC_}"
    # 原生 ARM64：启用 sandbox 保证构建正确性
    _FEATURES_="getbinpkg -binpkg-verify-signature"
else
    _NATIVE_ARM_="0"
    _MAKEOPTS_="-j1"
    _EMERGE_JOBS_="1"
    # QEMU/WSL2：禁用 sandbox（/dev/pts 无法正常挂载，PTY 会耗尽）
    _FEATURES_="getbinpkg -sandbox -usersandbox -ipc-sandbox -network-sandbox -pid-sandbox -binpkg-verify-signature"
fi

cat > /etc/portage/make.conf <<EOF
# Gentoo 镜像源（distfiles 下载）
GENTOO_MIRRORS="${GENTOO_MIRROR_BASE}/distfiles"

# 编译选项（原生 ARM64: 多核 / QEMU: 单核避免 PTY/CLONE_THREAD 问题）
MAKEOPTS="${_MAKEOPTS_}"
EMERGE_DEFAULT_OPTS="--jobs=${_EMERGE_JOBS_} --quiet-build"

# FEATURES（原生 ARM64 启用 sandbox，QEMU 下禁用）
FEATURES="\${FEATURES} ${_FEATURES_}"
BINPKG_VERIFY_SIGNATURE="no"

# 禁用 binpkg GPG 签名校验（构建环境，非生产系统）
# 防止 portage 调用 getuto 时因缺少 sec-keys/openpgp-keys-gentoo-release 而报错
USE="\${USE} -systemd -gnome -gnome-keyring -binpkg-request-signature"

# 匹配 arm64 binhost 的 Python 版本（systemd-utils 的 REQUIRED_USE 要求）
PYTHON_SINGLE_TARGET="python3_13"
EOF

# 配置二进制包仓库（arm64-openrc binhost）
mkdir -p /etc/portage/binrepos.conf
cat > /etc/portage/binrepos.conf/gentoo.conf <<'EOF'
[gentoo]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/arm64/binpackages/23.0/arm64/
# 关闭 binpkg GPG 签名验证（2025+ Portage 新增的 per-repo 设置）
# QEMU 环境下 GPG 因 PTY 耗尽（openpty failed）无法运行，必须绕过
verify-signature = false
EOF

# package.mask：阻止不必要的包被二进制包反拉
mkdir -p /etc/portage/package.mask
cat > /etc/portage/package.mask/router <<'EOF'
sys-apps/systemd
sys-apps/gentoo-systemd-integration
# udev-init-scripts（源码 404，且路由器用 busybox mdev 无需 udev init）
sys-fs/udev-init-scripts
# shared-mime-info（桌面 MIME 数据库，路由器无用）
x11-misc/shared-mime-info
EOF
# package.use 配置（处理目录情况）
if [ -d "/etc/portage/package.use" ]; then
    # 如果是目录，写入子文件
    cat > /etc/portage/package.use/router <<'EOF'
sys-apps/busybox syslog mdev make-symlinks
app-misc/fastfetch -chafa -ddcutil -drm -efl -elf -vulkan -xrandr -dbus -gnome -imagemagick -lua -opencl -opengl -pulseaudio -sqlite -test -vaapi -vdpau -wayland -X -xcb
EOF
else
    # 如果是文件或不存在，直接写入
    cat > /etc/portage/package.use <<'EOF'
sys-apps/busybox syslog mdev make-symlinks
app-misc/fastfetch -chafa -ddcutil -drm -efl -elf -vulkan -xrandr -dbus -gnome -imagemagick -lua -opencl -opengl -pulseaudio -sqlite -test -vaapi -vdpau -wayland -X -xcb
EOF
fi

# 同步 Portage tree（如果还没有）
# 注意：emerge-webrsync 下载 snapshot 时临时用官方源，避免镜像 snapshots 不完整
if [ ! -d "/var/db/repos/gentoo" ] || [ -z "$(ls -A /var/db/repos/gentoo 2>/dev/null)" ]; then
    echo "[setup] 同步 Portage tree（使用官方源）..."
    GENTOO_MIRRORS="https://distfiles.gentoo.org" emerge-webrsync || \
        GENTOO_MIRRORS="https://distfiles.gentoo.org" emerge --sync
fi

# 手动部署 Gentoo release GPG 密钥到 TARGET_ROOTFS
# 优先从 stage3 复制，避免硬编码日期 URL 过期
echo "[setup] 手动部署 Gentoo release GPG 密钥到目标 rootfs ..."
mkdir -p "${TARGET_ROOTFS}/usr/share/openpgp-keys"
if [ -f /usr/share/openpgp-keys/gentoo-release.asc ]; then
    cp /usr/share/openpgp-keys/gentoo-release.asc "${TARGET_ROOTFS}/usr/share/openpgp-keys/"
    echo "[setup]   从 stage3 复制 GPG 密钥成功"
else
    echo "[setup]   提示: stage3 无 GPG 密钥（当前已禁用 binpkg 签名校验，不影响安装）" >&2
fi

# ============================================================
#  2. 安装包到目标 rootfs —— 按 package.list 三段安装
# ============================================================
echo "[setup] === 安装系统包到 ${TARGET_ROOTFS} ==="

_PKG_LIST_="/package.list"
_PM_PKGS_=""

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
                _PM_PKGS_="${_PM_PKGS_} ${_pkg_}"
                ;;
            '[dl@'*)
                # dl 包稍后处理（先装完 pm 包）
                ;;
        esac
    done < "${_PKG_LIST_}"
else
    echo "[setup] 警告: ${_PKG_LIST_} 不存在" >&2
fi

# 批量 emerge 安装到 ROOT
# 默认 --binpkg-respect-use=y：拒绝 USE 不匹配的 binpkg，避免 systemd/GNOME 依赖链
# 被二进制包带入 OpenRC 目标 rootfs。缺失的包自动回退到源码编译
# --autounmask=y --autounmask-continue=y --autounmask-keep-masks=y：
# 自动处理 USE/keyword 变更并继续，但保留 package.mask/router 中已有的 mask
if [ -n "${_PM_PKGS_}" ]; then
    echo "[setup] 执行: ROOT=${TARGET_ROOTFS} emerge ${_PM_PKGS_}"
    ROOT="${TARGET_ROOTFS}" emerge --buildpkg=n --autounmask=y --autounmask-continue=y --autounmask-keep-masks=y ${_PM_PKGS_}
fi

# 处理 [dl@] 下载包（直接下载到 TARGET_ROOTFS）
if [ -f "${_PKG_LIST_}" ]; then
    _section_="base"
    while read -r _line_; do
        [ -z "${_line_}" ] && continue

        case "${_line_}" in
            '# ========== base'*) _section_="base"; continue ;;
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
            '[dl@'*)
                _line_="${_line_#\[dl@}"
                _url_="${_line_%%\] *}"
                _bin_="${_line_#*\] }"
                echo "[setup]   [dl@${_bin_}]"
                # 临时修改 _dl_url 输出目录为 TARGET_ROOTFS
                _orig_dl_url="${TARGET_ROOTFS}/usr/local/bin/${_bin_}"
                mkdir -p "${TARGET_ROOTFS}/usr/local/bin"
                _tmpdir_="/tmp/dl-$$-${_bin_}"
                _asset_="$(basename "${_url_}")"
                mkdir -p "${_tmpdir_}"

                _retry_=3
                while [ "${_retry_}" -gt 0 ]; do
                    if curl -fsSL "${_url_}" -o "${_tmpdir_}/${_asset_}" 2>/dev/null; then
                        break
                    fi
                    _retry_=$((_retry_ - 1))
                    [ "${_retry_}" -gt 0 ] && sleep "$(( (3 - _retry_) * 2 ))"
                done

                if [ "${_retry_}" -gt 0 ]; then
                    case "${_asset_}" in
                        *.tar.gz|*.tgz)
                            tar xzf "${_tmpdir_}/${_asset_}" -C "${_tmpdir_}"
                            find "${_tmpdir_}" -type f -name "${_bin_}" -exec cp -f {} "${_orig_dl_url}" \; 2>/dev/null || true
                            ;;
                        *)
                            cp -f "${_tmpdir_}/${_asset_}" "${_orig_dl_url}"
                            ;;
                    esac
                    chmod +x "${_orig_dl_url}"
                fi
                rm -rf "${_tmpdir_}"
                ;;
        esac
    done < "${_PKG_LIST_}"
fi


# ============================================================
#  2.5. busybox ntpd OpenRC 服务
# ============================================================
echo "[setup] === 配置 busybox ntpd ==="

# init 脚本
cat > "${TARGET_ROOTFS}/etc/init.d/busybox-ntpd" <<'INITEOF'
#!/sbin/openrc-run
description="Busybox NTP daemon"

depend() {
    use dns
    after net
}

start_pre() {
    # 从 RTC 恢复时间（即使不准确也给一个起点，后续 NTP 纠正）
    /bin/busybox hwclock --hctosys --utc 2>/dev/null || true
}

start() {
    ebegin "Starting ntpd"
    start-stop-daemon --start --quiet \
        --make-pidfile \
        --pidfile /run/busybox-ntpd.pid \
        --exec /bin/busybox -- ntpd -d -p pool.ntp.org -p ntp.cloudflare.com
    eend $?
}

stop() {
    ebegin "Stopping ntpd"
    start-stop-daemon --stop --quiet --pidfile /run/busybox-ntpd.pid
    # 关机前同步系统时间到 RTC
    /bin/busybox hwclock --systohc --utc 2>/dev/null || true
    eend $?
}
INITEOF
chmod 755 "${TARGET_ROOTFS}/etc/init.d/busybox-ntpd"

# conf.d
cat > "${TARGET_ROOTFS}/etc/conf.d/busybox-ntpd" <<'CONFEOF'
# NTP 服务器列表
NTP_SERVERS="pool.ntp.org ntp.cloudflare.com"
CONFEOF

# 配置时区
if [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    cp "/usr/share/zoneinfo/${TIMEZONE}" "${TARGET_ROOTFS}/etc/localtime" 2>/dev/null || true
else
    echo "[setup] 警告：时区文件 /usr/share/zoneinfo/${TIMEZONE} 不存在" >&2
fi

# ============================================================
#  3. 部署配置文件到目标 rootfs
# ============================================================
echo "[setup] === 部署出厂配置到 ${TARGET_ROOTFS} ==="

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
        cp -r "${_f_}" "${TARGET_ROOTFS}/etc/"
    done
    # 部署 OpenRC init 脚本
    if [ -d "${_CFG_}/init/openrc" ]; then
        cp -f "${_CFG_}/init/openrc/"* "${TARGET_ROOTFS}/etc/init.d/" 2>/dev/null || true
        chmod +x "${TARGET_ROOTFS}"/etc/init.d/* 2>/dev/null || true
    fi
done
IFS="${_OLD_IFS_}"

find "${TARGET_ROOTFS}/etc" \( -name '*.md' -o -name '*.example' \) -exec rm -f {} + 2>/dev/null || true

chmod +x "${TARGET_ROOTFS}"/etc/local.d/*.start 2>/dev/null || true

# 统一路径
if [ ! -e "${TARGET_ROOTFS}/usr/local/bin/sing-box" ] && [ -x "${TARGET_ROOTFS}/usr/bin/sing-box" ]; then
    ln -s /usr/bin/sing-box "${TARGET_ROOTFS}/usr/local/bin/sing-box"
fi

# ============================================================
#  4. 系统设置（在目标 rootfs 内配置）
# ============================================================
echo "[setup] === 系统设置 ==="

echo "[setup] 设置 root 密码 ..."
# 生成密码哈希（在 stage3 环境）并更新目标 shadow
_hash_="$(openssl passwd -6 "${ROOT_PASSWORD}")"
sed -i "s|^root:[^:]*:|root:${_hash_}:|" "${TARGET_ROOTFS}/etc/shadow"

echo "[setup] 确认默认 shell 为 bash ..."
sed -i '/^root:/ s|:[^:]*$|:/bin/bash|' "${TARGET_ROOTFS}/etc/passwd"

if [ ! -f "${TARGET_ROOTFS}/etc/shells" ]; then
    cat > "${TARGET_ROOTFS}/etc/shells" <<EOF
/bin/sh
/bin/bash
EOF
else
    grep -qx '/bin/bash' "${TARGET_ROOTFS}/etc/shells" 2>/dev/null || echo '/bin/bash' >> "${TARGET_ROOTFS}/etc/shells"
fi

echo "[setup] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > "${TARGET_ROOTFS}/etc/hostname"
if [ ! -f "${TARGET_ROOTFS}/etc/hosts" ]; then
    cat > "${TARGET_ROOTFS}/etc/hosts" <<EOF
127.0.0.1       localhost
127.0.1.1       ${HOSTNAME_VAL}
::1             localhost ip6-localhost ip6-loopback
EOF
else
    if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" "${TARGET_ROOTFS}/etc/hosts" 2>/dev/null; then
        printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> "${TARGET_ROOTFS}/etc/hosts"
    fi
fi

# 确保串口控制台（OpenRC inittab）
if [ ! -f "${TARGET_ROOTFS}/etc/inittab" ]; then
    cat > "${TARGET_ROOTFS}/etc/inittab" <<EOF
# Default runlevel
id:3:initdefault:

# System initialization
si::sysinit:/sbin/openrc sysinit
si::sysinit:/sbin/openrc boot
si::wait:/sbin/openrc default

# Termination
l0:0:wait:/sbin/openrc shutdown
l6:6:wait:/sbin/openrc reboot

# Serial console
${SERIAL_DEV}::respawn:/sbin/agetty ${SERIAL_BAUD} ${SERIAL_DEV} vt100
EOF
else
    if ! grep -q "${SERIAL_DEV}" "${TARGET_ROOTFS}/etc/inittab" 2>/dev/null; then
        echo "${SERIAL_DEV}::respawn:/sbin/agetty ${SERIAL_BAUD} ${SERIAL_DEV} vt100" >> "${TARGET_ROOTFS}/etc/inittab"
    fi
fi

echo "[setup] 启用基础服务 ..."
# OpenRC 服务启用需要在目标 rootfs 的 /etc/runlevels/ 下操作
mkdir -p "${TARGET_ROOTFS}/etc/runlevels"/{boot,default,sysinit}

# ============================================================
#  5. 启用路由器服务（通过修改目标 rootfs 的 runlevels）
# ============================================================
echo "[setup] === 启用服务 ==="

# 定义服务启用函数（直接操作 TARGET_ROOTFS）
_enable_service_target() {
    _svc_="$1"
    _rl_="${2:-default}"
    if [ -f "${TARGET_ROOTFS}/etc/init.d/${_svc_}" ]; then
        mkdir -p "${TARGET_ROOTFS}/etc/runlevels/${_rl_}"
        ln -sf "/etc/init.d/${_svc_}" "${TARGET_ROOTFS}/etc/runlevels/${_rl_}/${_svc_}" 2>/dev/null || true
        echo "[service]   启用: ${_svc_} (${_rl_})"
    fi
}

# 系统基础服务
_enable_service_target bootmisc boot
_enable_service_target syslog default
_enable_service_target crond default

# base 应用服务
_enable_service_target sshd default
_enable_service_target busybox-ntpd default
_enable_service_target nftables default

# 根据 INFRA 启用组件服务
case ",${INFRA:-sing-box}," in
    *",sing-box,"*)
        echo "[service] --- sing-box 服务 ---"
        _enable_service_target dnsmasq default
        _enable_service_target tailscale default
        _enable_service_target sing-box default
        _enable_service_target cloudflared default
        ;;
    *",landscape,"*)
        echo "[service] --- landscape 服务 ---"
        # TODO: landscape services
        ;;
esac

# 密钥注入（如果需要在目标 rootfs 内注入）
# 注意：inject-secrets.sh 需要知道目标路径
if [ -x /inject-secrets.sh ]; then
    TARGET_ROOT="${TARGET_ROOTFS}" /bin/sh /inject-secrets.sh
fi

# ============================================================
#  6. 清理
# ============================================================
echo "[setup] 清理缓存 ..."
rm -rf "${TARGET_ROOTFS}/var/cache/edb/"* 2>/dev/null || true
rm -rf "${TARGET_ROOTFS}/var/tmp/"* 2>/dev/null || true

echo "[setup] 完成。目标 rootfs: ${TARGET_ROOTFS}"
