#!/bin/sh
# tools/render.sh
# 在 build-time (router-images CI) 和 runtime (路由器本机) 共用的渲染主流程
#
# 用法:
#   ./tools/render.sh \
#       --site <workspace-location> \
#       --secrets <router-config-dir> \
#       --os <alpine|debian> \
#       --output <dir> \
#       [--mode build|runtime]
#
# 工作流程:
#   1. 解析 site 为 workspace + location
#   2. 拼接三层 TOML 为单一 context.toml
#   3. 调用 tera 渲染 templates/ 下所有非下划线开头的 .tera 文件
#   4. 渲染 os/<os>/templates/ 下的 OS 特定模板
#
# 退出码:
#   0  成功
#   1  参数/环境错误
#   2  渲染失败
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BASE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/common.sh"

# ---- 参数解析 ----
SITE=""
SECRETS_DIR=""
OS=""
OUTPUT_DIR=""
MODE="runtime"

usage() {
    cat <<EOF >&2
Usage: render.sh
         --site    <workspace-location>   e.g. home-beijing
         --secrets <path>                 router-config repo path
         --os      <alpine|debian>
         --output  <path>                 output directory
         [--mode   build|runtime]         default: runtime
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --site)    SITE=$2;        shift 2 ;;
        --secrets) SECRETS_DIR=$2; shift 2 ;;
        --os)      OS=$2;          shift 2 ;;
        --output)  OUTPUT_DIR=$2;  shift 2 ;;
        --mode)    MODE=$2;        shift 2 ;;
        -h|--help) usage ;;
        *) log_error "unknown arg: $1"; usage ;;
    esac
done

[ -n "$SITE" ]        || { log_error "missing --site";    usage; }
[ -n "$SECRETS_DIR" ] || { log_error "missing --secrets"; usage; }
[ -n "$OS" ]          || { log_error "missing --os";      usage; }
[ -n "$OUTPUT_DIR" ]  || { log_error "missing --output";  usage; }

case "$OS" in
    alpine|debian) : ;;
    *) die "unsupported os: $OS (expected alpine|debian)" ;;
esac

case "$MODE" in
    build|runtime) : ;;
    *) die "unsupported mode: $MODE (expected build|runtime)" ;;
esac

