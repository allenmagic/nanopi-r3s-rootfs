#!/usr/bin/env bash
#
# distros/devuan/build.sh —— 构建 Devuan aarch64(arm64) 最小 rootfs 并执行 chroot 内 setup
# 用 mmdebstrap 构建 minbase（默认 sysvinit，不折腾换 init）
# 产物落在仓库内 build/devuan/（被 .gitignore 排除），仿 Armbian output/ 模式
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"     # → distros/devuan
REPO_ROOT="$(readlink -f "${SCRIPT_DIR}/../..")"  # → 仓库根
source "${REPO_ROOT}/lib/chroot-helper.sh"

# ---------- 可配置参数 ----------
DISTRO="devuan"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build}"               # build 总根
BUILD_BASE="${BUILD_BASE:-${BUILD_ROOT}/${DISTRO}}"          # build/devuan
ROOTFS="${ROOTFS:-${BUILD_BASE}/devuan-rootfs}"
CACHE_DIR="${CACHE_DIR:-${BUILD_BASE}/cache}"                # apt 缓存（复用免重下）
ARCH="${ARCH:-arm64}"                                        # Debian/Devuan 架构名
SUITE="${SUITE:-excalibur}"                                  # Devuan 版本（对应 Debian bookworm）
REPO="${REPO:-http://deb.devuan.org/merged}"                 # merged 源最省心
COMPONENTS="${COMPONENTS:-main}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"                       # CI Secret，未设默认 root
HOSTNAME_VAL="${HOSTNAME_VAL:-nanopi-r3s-devuan}"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
PACK="${PACK:-0}"                                            # 1=构建后顺带打包
# Devuan keyring：mmdebstrap 验证仓库签名所需
KEYRING="${KEYRING:-/usr/share/keyrings/devuan-archive-keyring.gpg}"

# ---------- 路径规范化（readlink -m：允许路径尚不存在） ----------
BUILD_ROOT="$(readlink -m "${BUILD_ROOT}")"
BUILD_BASE="$(readlink -m "${BUILD_BASE}")"
ROOTFS="$(readlink -m "${ROOTFS}")"
CACHE_DIR="$(readlink -m "${CACHE_DIR}")"
WORKDIR="$(dirname "${ROOTFS}")"

# ---------- 提权前：以普通用户创建 build 目录树（属主天然归调用者，无需 chown） ----------
if [ "${EUID}" -ne 0 ]; then
    mkdir -p "${BUILD_BASE}" "${CACHE_DIR}" "${WORKDIR}"
fi

# ---------- 权限：非 root 自动 sudo 重入 ----------
# mmdebstrap 支持非 root，但需 chroot 跑 setup，故统一走 root
[ "${EUID}" -eq 0 ] || exec sudo -E "$0" "$@"

[ -f "${SETUP_SCRIPT}" ] || { echo "缺少 ${SETUP_SCRIPT}" >&2; exit 1; }

# ---------- 依赖检查：mmdebstrap ----------
command -v mmdebstrap >/dev/null 2>&1 || {
    echo "错误：未找到 mmdebstrap。请先安装：sudo apt-get install -y mmdebstrap" >&2
    exit 1
}

# ---------- keyring：显式指定 → 宿主自带 → build/ 缓存 → 自动下载 ----------
KEYRING="${KEYRING:-}"
KEYRING_CACHE="${BUILD_BASE}/keyring/devuan-archive-keyring.gpg"

fetch_keyring() {
    # 移植自 CI：从 Devuan pool 下载 keyring .deb 并解包
    echo "[devuan] 下载 Devuan keyring → ${KEYRING_CACHE} ..."
    mkdir -p "$(dirname "${KEYRING_CACHE}")"
    local POOL="http://deb.devuan.org/devuan/pool/main/d/devuan-keyring/"
    local tmp; tmp="$(mktemp -d)"
    wget -qO "${tmp}/pool.html" "${POOL}" || {
        echo "错误：pool 目录拉取失败：${POOL}" >&2; rm -rf "${tmp}"; return 1; }
    local DEB_NAME
    DEB_NAME="$(grep -oE 'devuan-keyring_[0-9.]+_all\.deb' "${tmp}/pool.html" \
                | sort -uV | tail -n1)"
    [ -n "${DEB_NAME}" ] || {
        echo "错误：未从 pool 解析到 .deb 包名" >&2; rm -rf "${tmp}"; return 1; }
    echo "[devuan]   找到：${DEB_NAME}"
    wget -qO "${tmp}/k.deb" "${POOL}${DEB_NAME}" || { rm -rf "${tmp}"; return 1; }
    dpkg-deb -x "${tmp}/k.deb" "${tmp}/kr"
    local SRC
    SRC="$(find "${tmp}/kr" -path '*keyrings/devuan-archive-keyring.gpg' | head -n1)"
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
    # 2) 宿主系统已装（Devuan 宿主 / CI 之前装过）
    for c in /usr/share/keyrings/devuan-archive-keyring.gpg \
             /usr/share/keyrings/devuan-keyring.gpg; do
        [ -f "$c" ] && { KEYRING="$c"; return 0; }
    done
    # 3) build/ 缓存命中（之前下过，复用免重下）
    [ -s "${KEYRING_CACHE}" ] && { KEYRING="${KEYRING_CACHE}"; return 0; }
    # 4) 自动下载到 build/ 缓存
    fetch_keyring && { KEYRING="${KEYRING_CACHE}"; return 0; }
    return 1
}

