#
# landscape/install.sh —— Landscape Router 安装
#   被 distros/<os>/setup.sh source（chroot 内）
#   定义 install_landscape()
#
# 目录布局（程序 / 状态 / 日志分树）：
#   /usr/local/bin/landscape-webserver     二进制
#   /usr/share/landscape-router/static/    前端资源（与二进制同版本，一起换）
#   /var/lib/landscape-router/             home：landscape_db.sqlite + landscape_init.toml
#   /var/log/landscape-router/             日志
#

LANDSCAPE_RELEASE="https://github.com/ThisSeanZhang/landscape/releases/latest/download"
LANDSCAPE_HOME="/var/lib/landscape-router"
LANDSCAPE_STATIC="/usr/share/landscape-router"
LANDSCAPE_LOG="/var/log/landscape-router"

install_landscape() {
    echo "[landscape] === 安装 Landscape Router ==="
    _ls_arch      || return 1
    _ls_dirs      || return 1
    _ls_binary    || return 1
    _ls_static    || return 1
    _ls_init_conf || return 1
    _ls_units     || return 1
    _ls_bpffs     || return 1
    echo "[landscape] 安装完成。"
}

# 上游按架构命名产物；只有 -static（musl 静态）能在 alpine 上跑
_ls_arch() {
    case "$(uname -m)" in
        aarch64|arm64) _LS_ARCH_="aarch64" ;;
        x86_64|amd64)  _LS_ARCH_="x86_64"  ;;
        *) echo "[landscape] 不支持的架构: $(uname -m)" >&2; return 1 ;;
    esac
}

_ls_dirs() {
    mkdir -p "${LANDSCAPE_HOME}" "${LANDSCAPE_STATIC}" "${LANDSCAPE_LOG}"
    chmod 0700 "${LANDSCAPE_HOME}"   # home 放 db，只允许 root
}

_ls_binary() {
    _dl_url "${LANDSCAPE_RELEASE}/landscape-webserver-${_LS_ARCH_}-static" landscape-webserver
}

# static.zip 内含顶层 static/，解到 ${LANDSCAPE_STATIC} 即得 .../static/
_ls_static() {
    _zip_="/tmp/landscape-static.zip"
    echo "[landscape] 下载前端资源 ..."
    if ! curl -fsSL --retry 3 --retry-delay 2 "${LANDSCAPE_RELEASE}/static.zip" -o "${_zip_}"; then
        echo "[landscape] 前端资源下载失败" >&2
        return 1
    fi
    if ! unzip -q -o "${_zip_}" -d "${LANDSCAPE_STATIC}"; then
        echo "[landscape] static.zip 解压失败" >&2
        rm -f "${_zip_}"
        return 1
    fi
    rm -f "${_zip_}"
    [ -f "${LANDSCAPE_STATIC}/static/index.html" ] || {
        echo "[landscape] 前端资源不完整：缺 static/index.html" >&2
        return 1
    }
}

# 用刚下载的同一个二进制生成 init 配置：产物带版本号，只能被同版本导入
_ls_init_conf() {
    [ -f /network.env ] && . /network.env

    _wan_extra_=""
    case "${WAN_MODE:-dhcp}" in
        dhcp)   ;;
        static) _wan_extra_="--wan-ip ${WAN_IP} --wan-gateway ${WAN_GATEWAY}" ;;
        *)      echo "[landscape] network.env 的 WAN_MODE=${WAN_MODE} 尚未支持（仅 dhcp/static）" >&2
                return 1 ;;
    esac

    # _wan_extra_ 需要按空格拆分，故不引用
    if ! /usr/local/bin/landscape-webserver config \
        --dir "${LANDSCAPE_HOME}" --force \
        --wan-iface "${WAN_IFACE}" --wan-mode "${WAN_MODE:-dhcp}" ${_wan_extra_} \
        --lan-iface "${LAN_BRIDGE}" --lan-ip "${LAN_IP}/${LAN_CIDR}" \
        --lan-member "${LAN_IFACE}" \
        --lan-dhcp-range "${DHCP_RANGE_START}-${DHCP_RANGE_END}" \
        --lan-dhcp-lease "$(_ls_lease "${DHCP_LEASE_TIME}")" \
        --enable nat,firewall,route-wan,route-lan
    then
        echo "[landscape] landscape_init.toml 生成失败" >&2
        return 1
    fi
    echo "[landscape]   已生成 landscape_init.toml（WAN=${WAN_IFACE} LAN=${LAN_BRIDGE}(+${LAN_IFACE})）"
}

# dnsmasq 写 "12h"，landscape 要秒
_ls_lease() {
    case "$1" in
        *h) echo $(( ${1%h} * 3600 )) ;;
        *m) echo $(( ${1%m} * 60 )) ;;
        *s) echo "${1%s}" ;;
        *)  echo "$1" ;;
    esac
}

_ls_units() {
    install -m 0755 /landscape/init/openrc/landscape-router /etc/init.d/landscape-router

    # 凭据不放 init 脚本（/etc/init.d/* 是 0755，人人可读），单独放 0600 的 conf.d
    mkdir -p /etc/conf.d
    _pass_="${ROOT_PASSWORD:-root}"
    cat > /etc/conf.d/landscape-router << EOF
# landscape web 管理端凭据，由 /etc/init.d/landscape-router source
LANDSCAPE_ADMIN_USER="admin"
LANDSCAPE_ADMIN_PASS="${_pass_}"
EOF
    chmod 0600 /etc/conf.d/landscape-router
    unset _pass_
}

_ls_bpffs() {
    # OpenRC 不像 systemd 会自动挂 bpffs；不挂则 pin eBPF map 报 ENOENT
    # https://landscape.whileaway.dev/zh/faq/alpine-bpffs.html
    if ! grep -qE '^[^#]*[[:space:]]/sys/fs/bpf([[:space:]]|$)' /etc/fstab 2>/dev/null; then
        # 没有结尾换行时直接追加会把两行拼成一条坏条目
        if [ -s /etc/fstab ] && [ "$(tail -c1 /etc/fstab | wc -l)" -eq 0 ]; then
            printf '\n' >> /etc/fstab
        fi
        printf 'bpf /sys/fs/bpf bpf defaults 0 0\n' >> /etc/fstab
    fi
}
