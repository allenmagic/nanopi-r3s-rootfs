#!/bin/sh
# tools/lib/common.sh
# 公共函数库，被其他脚本通过 . source 加载
# 要求: POSIX sh 兼容（不依赖 bash）

# ---- 颜色 (TTY 环境才启用) ----
if [ -t 2 ] && [ "${NO_COLOR:-}" = "" ]; then
    _C_RED=$(printf '\033[31m')
    _C_YEL=$(printf '\033[33m')
    _C_GRN=$(printf '\033[32m')
    _C_DIM=$(printf '\033[2m')
    _C_RST=$(printf '\033[0m')
else
    _C_RED=; _C_YEL=; _C_GRN=; _C_DIM=; _C_RST=
fi

# ---- 日志函数 ----
log_info()  { printf '%s[info]%s  %s\n' "$_C_GRN" "$_C_RST" "$*" >&2; }
log_warn()  { printf '%s[warn]%s  %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
log_error() { printf '%s[error]%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
log_debug() {
    [ "${DEBUG:-0}" = "1" ] || return 0
    printf '%s[debug]%s %s\n' "$_C_DIM" "$_C_RST" "$*" >&2
}

# ---- 致命错误 ----
die() {
    log_error "$*"
    exit 1
}

# ---- 检查命令是否存在 ----
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
    done
}

# ---- 路径解析 ----
realpath_p() {
    if command -v realpath >/dev/null 2>&1; then
        realpath "$1"
    elif readlink -f / >/dev/null 2>&1; then
        readlink -f "$1"
    else
        ( cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$1")" )
    fi
}

# ---- 校验文件存在 ----
require_file() {
    for f in "$@"; do
        [ -f "$f" ] || die "file not found: $f"
    done
}

# ---- 校验目录存在 ----
require_dir() {
    for d in "$@"; do
        [ -d "$d" ] || die "directory not found: $d"
    done
}

# ---- 检测当前系统 ----
# POSIX 兼容: 通过全局变量 DETECTED_TARGET 返回结果
# 不通过 stdout 返回，避免 $(detect_target) 在 dash 下子 shell 看不到函数定义的问题
#
# 用法:
#   detect_target
#   echo "$DETECTED_TARGET"
detect_target() {
    _arch=$(uname -m)
    case "$_arch" in
        aarch64|arm64) _arch=aarch64 ;;
        x86_64|amd64)  _arch=x86_64 ;;
        *) die "unsupported arch: $_arch" ;;
    esac

    if [ -f /etc/alpine-release ]; then
        _libc=musl
    else
        _libc=gnu
    fi

    DETECTED_TARGET="${_arch}-unknown-linux-${_libc}"
    export DETECTED_TARGET
}

# ---- 临时文件 ----
mktemp_safe() {
    mktemp -t "router-base.XXXXXX"
}