if ! resolve_keyring; then
    echo "错误：无法获取 Devuan keyring。" >&2
    echo "  可手动指定：KEYRING=/path/to/devuan-archive-keyring.gpg" >&2
    exit 1
fi
# 校验存在且非空（沿用你 CI 的护栏）
[ -s "${KEYRING}" ] || { echo "错误：keyring 未就绪：${KEYRING}" >&2; exit 1; }
echo "[devuan] keyring 就绪：${KEYRING}"; ls -l "${KEYRING}" || true


# root 态：补建缓存目录
mkdir -p "${CACHE_DIR}"

# 护栏：构建工作区不能是共享系统目录
case "${WORKDIR}" in
    /|/tmp|/var/tmp|/home|/root|/usr|/etc)
        echo "错误：构建工作区不能是共享系统目录 (${WORKDIR})。" >&2
        echo "请用 BUILD_BASE / ROOTFS 指向专属目录（默认 ${BUILD_ROOT}）。" >&2
        exit 1 ;;
esac

# ---------- 第二步前：跨架构能力预检（加强版：查 enabled + F flag） ----------
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
echo "[devuan] 跨架构预检通过（宿主 ${HOST_ARCH}）"

# ---------- 第二步：用 mmdebstrap 构建 minbase（≈ Void base-minimal，默认 sysvinit） ----------
echo "[devuan] 2. 用 mmdebstrap 构建 minbase → ${ROOTFS} ..."
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

mmdebstrap \
    --arch="${ARCH}" \
    --variant=minbase \
    --components="${COMPONENTS}" \
    --keyring="${KEYRING}" \
    --include=ca-certificates,devuan-keyring \
    "${SUITE}" \
    "${ROOTFS}" \
    "${REPO}"

[ -x "${ROOTFS}/bin/sh" ] || { echo "rootfs 构建异常：缺少 /bin/sh" >&2; exit 1; }

# ---------- 第三步：chroot（trap 确保卸载） ----------
echo "[devuan] 3. 进入 chroot ..."
trap 'chroot_exit "${ROOTFS}"' EXIT
chroot_enter "${ROOTFS}"

# ---------- 第四+五步：执行 setup ----------
echo "[devuan] 4+5. 执行 setup（装工具 / 配置）..."
cp -f "${SETUP_SCRIPT}" "${ROOTFS}/setup.sh"
chmod +x "${ROOTFS}/setup.sh"
chroot_run "${ROOTFS}" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    ROOT_PASSWORD="${ROOT_PASSWORD}" \
    HOSTNAME_VAL="${HOSTNAME_VAL}" \
    SUITE="${SUITE}" \
    REPO="${REPO}" \
    COMPONENTS="${COMPONENTS}" \
    /bin/sh /setup.sh
rm -f "${ROOTFS}/setup.sh"

echo "[devuan] base rootfs 构建完成：${ROOTFS}"

# ---------- 可选：打包（PACK=1） ----------
if [[ "${PACK}" == "1" ]]; then
    chroot_exit "${ROOTFS}"          # 先卸载，避免打进挂载内容
    trap '' EXIT                     # 清 trap 防重复卸载
    OUTPUT="${OUTPUT:-${ROOTFS%/}-minimal.tar.xz}"
    OUTPUT="$(readlink -m "${OUTPUT}")"
    echo "[devuan] 6. 调用打包：lib/slim-rootfs.sh"
    "${REPO_ROOT}/lib/slim-rootfs.sh" "${ROOTFS}" "${OUTPUT}"
fi
