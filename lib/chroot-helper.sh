#!/usr/bin/env bash
#
# chroot-helper.sh —— 通用 chroot 挂载/卸载/执行助手
# 可被任意发行版 rootfs 构建脚本 source 复用
#
# 用法：
#   source lib/chroot-helper.sh
#   chroot_enter /path/to/rootfs        # 挂载伪文件系统 + 配置 DNS / qemu
#   chroot_run   /path/to/rootfs /setup.sh   # 在 chroot 内执行命令
#   chroot_exit  /path/to/rootfs        # 卸载（通常由 trap 自动调用）
#
# 设计为可重复 source，不污染调用方的 set 选项。

# 需要时挂载的伪文件系统列表（按挂载顺序）
_CHROOT_VFS="dev dev/pts proc sys run"

# 状态文件：记录某个 rootfs 实际挂载了哪些点（供逆序卸载）
_chroot_state_file() {
    echo "/tmp/.chroot-mounts-$(echo "$1" | md5sum | cut -d' ' -f1)"
}

# --- 跨架构支持：rootfs 架构 != 主机架构时启用 qemu ---
_chroot_setup_qemu() {
    local rootfs="$1"
    # 通过 rootfs 内某个 ELF 判断目标架构
    local sample
    sample="$(find "$rootfs"/bin "$rootfs"/usr/bin -maxdepth 1 -type f 2>/dev/null | head -n1)"
    [ -z "$sample" ] && return 0

    local target host
    target="$(file -b "$sample" 2>/dev/null | grep -oE 'ARM aarch64|x86-64|ARM,|RISC-V' | head -n1)"
    host="$(uname -m)"

    # 简化判断：目标含 aarch64 且主机非 aarch64 → 需要 qemu
    case "$target" in
        *aarch64*)
            if [ "$host" != "aarch64" ]; then
                if command -v qemu-aarch64-static >/dev/null 2>&1; then
                    cp -f "$(command -v qemu-aarch64-static)" "$rootfs/usr/bin/" 2>/dev/null || true
                    echo "  [qemu] 已注入 qemu-aarch64-static（跨架构 chroot）"
                else
                    echo "  [警告] 跨架构 chroot 但未找到 qemu-aarch64-static" >&2
                fi
            fi
            ;;
    esac
}

# --- 挂载并进入准备 ---
chroot_enter() {
    local rootfs
    rootfs="$(readlink -f "$1")"
    [ -d "$rootfs" ] || { echo "chroot_enter: 目录不存在 $rootfs" >&2; return 1; }

    local state
    state="$(_chroot_state_file "$rootfs")"
    : > "$state"   # 清空旧状态

    echo "==> chroot_enter: $rootfs"

    local vfs src target opts
    for vfs in $_CHROOT_VFS; do
        target="$rootfs/$vfs"
        mkdir -p "$target"
        # 已挂载则跳过（幂等）
        if mountpoint -q "$target"; then
            continue
        fi
        case "$vfs" in
            dev)      src="/dev";  opts="--rbind" ;;
            dev/pts)  src="/dev/pts"; opts="--bind" ;;
            proc)     src="proc"; opts="-t proc" ;;
            sys)      src="/sys"; opts="--rbind" ;;
            run)      src="/run"; opts="--rbind" ;;
        esac

        if [ "$opts" = "-t proc" ]; then
            mount -t proc proc "$target"
        else
            mount $opts "$src" "$target"
            # rbind 的 dev/sys 设为 rslave，避免影响主机
            case "$vfs" in
                dev|sys) mount --make-rslave "$target" 2>/dev/null || true ;;
            esac
        fi
        # 记录已挂载点（逆序卸载用，故 prepend）
        printf '%s\n' "$target" | cat - "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    done

    # DNS：让 chroot 内可联网
    [ -f /etc/resolv.conf ] && cp -f /etc/resolv.conf "$rootfs/etc/resolv.conf" 2>/dev/null || true

    # 跨架构 qemu 注入
    _chroot_setup_qemu "$rootfs"
}

# --- 在 chroot 内执行命令 ---
# chroot_run <rootfs> <cmd...>   也可传环境变量：用 env 前缀
chroot_run() {
    local rootfs
    rootfs="$(readlink -f "$1")"; shift
    chroot "$rootfs" "$@"
}

# --- 卸载 ---
chroot_exit() {
    local rootfs
    rootfs="$(readlink -f "$1")"
    local state
    state="$(_chroot_state_file "$rootfs")"

    echo "==> chroot_exit: $rootfs"
    if [ -f "$state" ]; then
        # 状态文件已是逆序（最后挂的在最前），逐行卸载
        while IFS= read -r m; do
            [ -z "$m" ] && continue
            umount -R "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        done < "$state"
        rm -f "$state"
    else
        # 兜底：无状态文件时按已知列表逆序卸载
        local vfs
        for vfs in run sys proc dev/pts dev; do
            umount -R "$rootfs/$vfs" 2>/dev/null || umount -l "$rootfs/$vfs" 2>/dev/null || true
        done
    fi

    # 清理注入的 qemu
    rm -f "$rootfs/usr/bin/qemu-aarch64-static" 2>/dev/null || true
}
