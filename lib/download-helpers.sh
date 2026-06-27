#
# lib/download-helpers.sh —— 下载安装助手
#   被各 OS setup.sh source 使用
#
# 提供函数：
#   _gh_release <url> <binary_name>     —— GitHub Release 下载
#   _gh_latest_tag <owner/repo>         —— 获取最新 release tag
#   dl_sing_box [version]               —— 安装 sing-box 到 /usr/local/bin/
#                                          version 默认 latest，可固定如 "1.10.0"
#   dl_tailscale                        —— 安装 tailscale 到 /usr/local/bin/
#   dl_cloudflared                      —— 安装 cloudflared 到 /usr/local/bin/
#

# ============================================================
#  GitHub Release 下载助手
# ============================================================
# _gh_release <url> <binary_name>
#   下载 <url> 指向的 asset 到 /usr/local/bin/<binary_name>
#   若 url 以 .tar.gz/.tgz 结尾则自动解压并查找二进制
#   内置 3 次重试 + 指数退避
_gh_release() {
    _url_="$1"
    _bin_="$2"
    _tmpdir_="/tmp/gh-$$-${_bin_}"
    _asset_="$(basename "${_url_}")"
    mkdir -p "${_tmpdir_}"

    echo "[dl] 下载 ${_bin_} ..."

    # 3 次重试 + 指数退避
    _retry_=3
    while [ "${_retry_}" -gt 0 ]; do
        if curl -fsSL "${_url_}" -o "${_tmpdir_}/${_asset_}" 2>/dev/null; then
            break
        fi
        _retry_=$((_retry_ - 1))
        [ "${_retry_}" -gt 0 ] && sleep "$(( (3 - _retry_) * 2 ))"
    done
    if [ "${_retry_}" -eq 0 ]; then
        echo "[dl] 下载 ${_bin_} 失败" >&2
        rm -rf "${_tmpdir_}"
        return 1
    fi

    case "${_asset_}" in
        *.tar.gz|*.tgz)
            tar xzf "${_tmpdir_}/${_asset_}" -C "${_tmpdir_}"
            if [ -f "${_tmpdir_}/${_bin_}" ]; then
                cp -f "${_tmpdir_}/${_bin_}" "/usr/local/bin/${_bin_}"
            else
                find "${_tmpdir_}" -type f -name "${_bin_}" -exec cp -f {} "/usr/local/bin/${_bin_}" \; 2>/dev/null || true
            fi
            ;;
        *)
            cp -f "${_tmpdir_}/${_asset_}" "/usr/local/bin/${_bin_}"
            ;;
    esac

    chmod +x "/usr/local/bin/${_bin_}"
    rm -rf "${_tmpdir_}"
    echo "[dl] ${_bin_} 安装完成 ($(command -v "${_bin_}" 2>/dev/null || echo '/usr/local/bin/...'))"
}

# ============================================================
#  GitHub API —— 获取最新 release tag
# ============================================================
# _gh_latest_tag <owner/repo>
#   输出该仓库最新 release 的 tag_name（如 v1.10.0）
_gh_latest_tag() {
    _repo_="$1"
    curl -fsSL "https://api.github.com/repos/${_repo_}/releases/latest" | \
        grep '"tag_name"' | head -1 | \
        sed 's/.*"tag_name": *"\(.*\)".*/\1/'
}

# ============================================================
#  sing-box —— GitHub Release tar.gz
# ============================================================
# dl_sing_box [version]
#   version 可选，省略则下载 latest
#   指定版本如 "1.10.0" 则下载固定版本
dl_sing_box() {
    _ver_="${1:-latest}"
    if [ "${_ver_}" = "latest" ]; then
        _tag_="$(_gh_latest_tag sagernet/sing-box)"
        _ver_="$(echo "${_tag_}" | sed 's/^v//')"
        echo "[dl] sing-box latest tag: ${_tag_}, version: ${_ver_}"
    else
        echo "[dl] sing-box 指定版本: ${_ver_}"
    fi
    _gh_release \
        "https://github.com/sagernet/sing-box/releases/download/v${_ver_}/sing-box-${_ver_}-linux-arm64.tar.gz" \
        sing-box

    if ! /usr/local/bin/sing-box version >/dev/null 2>&1; then
        echo "[dl] 错误: sing-box 安装失败" >&2
        return 1
    fi
    echo "[dl] sing-box $(/usr/local/bin/sing-box version | head -1)"
}

# ============================================================
#  tailscale —— 静态二进制（官方 arm64 tar.gz）
# ============================================================
dl_tailscale() {
    echo "[dl] 从 tailscale.com 下载静态二进制 ..."
    _url_="https://pkgs.tailscale.com/stable/tailscale_latest_arm64.tgz"
    _tmpdir_="/tmp/ts-$$"
    mkdir -p "${_tmpdir_}"
    if curl -fsSL "${_url_}" -o "${_tmpdir_}/tailscale.tgz"; then
        tar xzf "${_tmpdir_}/tailscale.tgz" -C "${_tmpdir_}"
        _ts_dir_="$(find "${_tmpdir_}" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"
        if [ -n "${_ts_dir_}" ]; then
            cp -f "${_ts_dir_}/tailscale" /usr/local/bin/
            cp -f "${_ts_dir_}/tailscaled" /usr/local/bin/
            chmod +x /usr/local/bin/tailscale /usr/local/bin/tailscaled
            echo "[dl] tailscale $(tailscale version 2>/dev/null | head -1)"
        else
            echo "[dl] 警告: 解压后未找到 tailscale 二进制" >&2
        fi
    else
        echo "[dl] 警告: tailscale 下载失败" >&2
    fi
    rm -rf "${_tmpdir_}"
}

# ============================================================
#  cloudflared —— GitHub Release 直接二进制
# ============================================================
dl_cloudflared() {
    echo "[dl] 安装 cloudflared ..."
    _gh_release \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" \
        cloudflared

    if ! /usr/local/bin/cloudflared version >/dev/null 2>&1; then
        echo "[dl] 警告: cloudflared 验证失败" >&2
    else
        echo "[dl] cloudflared $(/usr/local/bin/cloudflared version | head -1)"
    fi
}
