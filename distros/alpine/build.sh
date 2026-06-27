#!/usr/bin/env bash
#
# distros/alpine/build.sh —— 构建 Alpine aarch64 rootfs
# 从 dl-cdn.alpinelinux.org 下载 minirootfs tarball 并 chroot 配置
# 产物落在仓库内 build/alpine/（被 .gitignore 排除）
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"     # → distros/alpine
REPO_ROOT="$(readlink -f "${SCRIPT_DIR}/../..")"  # → 仓库根
source "${REPO_ROOT}/lib/chroot-helper.sh"

# ---------- 可配置参数 ----------
DISTRO="alpine"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build}"
BUILD_BASE="${BUILD_BASE:-${BUILD_ROOT}/${DISTRO}}"
ROOTFS="${ROOTFS:-${BUILD_BASE}/alpine-rootfs}"
CACHE_DIR="${CACHE_DIR:-${BUILD_BASE}/cache}"
MIRROR="${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ARCH="${ARCH:-aarch64}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-alpine}"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
PACK="${PACK:-0}"                                            # 1=构建后顺带打包

# ---------- 镜像源映射 ----------
declare -A MIRRORS
MIRRORS["default"]="https://dl-cdn.alpinelinux.org/alpine"
MIRRORS["aliyun"]="https://mirrors.aliyun.com/alpine"
MIRRORS["tuna"]="https://mirrors.tuna.tsinghua.edu.cn/alpine"
MIRRORS["tsinghua"]="https://mirrors.tuna.tsinghua.edu.cn/alpine"

