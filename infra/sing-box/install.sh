#
# infra/sing-box/install.sh —— sing-box 栈安装
#   被 lib/install-router-software.sh source 调用
#   定义 install_sing_box() 函数
#
# 可用变量：$DISTRO、$REPO、$ARCH
# 可用函数：_pkg_install、_gh_release、_gh_latest_tag
#
# 约定：定义 check_sing_box() 作为安装检测，供调度器跳过重复安装
#

check_sing_box() {
    [ -f /etc/sing-box/.install-done ]
}

install_sing_box() {
    echo "[sing-box] === 安装 sing-box 体系 ==="

    # ============================================================
    #  1. 系统包 —— 从 package.list 逐行安装
    #      包含：dnsmasq, nftables, tailscale 等
    #      注：Debian/Devuan 安装 tailscale 需要 non-free 组件
    #         COMPONENTS="main non-free" 或在 build.sh 的 mmdebstrap
    #         --components 中追加 non-free
    #
    #      package.list 支持 OS 过滤语法：
    #        [void] pkg       — 仅 Void 安装
    #        [void,alpine]    — 多个 OS
    #        无前缀            — 所有 OS 安装
    # ============================================================
    _pkg_list_="/infra/sing-box/package.list"
    if [ -f "${_pkg_list_}" ]; then
        echo "[sing-box] 从 package.list 安装系统包 ..."
        while read -r _pkg_; do
            # 跳过空行和注释行
            case "${_pkg_}" in
                ''|'#'*) continue ;;
            esac
            # 处理 OS 过滤语法：[os] package
            case "${_pkg_}" in
                '['*)
                    _os_filter_="${_pkg_%%]*}"
                    _os_filter_="${_os_filter_#[}"
                    _pkg_="${_pkg_#*\] }"
                    # 检查当前 DISTRO 是否在过滤列表中
                    case ",${_os_filter_}," in
                        *",${DISTRO},"*) ;;
                        *) continue ;;
                    esac
                    ;;
            esac
            echo "[sing-box]   安装: ${_pkg_}"
            _pkg_install "${_pkg_}"
        done < "${_pkg_list_}"
    else
        echo "[sing-box] 警告: ${_pkg_list_} 不存在，跳过系统包安装" >&2
    fi

    # ============================================================
    #  2. sing-box —— GitHub Release tar.gz
    # ============================================================
    echo "[sing-box] 安装 sing-box ..."
    _ver="${SING_BOX_VERSION:-latest}"
    if [ "${_ver}" = "latest" ]; then
        _tag="$(_gh_latest_tag sagernet/sing-box)"
        _ver="$(echo "${_tag}" | sed 's/^v//')"
        echo "[sing-box]   latest tag: ${_tag}, version: ${_ver}"
    else
        echo "[sing-box]   指定版本: ${_ver}"
    fi
    _gh_release \
        "https://github.com/sagernet/sing-box/releases/download/v${_ver}/sing-box-${_ver}-linux-arm64.tar.gz" \
        sing-box

    # 验证 sing-box 可执行
    if ! /usr/local/bin/sing-box version >/dev/null 2>&1; then
        echo "[sing-box] 错误: sing-box 安装失败" >&2
        return 1
    fi
    echo "[sing-box]   sing-box $(/usr/local/bin/sing-box version | head -1)"

    # ============================================================
    #  3. cloudflared —— GitHub Release 直接二进制
    # ============================================================
    echo "[sing-box] 安装 cloudflared ..."
    _gh_release \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" \
        cloudflared

    if ! /usr/local/bin/cloudflared version >/dev/null 2>&1; then
        echo "[sing-box] 警告: cloudflared 验证失败" >&2
    else
        echo "[sing-box]   cloudflared $(/usr/local/bin/cloudflared version | head -1)"
    fi

    # ============================================================
    #  4. 出厂默认配置 —— 从 config/ 部署所有配置文件
    #      config/ 目录结构与 /etc/ 一致，递归复制即可
    #      根据 DISTRO 自动选择对应 init 系统的服务单元文件
    # ============================================================
    echo "[sing-box] 部署出厂默认配置 ..."
    _cfg_src_="/infra/sing-box/config"

    # 递归复制全部配置到 /etc/（保持目录结构）
    cp -r "${_cfg_src_}/"* /etc/

    # 清理文档文件和示例文件（留在仓库中，不进 rootfs）
    find /etc \( -name '*.md' -o -name '*.example' \) -exec rm -f {} + 2>/dev/null || true

    # 根据 DISTRO 部署对应的 init 服务单元
    case "${DISTRO}" in
        alpine)
            # init.d/ 已是 OpenRC 脚本，直接使用
            echo "[sing-box]   保持 OpenRC init 脚本：/etc/init.d/"
            ;;
        void)
            # 移除 OpenRC 脚本，部署 runit 服务目录
            rm -f /etc/init.d/sing-box /etc/init.d/cloudflared
            for _sv_dir_ in "${_cfg_src_}/sv/"*/; do
                [ -d "${_sv_dir_}" ] && cp -r "${_sv_dir_}" /etc/sv/
            done
            chmod +x /etc/sv/sing-box/run /etc/sv/cloudflared/run 2>/dev/null || true
            echo "[sing-box]   部署 runit 服务：/etc/sv/"
            ;;
        devuan)
            # 用 sysvinit 脚本覆盖 OpenRC 脚本
            rm -f /etc/init.d/sing-box /etc/init.d/cloudflared
            cp -f "${_cfg_src_}/init.d.sysvinit/"* /etc/init.d/ 2>/dev/null || true
            chmod +x /etc/init.d/sing-box /etc/init.d/cloudflared 2>/dev/null || true
            echo "[sing-box]   部署 sysvinit 脚本：/etc/init.d/"
            ;;
        debian)
            # 移除 OpenRC 脚本，部署 systemd unit
            rm -f /etc/init.d/sing-box /etc/init.d/cloudflared
            cp -f "${_cfg_src_}/systemd/"* /etc/systemd/system/ 2>/dev/null || true
            echo "[sing-box]   部署 systemd unit：/etc/systemd/system/"
            ;;
    esac

    # ============================================================
    #  5. 标记安装完成
    # ============================================================
    touch /etc/sing-box/.install-done
    echo "[sing-box] === sing-box 体系安装完成 ==="
}
