#!/usr/bin/env bash
#
# distros/void/build.sh —— 构建 Void aarch64 最小 rootfs 并执行 chroot 内 setup
# 产物落在仓库内 build/（被 .gitignore 排除），仿 Armbian output/ 模式
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"     # → distros/void
REPO_ROOT="$(readlink -f "${SCRIPT_DIR}/../..")"  # → 仓库根
source "${REPO_ROOT}/lib/chroot-helper.sh"

# ---------- 可配置参数 ----------
DISTRO="void"
BUILD_BASE="${BUILD_BASE:-${REPO_ROOT}/build/${DISTRO}}"     # 仓库内 build/（git 忽略）
ROOTFS="${ROOTFS:-${BUILD_BASE}/void-rootfs}"
CACHE_DIR="${CACHE_DIR:-${BUILD_BASE}/cache}"      # 下载缓存（复用免重下）
ARCH="${ARCH:-aarch64}"

# ---------- 镜像源解析：REPO 和 XBPS_STATIC_URL ----------
# 镜像别名映射，别名 → mirror base URL。Void 镜像遵循同一结构：
#   ${base}/current/${ARCH}              — 包仓库
#   ${base}/static/xbps-static-...       — xbps-static 工具
declare -A MIRRORS
MIRRORS["default"]="https://repo-default.voidlinux.org"
MIRRORS["tuna"]="https://mirrors.tuna.tsinghua.edu.cn/voidlinux"
MIRRORS["tsinghua"]="https://mirrors.tuna.tsinghua.edu.cn/voidlinux"
# ↑ 添加新镜像时在这里加一条

# REPO 支持三种形式：
#   1. 不传 → 默认官方源
#   2. 传别名（如 "tuna"）→ 从 MIRRORS 查找
#   3. 传完整 URL（含 ://）→ 直接使用
_REPO_IN="${REPO:-default}"
if [[ "${_REPO_IN}" =~ ^[a-z]+:// ]]; then
    REPO="${_REPO_IN}"
    _MIRROR_BASE="${_REPO_IN}"
else
    _MIRROR_BASE="${MIRRORS[${_REPO_IN}]:-${MIRRORS[default]}}"
    REPO="${_MIRROR_BASE}/current/${ARCH}"
fi
# XBPS_STATIC_URL 从 mirror base 推导，也可单独指定覆盖
XBPS_STATIC_URL="${XBPS_STATIC_URL:-${_MIRROR_BASE%/current/*}/static/xbps-static-latest.aarch64-musl.tar.xz}"
unset _REPO_IN _MIRROR_BASE
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"             # CI Secret，未设默认 root
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-void}"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
PACK="${PACK:-0}"                                  # 1=构建后顺带打包


[ -f "${SETUP_SCRIPT}" ] || { echo "缺少 ${SETUP_SCRIPT}" >&2; exit 1; }

# ---------- 路径准备（readlink -m：允许路径尚不存在） ----------
ROOTFS="$(readlink -m "${ROOTFS}")"
WORKDIR="$(dirname "${ROOTFS}")"
XBPS_DIR="${WORKDIR}/xbps-static"
CACHE_DIR="$(readlink -m "${CACHE_DIR}")"
mkdir -p "${WORKDIR}" "${XBPS_DIR}" "${CACHE_DIR}"

# ---------- 权限：非 root 自动 sudo 重入 ----------
[ "${EUID}" -eq 0 ] || exec sudo -E "$0" "$@"

# 护栏：构建工作区不能是共享系统目录
case "${WORKDIR}" in
    /|/tmp|/var/tmp|/home|/root|/usr|/etc)
        echo "错误：构建工作区不能是共享系统目录 (${WORKDIR})。" >&2
        echo "请用 BUILD_BASE / ROOTFS 指向专属目录（默认 ${REPO_ROOT}/build）。" >&2
        exit 1 ;;
esac

# ---------- 第一步：下载并解压 xbps-static（缓存复用，隔离解压） ----------
echo "[void] 1. 下载 xbps-static ..."
XBPS_TARBALL="${CACHE_DIR}/xbps-static.tar.xz"
[ -f "${XBPS_TARBALL}" ] || wget -qO "${XBPS_TARBALL}" "${XBPS_STATIC_URL}"
echo "[void]    解压到 ${XBPS_DIR} ..."
tar xf "${XBPS_TARBALL}" -C "${XBPS_DIR}" --no-overwrite-dir
XBPS_INSTALL="${XBPS_DIR}/usr/bin/xbps-install"
[ -x "${XBPS_INSTALL}" ] || { echo "未找到 ${XBPS_INSTALL}" >&2; exit 1; }

# ---------- 第二步：构建 base-minimal ----------
echo "[void] 2. 构建 base-minimal → ${ROOTFS} ..."
mkdir -p "${ROOTFS}/var/db/xbps/keys"
# 预置 Void 官方公钥，避免首次导入交互
cp -a "${XBPS_DIR}/var/db/xbps/keys/." "${ROOTFS}/var/db/xbps/keys/" 2>/dev/null || true

