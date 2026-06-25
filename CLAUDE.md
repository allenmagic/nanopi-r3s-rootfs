# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

router-base —— 面向 NanoPi R3S (aarch64) 的自建路由器 base 系统。通过模板渲染生成路由器配置，支持 Void Linux / Debian / Alpine 三种发行版作为 base OS。

## 构建命令

```bash
# 构建 Void Linux rootfs（最成熟的发行版）
sudo ./distros/void/build.sh

# 构建后打包（PACK=1 自动调用 slim-rootfs.sh）
sudo PACK=1 ./distros/void/build.sh

# 可选参数
BUILD_BASE=/tmp/my-build ROOT_PASSWORD=secret \
  sudo ./distros/void/build.sh

# 生成路由器配置文件（运行时/CI 均可用）
./tools/render.sh \
  --site home-beijing \
  --secrets /path/to/router-config \
  --os void \
  --output /tmp/rendered

# 下载 tera 模板引擎
./tools/lib/fetch-tera.sh

# 交互式进入已构建的 rootfs（调试用）
./tools/chroot-in.sh /path/to/rootfs

# 退出后清理 chroot 挂载点
./tools/chroot-exit.sh /path/to/rootfs

# 打包精简 rootfs
sudo ./lib/slim-rootfs.sh /path/to/rootfs output.tar.xz
```

## 项目架构

### 三层配置模型（schema/）

路由器配置分为三层 TOML 文件，由独立的 `router-config` 仓库维护：

| 层级 | 文件 | 作用 | 合并优先级 |
|------|------|------|-----------|
| Workspace | `workspaces/<name>.toml` | 跨地点共享的个人/团队配置 | 低 |
| Location | `locations/<name>.toml` | 某个物理地点的网络拓扑 | 中 |
| Site | `sites/<workspace>-<location>.toml` | 最终覆盖和设备 IP 绑定 | 高 |

Site 命名约定：`<workspace>-<location>`（如 `home-beijing`）。`render.sh` 按 `SITE%%-*` 切分 workspace 和 location。

### 模板渲染管线（templates/ + tools/render.sh）

Tera 模板（Rust 模板引擎，类似 Jinja2）生成路由器配置文件：

- **通用模板**（`templates/etc/`）：`nftables.conf`（防火墙）、`dnsmasq.conf`（DHCP/DNS）、`hostname`、`hosts`、`resolv.conf`
- **宏模板**（`templates/_macros/`）：`nft.tera`、`singbox.tera`、`systemd.tera`——被其他模板 include
- **合并模板**（`templates/_merged.tera`）：处理跨层设备合并
- **OS 特定模板**（`distros/<os>/templates/`）：对应发行版独有配置
- 以下划线 `_` 开头的模板不会被直接渲染，仅供 include

render.sh 工作流：读取三层 TOML → `concat-context.sh` 合并为单上下文 → tera 渲染所有非 `_` 开头模板 → 输出到指定目录。

### RootFS 构建系统（distros/ + lib/）

| 发行版 | 状态 | 包管理器 | 构建入口 |
|--------|------|----------|---------|
| Void Linux | ✅ 成熟 | xbps | `distros/void/build.sh` + `setup.sh` |
| Debian | 🚧 待完善 | apt | `distros/debian/packages.list` + `post-install.sh` |
| Alpine | 🚧 待完善 | apk | `distros/alpine/packages.list` + `post-install.sh` |

Void 构建流程：
1. 下载 xbps-static 缓存到 `build/cache/`
2. `xbps-install -S base-minimal` 初始化 rootfs
3. 通过 `chroot-helper.sh` 挂载伪文件系统 + DNS + qemu（跨架构）
4. chroot 内执行 `setup.sh`（安装工具包、配置串口 ttyS2@1500000、SSH、root 密码、主机名）
5. 可选：`slim-rootfs.sh` 精简打包为 `.tar.xz`

### 共享库（lib/）

- **`lib/chroot-helper.sh`**：通用 chroot 挂载/卸载/执行助手，支持跨架构（自动注入 qemu-aarch64-static）。可用 `mountpoint -q` 实现幂等挂载，状态文件实现逆序卸载。
- **`lib/slim-rootfs.sh`**：通用 rootfs 精简打包工具，适配 xbps/apt/apk，strip ELF 调试符号，xz 压缩，支持 CI 输出（`$GITHUB_OUTPUT` / `$GITHUB_STEP_SUMMARY`）。

### 工具脚本（tools/）

- `tools/lib/common.sh` —— POSIX sh 公共函数（日志、文件校验、架构检测、临时文件）
- `tools/lib/fetch-tera.sh` —— 根据 `tools/versions.toml` 下载对应平台的 tera-cli 二进制
- `tools/lib/concat-context.sh` —— **待实现**：拼接三层 TOML 上下文
- `tools/install.sh` —— **待实现**：安装到路由器
- `tools/apply.sh` / `tools/update.sh` / `tools/rollback.sh` —— **待实现**：配置部署/更新/回滚

### 目标硬件

- NanoPi R3S（aarch64）
- 串口控制台：`ttyS2` @ 1500000 baud
- 跨架构构建：x86_64 主机需安装 `qemu-user-static` + `binfmt`

## 代码约定

- 脚本使用 `#!/usr/bin/env bash`（需要 bash 特性）或 `#!/bin/sh`（POSIX 兼容）
- Void 配置使用 `runit` 服务管理（`/etc/sv/` + `/etc/runit/runsvdir/default/`）
- 构建产物落 `build/` 目录（已被 `.gitignore` 忽略）
- `tools/bin/` 下存放下载的外部二进制（被 `.gitignore` 忽略，由 `fetch-tera.sh` 管理）
- 三字母缩写规则：short flags（`-t`）在 `[]` 内聚合，long flags（`--template`）分行独立
- 模板文件名去掉 `.tera` 后缀即为输出路径

## 安全注意事项

- 构建脚本需要 root 权限（会通过 `sudo -E` 自动重入）
- `slim-rootfs.sh` 有路径安全护栏：拒绝 `/`、拒绝有残留挂载点的 rootfs
- `build.sh` 有工作区安全护栏：拒绝 `/tmp`、`/home` 等共享目录作为构建目录
