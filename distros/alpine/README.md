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

## Landscape Router

```bash
# 需搭 kernel_mode=full 的内核（BTF + eBPF + cgroup CPU 控制）
sudo INFRA=landscape PACK=1 ./distros/alpine/build.sh
```

landscape 接管 DNS/DHCP/防火墙/路由，因此 **base 网络栈整段不装**（base-net 段）：
dnsmasq / nftables / tailscale / cloudflared。`yunshu` / `wan-mgmt` / `network-watchdog`
随 base 部署但不在 landscape 模式下注册服务。

ifupdown 退到只配 `lo`；`eth1` 的 MAC 由 `landscape-router` 的 `start_pre()` 调 `lan-mac` 处理。

构建期用上游 `landscape-webserver config` 子命令（稳定接口）生成 `landscape_init.toml`，
拓扑取自 `network.env`：WAN=`eth0`(dhcp)、LAN=`br_lan` 桥 + `eth1` 成员、DHCP 池 `192.168.8.100-200`。

目录布局与 bpffs 处理见 [docs/landscape-deployment-design.md](../../docs/landscape-deployment-design.md)。

刷机后：Web 管理端 `http://192.168.8.1:6300`，用户 `admin`，密码为构建时的 `ROOT_PASSWORD`。

## 包列表

`distros/alpine/package.list` — 四段式：

| 段 | 内容 |
|----|------|
| base | openssh, chrony, curl, bash, busybox-openrc, podman … |
| base-net | dnsmasq, nftables, tailscale, cloudflared(\*) —— landscape 模式整段跳过 |
| sing-box | sing-box |
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
