# 路由器统一软件安装方案

## 概述

为 Void Linux / Devuan / Debian 三个发行版统一安装路由器核心软件，通过共享脚本 `lib/install-router-software.sh` 实现，避免各发行版 setup.sh 重复维护。

## 架构

```
lib/install-router-software.sh   # 新增：POSIX sh，chroot 内被 setup.sh source
                                  #   提供 install_router_software() 入口函数

distros/*/build.sh               # 修改：传入 DISTRO 环境变量，拷贝共享脚本进 rootfs
distros/*/setup.sh               # 修改：安装基础包后 source 并调用
```

## 待安装软件

| 软件 | 安装方式 | 说明 |
|------|----------|------|
| **dnsmasq** | 包管理器 | Void/Devuan/Debian 官方仓库均有，包名统一 |
| **nftables** | 包管理器 | 同上 |
| **sing-box** | GitHub Releases | `sing-box-${VERSION}-linux-arm64.tar.gz` |
| **tailscale** | 官方安装脚本 | `tailscale.com/install.sh`（自动检测 distro/arch） |
| **cloudflared** | GitHub Releases | `cloudflared-linux-arm64` |

## 调用时序

```
setup.sh 原有流程：
  apt-get update → 安装基础包 → 系统设置(密码/主机名/串口/服务) → 清理

改为：
  apt-get update → 安装基础包 → install_router_software() → 系统设置 → 清理
```

放在系统设置之前，便于后续扩展时在 init 服务配置阶段处理 sing-box/tailscale 的服务注册。

## 关键设计

### 包管理器分发

通过 `$DISTRO` 变量选择安装命令：

```sh
_pkg_install() {
    case "$DISTRO" in
        void)   xbps-install -y -S -R "${REPO}" "$1" ;;
        debian|devuan) apt-get install -y --no-install-recommends "$1" ;;
    esac
}
```

### 下载与错误处理

- 非仓库软件通过 GitHub Releases 下载 arm64 二进制到 `/usr/local/bin/`
- curl 下载支持 3 次重试 + 指数退避（1s → 2s → 4s）
- 默认 `set -eu` 遇错即停

### 版本控制

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `SING_BOX_VERSION` | latest | sing-box 版本 |
| `TAILSCALE_VERSION` | latest | tailscale 版本 |
| `CLOUDFLARED_VERSION` | latest | cloudflared 版本 |

### files 对比：bash vs sh

共享脚本使用 POSIX sh（`#!/bin/sh`），兼容 chroot 内可能无 bash 的环境（minbase 默认只有 sh）。

## 需要修改的文件

| 文件 | 改动内容 |
|------|----------|
| `lib/install-router-software.sh` | **新增**：统一安装脚本 |
| `distros/void/build.sh` | chroot_run 前拷贝共享脚本，env 加 `DISTRO` |
| `distros/devuan/build.sh` | 同上 |
| `distros/debian/build.sh` | 同上 |
| `distros/void/setup.sh` | 基础包加 `curl`，最后 source 并调用 |
| `distros/devuan/setup.sh` | 基础包加 `curl`，最后 source 并调用 |
| `distros/debian/setup.sh` | 基础包加 `curl`，最后 source 并调用 |

## 验证

```bash
# 本地测试各发行版
sudo REPO=tuna ./distros/void/build.sh
sudo REPO=tuna ./distros/devuan/build.sh
sudo REPO=tuna ./distros/debian/build.sh
```

## 关联

- 方案 2：landscape + docker + cloudflared（待规划）
