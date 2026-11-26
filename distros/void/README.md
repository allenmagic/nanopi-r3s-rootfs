# Void Linux 构建

## 构建命令

```bash
# 基础构建
sudo ./distros/void/build.sh

# 构建并打包
sudo PACK=1 ./distros/void/build.sh

# 使用镜像源
sudo REPO=tuna PACK=1 ./distros/void/build.sh
sudo REPO=tsinghua PACK=1 ./distros/void/build.sh

# 自定义参数
sudo BUILD_BASE=/tmp/my-build ROOT_PASSWORD=secret \
  HOSTNAME_VAL=my-router ./distros/void/build.sh
```

## 包列表

`distros/void/package.list` — 三段式：

| 段 | 内容 |
|----|------|
| base | openssh, dhcpcd, rsyslog, chrony, curl, ncurses, kmod, e2fsprogs, cloud-guest-utils, rsync |
| sing-box | dnsmasq, nftables, tailscale, sing-box, cloudflared, rtl_nic 固件 |
| landscape | （待定，Void 暂不支持） |

`[fw@<url>] <relative_path>` 用于单文件固件（Void 没有
`linux-firmware-rtl_nic` 拆分包），下载到 `/lib/firmware/<relative_path>`。

## 服务（runit）

`base/init/runit/` 下的服务会部署到 `/etc/sv/`，由 `service.sh` 链接进
`/etc/runit/runsvdir/default/`：

| 服务 | 作用 |
|------|------|
| `rsyslogd` | 系统日志，写 tmpfs `/run/messages`（`/etc/rsyslog.d/99-router.conf`） |
| `nftables` | 加载 `/etc/nftables.conf`（include `/etc/nftables.nft`） |
| `dhcpcd` | WAN DHCP；LAN 静态地址来自 `/etc/dhcpcd.conf`，启动前先跑 `lan-mac` 固定 MAC |
| `dnsmasq` | DHCP/DNS（sing-box 模式下 `port=0` 只做 DHCP） |
| `tailscaled` / `cloudflared` | 组网与隧道 |
| `network-watchdog` | WAN 连通性监控 |
| `wan-mgmt` | WAN 侧管理网段放行 |
| `yunshu` | podman-compose 容器 + `vpn-routes` 路由，由 runit 托管 |
| `local-router` | 一次性任务：sysctl.d + local.d（首启扩容 / LED / hw-tweak） |
| `sing-box` | `INFRA=sing-box` 时启用，启动前等待 `tun0` |

## Void 特有说明

- **模块加载**：Void 的 `kmod` 不提供 `modules-load`（那是 systemd 工具），
  但 runit 的 `02-kmods` core service 会调用它。构建时安装
  `scripts/modules-load.sh` 到 `/usr/bin/modules-load`，读取
  `/etc/modules-load.d/*.conf` 加载 `tun` / `wireguard` / `r8169`。
- **日志**：默认 rsyslog 配置会写 `/var/log`；构建时用
  `/etc/rsyslog.d/99-router.conf` 把日志改到 `/run/messages` 并用 `& stop`
  截断后续规则，避免 SD 卡写入。
- **首启扩容**：`/etc/local.d/10-rootfs-resize.start` 由 `local-router`
  服务执行，依赖 `growpart`（cloud-guest-utils）和 `resize2fs`（e2fsprogs）。
- **LAN MAC**：RTL8111H 无 EEPROM，`dhcpcd` 启动脚本里先调用 `lan-mac`，
  用 SoC serial-number 派生稳定 MAC。
- **sysctl**：共享的 `base/sysctl.d` 使用 systemd 的 `-key = value` 语法，
  构建期会剥掉 `-` 前缀，保证 Void 的 `sysctl -p` 能执行。

## 镜像源说明

`REPO` 支持三种形式：
- 不传 → 官方源
- 别名 → `tuna` / `tsinghua` 自动解析
- 完整 URL → 直接使用

## 产物

- 目录：`build/void/void-rootfs/`
- 打包：`build/void/void-rootfs-minimal.tar.xz`（`PACK=1`）