# ---- 解析 site → workspace + location ----
# 约定: site 命名为 <workspace>-<location>，取首个 '-' 切分
WORKSPACE=${SITE%%-*}
LOCATION=${SITE#*-}
[ "$WORKSPACE" != "$SITE" ] || die "site name must be in 'workspace-location' format: $SITE"
[ -n "$LOCATION" ]          || die "site name missing location part: $SITE"

log_info "site=$SITE  workspace=$WORKSPACE  location=$LOCATION  os=$OS  mode=$MODE"

# ---- 定位输入文件 ----
WORKSPACE_FILE="$SECRETS_DIR/workspaces/${WORKSPACE}.toml"
LOCATION_FILE="$SECRETS_DIR/locations/${LOCATION}.toml"
SITE_FILE="$SECRETS_DIR/sites/${SITE}.toml"
require_file "$WORKSPACE_FILE" "$LOCATION_FILE" "$SITE_FILE"

# ---- 定位 tera 二进制 ----
# 查找顺序:
#   1. /opt/router/bin/tera     ← P2 install.sh 安装后的位置
#   2. <repo>/tools/bin/tera    ← fetch-tera.sh 默认位置 (开发用)
#   3. PATH 中的 tera           ← apk add / 手动安装
TERA_BIN=""
for candidate in \
    "/opt/router/bin/tera" \
    "$BASE_DIR/tools/bin/tera" \
    "$(command -v tera 2>/dev/null || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        TERA_BIN=$candidate
        break
    fi
done
[ -n "$TERA_BIN" ] || die "tera binary not found. Run tools/lib/fetch-tera.sh first."
log_info "using tera: $TERA_BIN"

# ---- 1. 拼接 context.toml ----
CONTEXT_FILE=$(mktemp -t router-base.ctx.XXXXXX).toml
trap 'rm -f "$CONTEXT_FILE"' EXIT INT TERM

"$SCRIPT_DIR/lib/concat-context.sh" \
    --workspace "$WORKSPACE_FILE" \
    --location  "$LOCATION_FILE" \
    --site      "$SITE_FILE" \
    --meta      "site=$SITE,workspace=$WORKSPACE,location=$LOCATION,os=$OS,mode=$MODE" \
    > "$CONTEXT_FILE"

log_debug "context assembled: $CONTEXT_FILE"
if [ "${DEBUG:-0}" = "1" ]; then
    log_debug "----- context.toml -----"
    cat "$CONTEXT_FILE" >&2
    log_debug "------------------------"
fi

# ---- 2. 准备输出目录 ----
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(realpath_p "$OUTPUT_DIR")

# ---- 3. 渲染函数 ----
TEMPLATES_DIR="$BASE_DIR/templates"

# render_one <tpl-abs-path> <tpl-root> <rel-path>
#   tpl-abs-path: 模板绝对路径
#   tpl-root:     模板根目录 (用于计算 include 搜索路径)
#   rel-path:     相对于 tpl-root 的路径，例如 etc/dnsmasq.conf.tera
render_one() {
    tpl=$1
    root=$2
    rel=$3
    out_rel=${rel%.tera}
    out_path="$OUTPUT_DIR/$out_rel"

    mkdir -p "$(dirname "$out_path")"
    log_info "render: $rel → $out_rel"

    # tera CLI:
    #   --template <FILE>       主模板
    #   --include               启用 include/extends/macros 扫描
    #   --include-path <DIR>    扫描目录
    #   --out <FILE>            输出文件
    #   <CONTEXT>               位置参数: TOML/JSON/YAML, 按扩展名自动识别
    if ! "$TERA_BIN" \
        --template "$tpl" \
        --include --include-path "$TEMPLATES_DIR" \
        --out "$out_path" \
        "$CONTEXT_FILE"
    then
        log_error "tera failed on: $tpl"
        exit 2
    fi
}

# ---- 4. 渲染 OS 无关模板 (templates/) ----
# 规则: 跳过以 _ 开头的文件和路径段 (_merged.tera / _macros/)
# 这些是辅助文件，被 include 使用，不直接渲染
if [ -d "$TEMPLATES_DIR" ]; then
    find "$TEMPLATES_DIR" -type f -name '*.tera' | while read -r tpl; do
        rel=${tpl#"$TEMPLATES_DIR/"}
        # 排除 _xxx 开头的文件或目录
        case "$rel" in
            _*|*/_*) continue ;;
        esac
        render_one "$tpl" "$TEMPLATES_DIR" "$rel"
    done
fi

# ---- 5. 渲染 OS 特定模板 (os/<os>/templates/) ----
OS_TEMPLATES="$BASE_DIR/os/$OS/templates"
if [ -d "$OS_TEMPLATES" ]; then
    find "$OS_TEMPLATES" -type f -name '*.tera' | while read -r tpl; do
        rel=${tpl#"$OS_TEMPLATES/"}
        case "$rel" in
            _*|*/_*) continue ;;
        esac

        # OS 模板输出到相同的 OUTPUT_DIR 下，路径与 os/<os>/templates/ 内相对路径一致
        # 这样 alpine/templates/etc/init.d/foo.tera → OUTPUT_DIR/etc/init.d/foo
        out_rel=${rel%.tera}
        out_path="$OUTPUT_DIR/$out_rel"
        mkdir -p "$(dirname "$out_path")"
        log_info "render[$OS]: $rel → $out_rel"

        if ! "$TERA_BIN" \
            --template "$tpl" \
            --include --include-path "$TEMPLATES_DIR" \
            --out "$out_path" \
            "$CONTEXT_FILE"
        then
            log_error "tera failed on: $tpl"
            exit 2
        fi
    done
fi

log_info "render complete: $OUTPUT_DIR"