_REPO_IN="${REPO:-default}"
if [[ "${_REPO_IN}" =~ ^https?:// ]]; then
    MIRROR="${_REPO_IN}"
else
    MIRROR="${MIRRORS[${_REPO_IN}]:-${MIRRORS[default]}}"
fi
unset _REPO_IN

# ---------- 路径准备 ----------
BUILD_ROOT="$(readlink -m "${BUILD_ROOT}")"
BUILD_BASE="$(readlink -m "${BUILD_BASE}")"
ROOTFS="$(readlink -m "${ROOTFS}")"
CACHE_DIR="$(readlink -m "${CACHE_DIR}")"
WORKDIR="$(dirname "${ROOTFS}")"

# ---------- 提权前：以普通用户创建构建目录树 ----------
if [ "${EUID}" -ne 0 ]; then
    mkdir -p "${BUILD_BASE}" "${WORKDIR}"
fi

# ---------- 权限 ----------
[ "${EUID}" -eq 0 ] || exec sudo -E "$0" "$@"

# root 态：补建缓存目录
mkdir -p "${CACHE_DIR}"
[ -f "${SETUP_SCRIPT}" ] || { echo "缺少 ${SETUP_SCRIPT}" >&2; exit 1; }

# 护栏
case "${WORKDIR}" in
    /|/tmp|/var/tmp|/home|/root|/usr|/etc)
        echo "错误：构建工作区不能是共享系统目录 (${WORKDIR})。" >&2
        exit 1 ;;
esac

# ---------- 跨架构预检 ----------
HOST_ARCH="$(uname -m)"
if [ "${HOST_ARCH}" != "aarch64" ] && [ "${HOST_ARCH}" != "arm64" ]; then
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo "错误：宿主架构为 ${HOST_ARCH}，但未注册 aarch64 的 binfmt/qemu。" >&2
        exit 1
    fi
fi
echo "[alpine] 跨架构预检通过（宿主 ${HOST_ARCH}）"

# ---------- 第一步：下载 alpine-minirootfs ----------
echo "[alpine] 1. 解析最新 minirootfs 版本 ..."
BASE_URL="${MIRROR}/latest-stable/releases/${ARCH}"
LATEST_YAML="$(curl -fsSL "${BASE_URL}/latest-releases.yaml" 2>/dev/null || true)"
FILENAME="$(echo "${LATEST_YAML}" | grep -oE 'alpine-minirootfs-[0-9.]+-'"${ARCH}"'\.tar\.gz' | head -n1)"
[ -n "${FILENAME}" ] || { echo "错误：无法解析 minirootfs 文件名" >&2; exit 1; }
echo "[alpine]   最新: ${FILENAME}"

CACHE_DIR="${BUILD_BASE}/cache"
mkdir -p "${CACHE_DIR}"
TARBALL="${CACHE_DIR}/${FILENAME}"

if [ ! -f "${TARBALL}" ]; then
    echo "[alpine]   下载 ${BASE_URL}/${FILENAME} ..."
    wget -qO "${TARBALL}" "${BASE_URL}/${FILENAME}"
    wget -qO "${TARBALL}.sha256" "${BASE_URL}/${FILENAME}.sha256" 2>/dev/null || true
    if [ -f "${TARBALL}.sha256" ]; then
        (cd "${CACHE_DIR}" && sha256sum -c "${FILENAME}.sha256" 2>/dev/null) || echo "[alpine]   警告：sha256 校验跳过" >&2
    fi
else
    echo "[alpine]   缓存命中: ${TARBALL}"
fi

# ---------- 第二步：解压到 rootfs ----------
echo "[alpine] 2. 解压到 ${ROOTFS} ..."
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"
tar xzf "${TARBALL}" --numeric-owner --same-owner -C "${ROOTFS}" 2>/dev/null || \
    tar xzf "${TARBALL}" -C "${ROOTFS}"

[ -x "${ROOTFS}/bin/busybox" ] || { echo "rootfs 解压异常" >&2; exit 1; }

# ---------- 第三步：chroot ----------
echo "[alpine] 3. 进入 chroot ..."
trap 'chroot_exit "${ROOTFS}"' EXIT
chroot_enter "${ROOTFS}"

# ---------- 第三+步：拷贝安装框架 ----------
echo "[alpine] 3+. 拷贝安装框架到 rootfs ..."
cp -f "${REPO_ROOT}/lib/download-helpers.sh" "${ROOTFS}/download-helpers.sh"
cp -r "${REPO_ROOT}/infra" "${ROOTFS}/infra"
cp -f "${SCRIPT_DIR}/package.list" "${ROOTFS}/package.list"
cp -f "${SCRIPT_DIR}/service.sh" "${ROOTFS}/service.sh"

# ---------- 第四步：安装基础系统（alpine-base + openrc + 基础配置）----------
echo "[alpine] 4. 安装基础系统 ..."
chroot_run "${ROOTFS}" /bin/sh << CHROOTEOF
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 配置软件源
echo "${MIRROR}/latest-stable/main" > /etc/apk/repositories
echo "${MIRROR}/latest-stable/community" >> /etc/apk/repositories

# 安装 alpine-base 和 openrc
apk add --no-cache alpine-base openrc

# 串口控制台
echo 'ttyS2::respawn:/sbin/agetty -L 1500000 ttyS2 vt100' >> /etc/inittab
echo 'ttyS2' >> /etc/securetty 2>/dev/null || true

# Boot 级服务
rc-update add bootmisc boot
rc-update add syslog default
rc-update add crond default

# setup-alpine quick mode（最小化配置）
cat > /answer_file << 'EOL'
KEYMAPOPTS="us us"
TIMEZONEOPTS="-z CST-8"
APKREPOSOPTS="-r"
SSHDOPTS="-c none"
NTPOPTS="-c openntpd"
EOL
setup-alpine -q -f /answer_file 2>/dev/null || true
rm -f /answer_file
CHROOTEOF

# ---------- 第六步：执行 setup ----------
echo "[alpine] 6. 执行 setup（安装包 / 配置 / 服务）..."
cp -f "${SETUP_SCRIPT}" "${ROOTFS}/setup.sh"
chmod +x "${ROOTFS}/setup.sh"
chroot_run "${ROOTFS}" /usr/bin/env \
    DISTRO="${DISTRO}" \
    INFRA="${INFRA:-sing-box}" \
    ROOT_PASSWORD="${ROOT_PASSWORD}" \
    HOSTNAME_VAL="${HOSTNAME_VAL}" \
    MIRROR="${MIRROR}" \
    /bin/sh /setup.sh
rm -f "${ROOTFS}/setup.sh"
rm -f "${ROOTFS}/download-helpers.sh"
rm -f "${ROOTFS}/package.list"
rm -f "${ROOTFS}/service.sh"
rm -rf "${ROOTFS}/infra"

echo "[alpine] base rootfs 构建完成：${ROOTFS}"

# ---------- 可选：打包 ----------
if [[ "${PACK}" == "1" ]]; then
    chroot_exit "${ROOTFS}"
    trap '' EXIT
    OUTPUT="${OUTPUT:-${ROOTFS%/}-minimal.tar.xz}"
    OUTPUT="$(readlink -m "${OUTPUT}")"
    echo "[alpine] 7. 调用打包：lib/slim-rootfs.sh"
    "${REPO_ROOT}/lib/slim-rootfs.sh" "${ROOTFS}" "${OUTPUT}"
fi
