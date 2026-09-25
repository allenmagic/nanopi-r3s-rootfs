#!/usr/bin/env bash
#
# local-build.sh —— 本地复刻 .github/workflows/build-rootfs.yml
#   只做编排：把环境变量对齐 CI 后调用 distros/<distro>/build.sh，不改动任何现有脚本。
#
# 用法：
#   ./local-build.sh [--distro gentoo] [--infra base] [--arch aarch64] [--mirror default]
#                    [--jobs N] [--cold] [--no-pack] [--debug]
#
# 需要 sudo 密码（build.sh 要在 chroot 里 emerge）。
# 密钥走 .env（被 .gitignore 忽略），没有则跳过注入，只影响 SSH key / tailscale / cloudflared。
#
# 与 CI 的区别：默认 KEEP_STAGE3=1 + binpkg 复用 + 显式多线程，第二次起只重跑 setup。
#   --cold  丢掉 stage3 与 binpkg，完全从零复刻 CI
#   --jobs  编译并发（默认 nproc；qemu 下若不稳可降到 8）
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
INVOKER_UID="$(id -u)"

DISTRO="gentoo"
INFRA="base"
ARCH="aarch64"
MIRROR="default"
PACK="1"
MAKE_JOBS="$(nproc 2>/dev/null || echo 4)"
PKGDIR="/packages"
KEEP_STAGE3="1"
BASH_OPTS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --distro) DISTRO="$2"; shift 2 ;;
        --infra)  INFRA="$2";  shift 2 ;;
        --arch)   ARCH="$2";   shift 2 ;;
        --mirror) MIRROR="$2"; shift 2 ;;
        --jobs)   MAKE_JOBS="$2"; shift 2 ;;
        --cold)   KEEP_STAGE3="0"; shift ;;
        --no-pack) PACK="0";   shift ;;
        --debug)  BASH_OPTS="-x"; shift ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

case "${DISTRO}" in
    void|devuan|debian|alpine|gentoo) ;;
    *) echo "无效 --distro: ${DISTRO}" >&2; exit 1 ;;
esac

BUILD_SH="${REPO_ROOT}/distros/${DISTRO}/build.sh"
OUT_DIR="${REPO_ROOT}/build/local-out"

say()  { printf '\033[32m[local]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[local]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[local]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 预检 ----------
[ -f "${BUILD_SH}" ] || die "找不到 ${BUILD_SH}"

_missing=""
for _t in xz wget curl tar sudo; do
    command -v "${_t}" >/dev/null 2>&1 || _missing="${_missing} ${_t}"
done
case "${DISTRO}" in
    gentoo)        _need="file openssl" ;;
    debian|devuan) _need="mmdebstrap" ;;
    *)             _need="openssl" ;;
esac
for _t in ${_need}; do
    command -v "${_t}" >/dev/null 2>&1 || _missing="${_missing} ${_t}"
done
[ -z "${_missing}" ] || die "缺少宿主工具:${_missing}"

# 跨架构：早于下载检查，免得白等半天
if [ "${ARCH}" = "aarch64" ] && [ "$(uname -m)" != "aarch64" ]; then
    grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null \
        || die "未启用 aarch64 binfmt（装 qemu-user-static 后 docker run --privileged tonistiigi/binfmt --install arm64）"
    say "跨架构构建（qemu），首次全量编译仍慢；之后走 binpkg 复用"
fi

_avail_g="$(df -Pk "${REPO_ROOT}" | awk 'NR==2 {print int($4/1048576)}')"
[ "${_avail_g}" -ge 15 ] || die "磁盘余量不足（${_avail_g}G < 15G）"

# gentoo 官方源可能只解析出 IPv6 而本机无出口；提前说，别等下载到一半才报错
if [ "${DISTRO}" = "gentoo" ] && [ "${MIRROR}" = "default" ] && \
   ! curl -s -o /dev/null --max-time 8 "https://distfiles.gentoo.org/" 2>/dev/null; then
    warn "distfiles.gentoo.org 不可达 —— 换国内镜像重跑：./local-build.sh --mirror tuna"
fi

if [ -f "${REPO_ROOT}/.env" ]; then
    say "加载 ${REPO_ROOT}/.env"
else
    warn "无 .env：跳过密钥注入（SSH key / tailscale / cloudflared 不会进镜像）"
fi

# ---------- 与 CI 对齐的环境 ----------
export DISTRO INFRA ARCH PACK REPO="${MIRROR}"
export ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
export SSH_PRIVATE_KEY SSH_PUBLIC_KEY TAILSCALE_AUTH_KEY HEADSCALE_AUTH_KEY CLOUDFLARED_TOKEN
if [ "${DISTRO}" = "gentoo" ]; then
    export KEEP_STAGE3 MAKE_JOBS PKGDIR
else
    warn "KEEP_STAGE3/MAKE_JOBS/PKGDIR 目前只在 gentoo 的 build.sh 里实现，其余发行版走全量"
fi

say "distro=${DISTRO} infra=${INFRA} arch=${ARCH} mirror=${MIRROR} pack=${PACK}"
if [ "${KEEP_STAGE3}" = "1" ]; then
    say "增量模式：-j${MAKE_JOBS}，binpkg 目录 ${PKGDIR}（--cold 可关掉）"
fi
say "产物目录: ${OUT_DIR}"
mkdir -p "${OUT_DIR}"

# ---------- 构建（等价于 CI 的 sudo -E bash build.sh）----------
chmod +x "${BUILD_SH}"
sudo -E bash ${BASH_OPTS} "${BUILD_SH}" || die "构建失败"

# ---------- 定位产物（与 CI 的 Locate artifact 同逻辑）----------
_f="$(ls -1 "${REPO_ROOT}/build/${DISTRO}/${DISTRO}-rootfs-minimal.tar.xz" 2>/dev/null \
      || ls -1 "${REPO_ROOT}/build/${DISTRO}"/*-rootfs-minimal.tar.* 2>/dev/null \
      || ls -1 "${REPO_ROOT}/build/${DISTRO}"/*.tar.* 2>/dev/null | head -n1 || true)"

if [ -z "${_f}" ] || [ ! -e "${_f}" ]; then
    warn "未找到 tar 产物（--no-pack 属正常）；rootfs 目录：${REPO_ROOT}/build/${DISTRO}/${DISTRO}-rootfs"
    exit 0
fi

_out="${OUT_DIR}/${DISTRO}-${INFRA}-${ARCH}-rootfs.tar.${_f##*.}"
cp -f "${_f}" "${_out}"
( cd "${OUT_DIR}" && sha256sum "$(basename "${_out}")" > "$(basename "${_out}").sha256" )
# 构建跑在 root 下，产物交还给调用者
[ "${INVOKER_UID}" -eq 0 ] || chown -f "${INVOKER_UID}" "${_out}" "${_out}.sha256" 2>/dev/null || true

say "完成: ${_out} ($(du -h "${_out}" | cut -f1))"
say "接镜像: cd ../nanopi-r3s-img && sudo bash local-build.sh --skip-kernel --dist-os ${DISTRO} --rootfs-file ${_out}"
