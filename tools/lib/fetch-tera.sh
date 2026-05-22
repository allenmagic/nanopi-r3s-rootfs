#!/bin/sh
# tools/lib/fetch-tera.sh
# 根据 versions.toml + 当前平台，下载 tera 二进制到指定目录
#
# 用法:
#   ./tools/lib/fetch-tera.sh [--output <dir>] [--target <triple>] [--force]
#
# 默认行为:
#   --output: <repo>/tools/bin
#   --target: 根据当前系统自动检测 (gnu/musl 由 /etc/alpine-release 区分)
#   --force:  即使已存在也强制重新下载
#
# 退出码:
#   0  成功 (含已存在跳过)
#   1  参数/环境错误
#   2  下载或解压失败
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BASE_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
. "$SCRIPT_DIR/common.sh"

# ---- 参数解析 ----
OUTPUT_DIR=""
TARGET=""
FORCE=0

usage() {
    cat <<EOF >&2
Usage: fetch-tera.sh [--output <dir>] [--target <triple>] [--force]

Options:
  --output <dir>     install destination (default: <repo>/tools/bin)
  --target <triple>  rust target triple, e.g. aarch64-unknown-linux-musl
                     (default: auto-detect from current system)
  --force            re-download even if binary already exists
  -h | --help        show this help

Supported targets (per tera-cli v0.5.0 upstream release):
  aarch64-unknown-linux-gnu
  aarch64-unknown-linux-musl
  x86_64-unknown-linux-gnu
  x86_64-unknown-linux-musl
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT_DIR=$2; shift 2 ;;
        --target) TARGET=$2;     shift 2 ;;
        --force)  FORCE=1;       shift ;;
        -h|--help) usage ;;
        *) log_error "unknown arg: $1"; usage ;;
    esac
done

# ---- 默认输出目录 ----
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="$BASE_DIR/tools/bin"

# ---- 自动检测 target (内联实现，避免函数返回值问题) ----
if [ -z "$TARGET" ]; then
    _arch=$(uname -m)
    case "$_arch" in
        aarch64|arm64) _arch=aarch64 ;;
        x86_64|amd64)  _arch=x86_64 ;;
        *) die "unsupported arch: $_arch" ;;
    esac

    # Alpine = musl，其他 Linux 视为 gnu
    if [ -f /etc/alpine-release ]; then
        _libc=musl
    else
        _libc=gnu
    fi

    TARGET="${_arch}-unknown-linux-${_libc}"
fi

# ---- 读 versions.toml ----
VERSIONS_FILE="$BASE_DIR/tools/versions.toml"
require_file "$VERSIONS_FILE"

# 极简 TOML 读取: 仅支持 [section] / key = "value" 形式
toml_get() {
    file=$1; section=$2; key=$3
    awk -v sec="[$section]" -v k="$key" '
        $0 == sec    { in_sec=1; next }
        /^\[/        { in_sec=0 }
        in_sec && $1 == k {
            sub(/^[^=]*=[[:space:]]*/, "")     # 去掉 "key ="
            sub(/[[:space:]]*#.*$/, "")        # 去掉行尾注释
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")   # 去首尾空白
            gsub(/^"|"$/, "")                  # 去引号
            print
            exit
        }
    ' "$file"
}

VERSION=$(toml_get "$VERSIONS_FILE" tera version)
REPO=$(toml_get    "$VERSIONS_FILE" tera repo)
ASSET_TEMPLATE=$(toml_get "$VERSIONS_FILE" tera asset_template)

[ -n "$VERSION" ]        || die "versions.toml: missing [tera].version"
[ -n "$REPO" ]           || die "versions.toml: missing [tera].repo"
[ -n "$ASSET_TEMPLATE" ] || die "versions.toml: missing [tera].asset_template"

# ---- 拼出资产名和 URL ----
ASSET=$(echo "$ASSET_TEMPLATE" | sed "s|{target}|$TARGET|g")
URL="https://github.com/$REPO/releases/download/v$VERSION/$ASSET"
OUT_BIN="$OUTPUT_DIR/tera"

log_info "tera target  : $TARGET"
log_info "tera version : v$VERSION"
log_info "asset URL    : $URL"
log_info "install to   : $OUT_BIN"

# ---- 已存在且版本一致则跳过 ----
if [ -x "$OUT_BIN" ] && [ "$FORCE" -ne 1 ]; then
    existing_ver=$("$OUT_BIN" --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
    if [ "$existing_ver" = "$VERSION" ] || [ "$existing_ver" = "v$VERSION" ]; then
        log_info "tera v$VERSION already installed, skipping (use --force to override)"
        exit 0
    else
        log_warn "found existing tera ($existing_ver), will replace with v$VERSION"
    fi
fi

# ---- 检查依赖 ----
require_cmd curl tar

# ---- 下载 + 解压 ----
mkdir -p "$OUTPUT_DIR"
TMPDIR=$(mktemp -d -t fetch-tera.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

log_info "downloading..."
if ! curl -fsSL --retry 3 --retry-delay 2 -o "$TMPDIR/$ASSET" "$URL"; then
    log_error "download failed: $URL"
    exit 2
fi

log_info "extracting..."
if ! tar -xzf "$TMPDIR/$ASSET" -C "$TMPDIR"; then
    log_error "extract failed: $TMPDIR/$ASSET"
    exit 2
fi

# ---- 定位解压出来的二进制 ----
# upstream tarball 布局可能是: tera (顶层) 或 <subdir>/tera
EXTRACTED=$(find "$TMPDIR" -type f -name 'tera' ! -name '*.tar*' | head -n 1)
[ -n "$EXTRACTED" ] || die "tera binary not found in extracted archive"

# ---- 安装 ----
install -m 0755 "$EXTRACTED" "$OUT_BIN" 2>/dev/null || {
    cp "$EXTRACTED" "$OUT_BIN"
    chmod 0755 "$OUT_BIN"
}

# ---- 校验能跑 ----
if ! "$OUT_BIN" --version >/dev/null 2>&1; then
    log_error "installed binary failed to execute: $OUT_BIN"
    exit 2
fi

INSTALLED_VER=$("$OUT_BIN" --version 2>&1 | head -n 1)
log_info "installed: $INSTALLED_VER"
log_info "done."
