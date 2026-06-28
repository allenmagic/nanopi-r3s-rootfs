#!/usr/bin/env bash
#
# distros/debian/build.sh —— 构建 Debian aarch64(arm64) 最小 rootfs 并执行 chroot 内 setup
# 用 mmdebstrap 构建 minbase（systemd 作为 init）
# 产物落在仓库内 build/debian/（被 .gitignore 排除）
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"     # → distros/debian
REPO_ROOT="$(readlink -f "${SCRIPT_DIR}/../..")"  # → 仓库根
source "${REPO_ROOT}/lib/chroot-helper.sh"

# ---------- 可配置参数 ----------
DISTRO="debian"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build}"               # build 总根
BUILD_BASE="${BUILD_BASE:-${BUILD_ROOT}/${DISTRO}}"          # build/debian
ROOTFS="${ROOTFS:-${BUILD_BASE}/debian-rootfs}"
CACHE_DIR="${CACHE_DIR:-${BUILD_BASE}/cache}"                # apt 缓存（复用免重下）
ARCH="${ARCH:-arm64}"                                        # Debian 架构名
SUITE="${SUITE:-stable}"                                 # Debian 最新稳定版
COMPONENTS="${COMPONENTS:-main}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"                       # CI Secret，未设默认 root
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-debian}"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
PACK="${PACK:-0}"                                            # 1=构建后顺带打包

# ---------- 镜像源解析：REPO ----------
# 镜像别名映射，别名 → mirror URL。Debian 镜像结构无 /merged 后缀。
declare -A MIRRORS
MIRRORS["default"]="http://deb.debian.org/debian"
MIRRORS["tuna"]="https://mirrors.tuna.tsinghua.edu.cn/debian"
MIRRORS["tsinghua"]="https://mirrors.tuna.tsinghua.edu.cn/debian"
# ↑ 添加新镜像时在这里加一条

