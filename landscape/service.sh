#
# landscape/service.sh —— Landscape Router 服务启用（OpenRC）
#   被 distros/alpine/setup.sh source
#   定义 enable_landscape()
#
# 仅 OpenRC：其他 init 体系（systemd/runit/sysvinit）尚未接入 landscape
#

enable_landscape() {
    echo "[landscape] === 启用 Landscape 服务 ==="
    # bpffs 由 localmount 读 /etc/fstab 挂载（见 install.sh 的 _ls_bpffs）
    rc-update add localmount boot 2>/dev/null || true
    rc-update add landscape-router default 2>/dev/null || true
    echo "[landscape]   localmount (boot) / landscape-router (default) 已注册"
}
