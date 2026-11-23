# Alpine 构建

## 构建命令

```bash
# 基础构建
sudo ./distros/alpine/build.sh

# 构建并打包
sudo PACK=1 ./distros/alpine/build.sh

# 使用镜像源（国内推荐）
sudo REPO=aliyun PACK=1 ./distros/alpine/build.sh
sudo REPO=tuna PACK=1 ./distros/alpine/build.sh

# 自定义参数
sudo BUILD_BASE=/tmp/my-build ROOT_PASSWORD=secret \
  HOSTNAME_VAL=my-router ./distros/alpine/build.sh
```

## sing-box + yunshu（基础网络）

```bash
# sing-box 1.14.4（bridge outbound）+ podman yunshu
sudo INFRA=sing-box PACK=1 ./distros/alpine/build.sh
```

- `dnsmasq` 只做 DHCP（`port=0`）；DNS 由 sing-box 的 `dns-in` 接管。
- LAN 流量由 `auto_redirect` 送进 `singtun0`，默认出口 `direct-out`。
- 只有 `/etc/sing-box/rules/yunshu-domains.txt` 命中的域名：
  - DNS 问 yunshu 的 `10.251.1.1`，拿 fake-IP；
  - 数据经 `bridge` 出站送到 yunshu 的 `tun0`。
- yunshu 使用 podman `network_mode: host`，固定创建 `tun0`；sing-box 使用
  `singtun0`，两者不能同名。
- netavark 固定 nftables：`/etc/containers/containers.conf.d/50-netavark-nftables.conf`。
- 内核建议 `kernel_mode=full`（容器栈 + `NFT_FIB_INET`，纯 nftables，无 iptables）。

域名清单运维：

```sh
yunshu-domain list
yunshu-domain add corp.example.com
yunshu-domain del corp.example.com
yunshu-domain apply
```

详细数据流与验收见 [docs/singbox-yunshu-base.md](../../docs/singbox-yunshu-base.md)。

## Landscape Router

```bash
# 需搭 kernel_mode=full 的内核（BTF + eBPF + cgroup CPU 控制）
sudo INFRA=landscape PACK=1 ./distros/alpine/build.sh
```

landscape 接管 DNS/DHCP/防火墙/路由，因此 **base 网络栈整段不装**（base-net 段）：
dnsmasq / nftables / tailscale / cloudflared。`yunshu` / `wan-mgmt` / `network-watchdog`
随 base 部署但不在 landscape 模式下注册服务。

ifupdown 退到只配 `lo`；`eth1` 的 MAC 由 `landscape-router` 的 `start_pre()` 调 `lan-mac` 处理。

容器运行时用 **podman 顶替 docker**（镜像里不含 docker）：启用 `podman` 服务拿到 rootful API
socket，并在 `landscape-router` 启动前把 `/var/run/docker.sock` 链到 `/run/podman/podman.sock`。

构建期用上游 `landscape-webserver config` 子命令（稳定接口）生成 `landscape_init.toml`，
拓扑取自 `network.env`：WAN=`eth0`(dhcp)、LAN=`br_lan` 桥 + `eth1` 成员、DHCP 池 `192.168.8.100-200`。

目录布局与 bpffs 处理见 [docs/landscape-deployment-design.md](../../docs/landscape-deployment-design.md)。

刷机后：Web 管理端 `http://192.168.8.1:6300`，用户 `admin`，密码为构建时的 `ROOT_PASSWORD`。

> 普通 `INFRA=sing-box` 的 rootfs 构建不再接收 `ROOT_PASSWORD`，默认锁定 root；
> 密码由 img 阶段注入。`landscape` 模式例外：它用 `ROOT_PASSWORD` 作为 Web admin 密码，
> 构建 landscape rootfs 时仍需显式提供（不要把带该密码的 rootfs 作为公开 release）。

## 包列表

`distros/alpine/package.list` — 四段式：

| 段 | 内容 |
|----|------|
| base | openssh, chrony, curl, bash, busybox-openrc, podman … |
| base-net | dnsmasq, nftables, tailscale, cloudflared(\*) —— landscape 模式整段跳过 |
| sing-box | 自定义精简构建（`nanopi-r3s-sing-box`，静态 arm64，bridge outbound 需要 ≥1.14） |
| landscape | unzip（二进制与前端资源由 `landscape/install.sh` 下载） |

(\*) cloudflared 通过 `[dl@URL]` 下载安装。段的匹配顺序敏感：`base-net` 必须排在 `base` 之前。

## 镜像源说明

`REPO` 支持三种形式：
- 不传 → 官方源 `https://dl-cdn.alpinelinux.org/alpine`
- 别名 → `aliyun` / `tuna` / `tsinghua` 自动解析
- 完整 URL → 直接使用

## 产物

- 目录：`build/alpine/alpine-rootfs/`
- 打包：`build/alpine/alpine-rootfs-minimal.tar.xz`（`PACK=1`）