# REPO 支持三种形式：
#   1. 不传 → 默认官方源
#   2. 传别名（如 "tuna"）→ 从 MIRRORS 查找
#   3. 传完整 URL（含 ://）→ 直接使用
_REPO_IN="${REPO:-default}"
if [[ "${_REPO_IN}" =~ ^[a-z]+:// ]]; then
    REPO="${_REPO_IN}"
else
    REPO="${MIRRORS[${_REPO_IN}]:-${MIRRORS[default]}}"
fi
unset _REPO_IN

# ---------- keyring ----------
# Debian archive keyring：从 mirror pool 自动下载，也可手动指定
KEYRING="${KEYRING:-}"
KEYRING_CACHE="${BUILD_BASE}/keyring/debian-archive-keyring.gpg"
# keyring 下载路径，从 REPO 推导
KEYRING_POOL="${KEYRING_POOL:-${REPO%/debian}/debian/pool/main/d/debian-archive-keyring/}"

fetch_keyring() {
    echo "[debian] 下载 Debian keyring → ${KEYRING_CACHE} ..."
    mkdir -p "$(dirname "${KEYRING_CACHE}")"
    local POOL="${KEYRING_POOL}"
    local tmp; tmp="$(mktemp -d)"
    wget -qO "${tmp}/pool.html" "${POOL}" || {
        echo "错误：pool 目录拉取失败：${POOL}" >&2; rm -rf "${tmp}"; return 1; }
    local DEB_NAME
    DEB_NAME="$(grep -oE 'debian-archive-keyring_[0-9.]+_all\.deb' "${tmp}/pool.html" \
                | sort -uV | tail -n1)"
    [ -n "${DEB_NAME}" ] || {
        echo "错误：未从 pool 解析到 .deb 包名" >&2; rm -rf "${tmp}"; return 1; }
    echo "[debian]   找到：${DEB_NAME}"
    wget -qO "${tmp}/k.deb" "${POOL}${DEB_NAME}" || { rm -rf "${tmp}"; return 1; }
    dpkg-deb -x "${tmp}/k.deb" "${tmp}/kr"
    local SRC
    SRC="$(find "${tmp}/kr" -path '*debian-archive-keyring.gpg' | head -n1)"
    [ -n "${SRC}" ] || {
        echo "错误：deb 内未找到 keyring" >&2; find "${tmp}/kr" -name '*.gpg' >&2
        rm -rf "${tmp}"; return 1; }
    cp "${SRC}" "${KEYRING_CACHE}"
    rm -rf "${tmp}"
    [ -s "${KEYRING_CACHE}" ]
}

resolve_keyring() {
    # 1) 用户显式指定
    [ -n "${KEYRING}" ] && [ -f "${KEYRING}" ] && return 0
    # 2) 宿主系统已装
    for c in /usr/share/keyrings/debian-archive-keyring.gpg \
             /usr/share/keyrings/debian-keyring.gpg; do
        [ -f "$c" ] && { KEYRING="$c"; return 0; }
    done
    # 3) build/ 缓存命中
    [ -s "${KEYRING_CACHE}" ] && { KEYRING="${KEYRING_CACHE}"; return 0; }
    # 4) 自动下载到 build/ 缓存
    fetch_keyring && { KEYRING="${KEYRING_CACHE}"; return 0; }
    return 1
}

if ! resolve_keyring; then
    echo "错误：无法获取 Debian keyring。" >&2
    echo "  可手动指定：KEYRING=/path/to/debian-archive-keyring.gpg" >&2
    exit 1
fi
[ -s "${KEYRING}" ] || { echo "错误：keyring 未就绪：${KEYRING}" >&2; exit 1; }
echo "[debian] keyring 就绪：${KEYRING}"; ls -l "${KEYRING}" || true

# ---------- 路径规范化（readlink -m：允许路径尚不存在） ----------
BUILD_ROOT="$(readlink -m "${BUILD_ROOT}")"
BUILD_BASE="$(readlink -m "${BUILD_BASE}")"
ROOTFS="$(readlink -m "${ROOTFS}")"
CACHE_DIR="$(readlink -m "${CACHE_DIR}")"
WORKDIR="$(dirname "${ROOTFS}")"

# ---------- 提权前：以普通用户创建 build 目录树 ----------
if [ "${EUID}" -ne 0 ]; then
    mkdir -p "${BUILD_BASE}" "${CACHE_DIR}" "${WORKDIR}"
fi

# ---------- 权限：非 root 自动 sudo 重入 ----------
[ "${EUID}" -eq 0 ] || exec sudo -E "$0" "$@"

[ -f "${SETUP_SCRIPT}" ] || { echo "缺少 ${SETUP_SCRIPT}" >&2; exit 1; }

# ---------- 依赖检查：mmdebstrap ----------
command -v mmdebstrap >/dev/null 2>&1 || {
    echo "错误：未找到 mmdebstrap。请先安装：sudo apt-get install -y mmdebstrap" >&2
    exit 1
}

# root 态：补建缓存目录
mkdir -p "${CACHE_DIR}"

# 护栏：构建工作区不能是共享系统目录
case "${WORKDIR}" in
    /|/tmp|/var/tmp|/home|/root|/usr|/etc)
        echo "错误：构建工作区不能是共享系统目录 (${WORKDIR})。" >&2
        echo "请用 BUILD_BASE / ROOTFS 指向专属目录（默认 ${BUILD_ROOT}）。" >&2
        exit 1 ;;
esac

# ---------- 第二步前：跨架构能力预检 ----------
HOST_ARCH="$(uname -m)"
if [ "${HOST_ARCH}" != "aarch64" ] && [ "${HOST_ARCH}" != "arm64" ]; then
    BINFMT=/proc/sys/fs/binfmt_misc/qemu-aarch64
    if [ ! -e "${BINFMT}" ] || ! grep -q '^enabled' "${BINFMT}" 2>/dev/null; then
        echo "错误：宿主架构为 ${HOST_ARCH}，但未启用 aarch64 的 binfmt/qemu。" >&2
        echo "构建 arm64 rootfs 将失败。请先执行：" >&2
        echo "  sudo apt-get install -y qemu-user-static binfmt-support" >&2
        echo "  docker run --rm --privileged tonistiigi/binfmt --install arm64" >&2
        echo "或在原生 aarch64 环境（如 GitHub ubuntu-24.04-arm runner）构建。" >&2
        exit 1
    fi
    if ! grep -q 'flags:.*F' "${BINFMT}" 2>/dev/null; then
        echo "警告：qemu-aarch64 未带 F flag，跨架构 chroot 可能找不到解释器。" >&2
        echo "建议用 tonistiigi/binfmt 重新注册：" >&2
        echo "  docker run --rm --privileged tonistiigi/binfmt --install arm64" >&2
    fi
fi
echo "[debian] 跨架构预检通过（宿主 ${HOST_ARCH}）"

# ---------- 第二步：用 mmdebstrap 构建 minbase（systemd 作为 init） ----------
echo "[debian] 2. 用 mmdebstrap 构建 minbase → ${ROOTFS} ..."
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

mmdebstrap \
    --arch="${ARCH}" \
    --variant=minbase \
    --components="${COMPONENTS}" \
    --keyring="${KEYRING}" \
    --include=ca-certificates,systemd-sysv \
    "${SUITE}" \
    "${ROOTFS}" \
    "${REPO}"

[ -x "${ROOTFS}/bin/sh" ] || { echo "rootfs 构建异常：缺少 /bin/sh" >&2; exit 1; }

# ---------- 第三步：chroot（trap 确保卸载） ----------
echo "[debian] 3. 进入 chroot ..."
trap 'chroot_exit "${ROOTFS}"' EXIT
chroot_enter "${ROOTFS}"

# ---------- 第三+步：拷贝安装框架到 rootfs ----------
echo "[debian] 3+. 拷贝安装框架到 rootfs ..."
cp -f "${REPO_ROOT}/lib/download-helpers.sh" "${ROOTFS}/download-helpers.sh"
cp -r "${REPO_ROOT}/infra" "${ROOTFS}/infra"
	# 从环境变量注入敏感配置（未设则保留占位符）
	[ -n "${TS_AUTH_KEY:-}" ]     && find "${ROOTFS}/infra" -name tailscaled.log.conf -exec sed -i "s|__TS_AUTH_KEY__|${TS_AUTH_KEY}|g" {} +
	[ -n "${TS_AUTH_KEY_PUB:-}" ] && find "${ROOTFS}/infra" -name tailscaled.log.conf -exec sed -i "s|__TS_AUTH_KEY_PUB__|${TS_AUTH_KEY_PUB}|g" {} +
cp -f "${SCRIPT_DIR}/package.list" "${ROOTFS}/package.list"
cp -f "${SCRIPT_DIR}/service.sh" "${ROOTFS}/service.sh"

# ---------- 第四+五步：执行 setup ----------
echo "[debian] 4+5. 执行 setup（装工具 / 配置）..."
cp -f "${SETUP_SCRIPT}" "${ROOTFS}/setup.sh"
chmod +x "${ROOTFS}/setup.sh"
chroot_run "${ROOTFS}" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    DISTRO="${DISTRO}" \
    INFRA="${INFRA:-sing-box}" \
    ROOT_PASSWORD="${ROOT_PASSWORD}" \
    HOSTNAME_VAL="${HOSTNAME_VAL}" \
    SUITE="${SUITE}" \
    REPO="${REPO}" \
    COMPONENTS="${COMPONENTS}" \
    /bin/sh /setup.sh
rm -f "${ROOTFS}/setup.sh"
rm -f "${ROOTFS}/download-helpers.sh"
rm -f "${ROOTFS}/package.list"
rm -f "${ROOTFS}/service.sh"
rm -rf "${ROOTFS}/infra"

echo "[debian] base rootfs 构建完成：${ROOTFS}"

# ---------- 可选：打包（PACK=1） ----------
if [[ "${PACK}" == "1" ]]; then
    chroot_exit "${ROOTFS}"          # 先卸载，避免打进挂载内容
    trap '' EXIT                     # 清 trap 防重复卸载
    OUTPUT="${OUTPUT:-${ROOTFS%/}-minimal.tar.xz}"
    OUTPUT="$(readlink -m "${OUTPUT}")"
    echo "[debian] 6. 调用打包：lib/slim-rootfs.sh"
    "${REPO_ROOT}/lib/slim-rootfs.sh" "${ROOTFS}" "${OUTPUT}"
fi