env XBPS_ARCH="${ARCH}" "${XBPS_INSTALL}" \
    --yes -S -r "${ROOTFS}" -R "${REPO}" base-minimal


# ---------- 第三步前：跨架构能力预检 ----------
HOST_ARCH="$(uname -m)"
if [ "${HOST_ARCH}" != "aarch64" ] && [ "${HOST_ARCH}" != "arm64" ]; then
    # 非 aarch64 宿主：必须有 binfmt+qemu 才能 chroot 进 aarch64 rootfs
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo "错误：宿主架构为 ${HOST_ARCH}，但未注册 aarch64 的 binfmt/qemu。" >&2
        echo "chroot 进 aarch64 rootfs 将失败。请先执行：" >&2
        echo "  sudo apt-get install -y qemu-user-static binfmt-support" >&2
        echo "  docker run --rm --privileged tonistiigi/binfmt --install arm64" >&2
        echo "或在原生 aarch64 环境（如 GitHub ubuntu-24.04-arm runner）构建。" >&2
        exit 1
    fi
fi
echo "[void] 跨架构预检通过（宿主 ${HOST_ARCH}）"


# ---------- 第三步：chroot（trap 确保卸载） ----------
echo "[void] 3. 进入 chroot ..."
trap 'chroot_exit "${ROOTFS}"' EXIT
chroot_enter "${ROOTFS}"

# ---------- 第三+步：拷贝安装框架到 rootfs ----------
echo "[void] 3+. 拷贝安装框架到 rootfs ..."
cp -f "${REPO_ROOT}/lib/download-helpers.sh" "${ROOTFS}/download-helpers.sh"
cp -r "${REPO_ROOT}/infra" "${ROOTFS}/infra"
	mkdir -p "${ROOTFS}/opt/installer/tmp"
	[ -n "${SSH_PRIVATE_KEY:-}" ]   && printf '%s' "${SSH_PRIVATE_KEY}"   > "${ROOTFS}/opt/installer/tmp/ssh_private_key"
	[ -n "${SSH_PUBLIC_KEY:-}" ]    && printf '%s' "${SSH_PUBLIC_KEY}"    > "${ROOTFS}/opt/installer/tmp/ssh_public_key"
	[ -n "${SSH_KNOWN_HOSTS:-}" ]   && printf '%s' "${SSH_KNOWN_HOSTS}"   > "${ROOTFS}/opt/installer/tmp/ssh_known_hosts"
	[ -n "${TAILSCALE_AUTH_KEY:-}" ] && printf '%s' "${TAILSCALE_AUTH_KEY}" > "${ROOTFS}/opt/installer/tmp/tailscale_authkey"
	[ -n "${HEADSCALE_AUTH_KEY:-}" ] && printf '%s' "${HEADSCALE_AUTH_KEY}" > "${ROOTFS}/opt/installer/tmp/headscale_authkey"
	cp -f "${REPO_ROOT}/tools/inject-secrets.sh" "${ROOTFS}/inject-secrets.sh"
cp -f "${SCRIPT_DIR}/package.list" "${ROOTFS}/package.list"
cp -f "${SCRIPT_DIR}/service.sh" "${ROOTFS}/service.sh"

# ---------- 第四+五步：执行 setup ----------
echo "[void] 4+5. 执行 setup（装工具 / 配置）..."
cp -f "${SETUP_SCRIPT}" "${ROOTFS}/setup.sh"
chmod +x "${ROOTFS}/setup.sh"
chroot_run "${ROOTFS}" /usr/bin/env \
    DISTRO="${DISTRO}" \
    INFRA="${INFRA:-sing-box}" \
    ROOT_PASSWORD="${ROOT_PASSWORD}" \
    HOSTNAME_VAL="${HOSTNAME_VAL}" \
    REPO="${REPO}" \
    /bin/sh /setup.sh
rm -f "${ROOTFS}/setup.sh"
rm -f "${ROOTFS}/inject-secrets.sh"
rm -f "${ROOTFS}/download-helpers.sh"
rm -f "${ROOTFS}/package.list"
rm -f "${ROOTFS}/service.sh"
rm -rf "${ROOTFS}/infra"

echo "[void] base rootfs 构建完成：${ROOTFS}"

# ---------- 可选：打包（PACK=1） ----------
if [[ "${PACK}" == "1" ]]; then
    chroot_exit "${ROOTFS}"          # 先卸载，避免打进挂载内容
    trap '' EXIT                     # 清 trap 防重复卸载（EXIT 时忽略，因已手动卸载）
    OUTPUT="${OUTPUT:-${ROOTFS%/}-minimal.tar.xz}"
    OUTPUT="$(readlink -m "${OUTPUT}")"
    echo "[void] 6. 调用打包：lib/slim-rootfs.sh"
    "${REPO_ROOT}/lib/slim-rootfs.sh" "${ROOTFS}" "${OUTPUT}"
fi
