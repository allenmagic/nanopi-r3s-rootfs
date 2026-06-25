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
BUILD_BASE="${BUILD_BASE:-${REPO_ROOT}/build}"     # 仓库内 build/（git 忽略）
ROOTFS="${ROOTFS:-${BUILD_BASE}/void-rootfs}"
CACHE_DIR="${CACHE_DIR:-${BUILD_BASE}/cache}"      # 下载缓存（复用免重下）
ARCH="${ARCH:-aarch64}"
REPO="${REPO:-https://repo-default.voidlinux.org/current/${ARCH}}"
XBPS_STATIC_URL="${XBPS_STATIC_URL:-https://repo-default.voidlinux.org/static/xbps-static-latest.aarch64-musl.tar.xz}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"             # CI Secret，未设默认 root
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-void}"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
PACK="${PACK:-0}"                                  # 1=构建后顺带打包

# ---------- 权限：非 root 自动 sudo 重入 ----------
[ "${EUID}" -eq 0 ] || exec sudo -E "$0" "$@"

[ -f "${SETUP_SCRIPT}" ] || { echo "缺少 ${SETUP_SCRIPT}" >&2; exit 1; }

# ---------- 路径准备（readlink -m：允许路径尚不存在） ----------
ROOTFS="$(readlink -m "${ROOTFS}")"
WORKDIR="$(dirname "${ROOTFS}")"
XBPS_DIR="${WORKDIR}/xbps-static"
CACHE_DIR="$(readlink -m "${CACHE_DIR}")"
mkdir -p "${WORKDIR}" "${XBPS_DIR}" "${CACHE_DIR}"

mkdir -p "${WORKDIR}" "${XBPS_DIR}" "${CACHE_DIR}"

# 把 build 顶层目录属主还给调用者（rootfs 内部仍须 root）
if [ -n "${SUDO_USER:-}" ]; then
    chown "${SUDO_USER}:${SUDO_USER}" "${BUILD_BASE}" "${CACHE_DIR}" 2>/dev/null || true
fi


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
mkdir -p "${ROOTFS}"
yes | env XBPS_ARCH="${ARCH}" "${XBPS_INSTALL}" \
    --yes -S -r "${ROOTFS}" -R "${REPO}" base-minimal

# ---------- 第三步：chroot（trap 确保卸载） ----------
echo "[void] 3. 进入 chroot ..."
trap 'chroot_exit "${ROOTFS}"' EXIT
chroot_enter "${ROOTFS}"

# ---------- 第四+五步：执行 setup ----------
echo "[void] 4+5. 执行 setup（装工具 / 配置）..."
cp -f "${SETUP_SCRIPT}" "${ROOTFS}/setup.sh"
chmod +x "${ROOTFS}/setup.sh"
chroot_run "${ROOTFS}" /usr/bin/env \
    ROOT_PASSWORD="${ROOT_PASSWORD}" \
    HOSTNAME_VAL="${HOSTNAME_VAL}" \
    REPO="${REPO}" \
    /bin/sh /setup.sh
rm -f "${ROOTFS}/setup.sh"

echo "[void] base rootfs 构建完成：${ROOTFS}"

# ---------- 可选：打包（PACK=1） ----------
if [[ "${PACK}" == "1" ]]; then
    chroot_exit "${ROOTFS}"          # 先卸载，避免打进挂载内容
    trap - EXIT                      # 清 trap 防重复卸载
    OUTPUT="${OUTPUT:-${ROOTFS%/}-minimal.tar.xz}"
    OUTPUT="$(readlink -m "${OUTPUT}")"
    echo "[void] 6. 调用打包：lib/slim-rootfs.sh"
    "${REPO_ROOT}/lib/slim-rootfs.sh" "${ROOTFS}" "${OUTPUT}"
fi
