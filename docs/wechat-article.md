# 多发行版 RootFS 构建实战：为嵌入式路由器打造用户空间

> 用同一套框架，在 Void、Devuan、Debian、Alpine、Gentoo 之间自由选择

## 一、背景

OpenWrt 虽好，但包管理、C 库、init 系统都自成一体，与桌面/服务器生态割裂。如果你想要的是一个**能跑标准 Linux 软件、用你熟悉的 `apt`/`xbps`/`emerge` 管理包**的路由器，那么自构建 rootfs 是更好的路径。而且我其实不太习惯 OpenWrt 那套解决方案，虽然算不上 Linux 高手，但和 Linux 打了快20年的交道了，更喜欢在命令行方式下进行系统管理，所以选择了这套方案。

本项目基于 NanoPi R3S（aarch64），内核采用**自行裁剪的 Armbian 内核**，这样能够使用主线 Linux 内核。但 Armbian 自带的用户空间（Ubuntu/Debian) 包含大量冗余组件，比如我的路由器不需要 systemd-journald、不需要 PolicyKit、不需要 NetworkManager。于是我就想了想，为这颗裁剪好的内核单独构建一个**最小化的用户空间**（rootfs）然后和内核拼装起来，在构建时只包含我所需的组件：

- **基础系统**：bash、openssh、curl、busybox（部分发行版）
- **网络服务**：dnsmasq（主要是DHCP）、nftables（防火墙）
- **组网工具**：tailscale（异地组网）
- **代理隧道**：sing-box、cloudflared

整个构建系统已在 GitHub 开源：[allenmagic/nanopi-r3s-rootfs](https://github.com/allenmagic/nanopi-r3s-rootfs)

---

## 二、支持的发行版一览

项目目前支持 **5 个发行版**作为路由器的 base，覆盖了 Linux 生态的若干分支：

| 发行版 | C 库 | init 系统 | 包管理器 | 构建状态 |
|--------|------|-----------|----------|---------|
| **Void Linux** | glibc | runit | xbps | ✅ 成熟 |
| **Devuan** | glibc | sysvinit | apt (mmdebstrap) | ✅ 成熟 |
| **Debian** | glibc | systemd | apt (mmdebstrap) | ✅ 成熟 |
| **Alpine Linux** | musl | OpenRC | apk | ✅ 成熟 |
| **Gentoo Linux** | glibc | OpenRC | emerge/portage | ✅ 成熟 |

每个发行版支持 `sing-box` 和 `landscape`（一个基于Rust和eBPF的路由系统，目前设计预留）两种路由组件集。支持多发行版的目的：**选你熟悉的包管理工具来维护系统**，同时保留极客风格的个性化定制空间。

---

## 三、各发行版的构建方式与命令

不同发行版的 rootfs 初始化方式差异很大——有的提供现成的 minirootfs tarball 解压即用，有的需要自底向上 bootstrap。下面只关注**最通用的命令**，不涉及本项目特有的封装逻辑。

### 3.1 Void Linux

Void 的 `xbps` 原生支持 `XBPS_ARCH` 跨架构安装，是思路最直接的方式。

```bash
# 1. 获取 xbps-static 工具链
wget https://repo-default.voidlinux.org/static/xbps-static-latest.aarch64-musl.tar.xz
tar -xf xbps-static-latest.aarch64-musl.tar.xz -C /opt/xbps-static/

# 2. 指定架构安装 base-minimal 到目标目录
env XBPS_ARCH=aarch64 \
  /opt/xbps-static/usr/bin/xbps-install -S -r /target/rootfs \
  -R https://repo-default.voidlinux.org/current \
  base-minimal

# 3. chroot 配置
chroot /target/rootfs xbps-reconfigure -a
```

**bootstrap 机制**：no-chroot 直装——xbps-install 可以离线解包到目标 rootfs，无需 chroot 环境。所以在所有发行版中构建流程最简单。

### 3.2 Devuan / Debian

两者都基于 apt 生态，用 `mmdebstrap` 构建最小 rootfs（比传统 debootstrap 快得多，且原生支持 `--merged-usr`、自定义 hook）。

```bash
# Devuan (excalibur = stable)
mmdebstrap --arch=arm64 --variant=minbase excalibur /target/rootfs \
  https://deb.devuan.org/merged

# Debian
mmdebstrap --arch=arm64 --variant=minbase stable /target/rootfs \
  http://deb.debian.org/debian
```

生成的 rootfs 预配置好 apt sources.list，后续 `chroot /target/rootfs apt-get install <pkg>` 即可。

**bootstrap 机制**：chroot 内安装——mmdebstrap 在宿主机用 `dpkg` 解包基础包到目标目录，再 chroot 进去执行 `dpkg --configure -a`。Devuan 与 Debian 的 build.sh 共用同一套脚手架，差异仅在于 keyring 和 suite 名称。

### 3.3 Alpine Linux

Alpine 官方提供 minirootfs tarball，解压即得完整的 apk 基础系统。

```bash
# 1. 下载 minirootfs
wget https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.3-aarch64.tar.gz

# 2. 解压到目标目录
tar -xf alpine-minirootfs-3.20.3-aarch64.tar.gz -C /target/rootfs

# 3. chroot 后用 apk 安装额外包
chroot /target/rootfs apk add --no-cache bash openssh
```

**bootstrap 机制**：tarball 直接解压——Alpine 的 minirootfs 本质是一个已经构建好的最小系统快照，解压后 `apk` 即可工作。这种方式启动最快（只需网络下载和解压），但灵活性最低（版本由镜像站发布的 tarball 决定）。

### 3.4 Gentoo Linux

Gentoo 的方式最为独特：先下载 stage3 tarball 作为**构建环境**，在该环境内用 `ROOT=<target>` 将包**编译安装**到独立的目标目录。

```bash
# 1. 下载 stage3-arm64-openrc tarball
wget https://distfiles.gentoo.org/releases/arm64/autobuilds/.../stage3-arm64-openrc-<date>.tar.xz

# 2. 解压作为构建环境
tar -xf stage3-arm64-openrc-<date>.tar.xz -C /stage3

# 3. 进入 stage3 环境
chroot /stage3 /bin/bash
source /etc/profile

# 4. 在 stage3 内编译安装到目标 rootfs
ROOT=/target/rootfs emerge --oneshot bash openssh
```

**bootstrap 机制**：两阶段编译——先解压 stage3（含完整 Portage 树和编译器），在 stage3 chroot 内用 `ROOT=<target> emerge` 编译包到目标目录，最后将目标目录整体移出作为最终 rootfs。这种方式的代价是明确而高昂的：构建环境占用 ~2GB 磁盘，emerge 编译时间以十分钟计，即使在原生 ARM64 机器上。

而且 Gentoo 有一个实际问题：**如果在最终 rootfs 中保留 `emerge` 工具，会显著膨胀产物体积**。我选择在 rootfs 中彻底移除 Portage 和编译器，只保留二进制文件。后续系统维护通过 CI 重新构建镜像完成，不在设备上做就地编译。但这就引出一个矛盾：**既然不就地编译，用 Gentoo 的意义何在？**——答案在于 USE flag 级别的定制能力：可以全局禁用 `systemd`、`udev`、`python`、`X` 等不相关特性，确保 rootfs 只包含你真正需要的东西。这种"编译一次，受益永久"的模式恰好匹配嵌入式场景：镜像烧录后不变，升级靠重新烧录。

---

## 四、脚本架构设计：为什么拆成四个文件？

项目初期所有逻辑堆在一个 `build.sh` 中，很快就难以维护。经过与 DeepSeek 多轮交互讨论后，我重构为 **四个职责分明** 的文件：

### 文件结构

```
distros/<发行版>/
├── build.sh          # 构建流水线：下载 → 初始化 rootfs → chroot 挂载 → 执行 setup → 清理 → 打包
├── setup.sh          # 部署脚本：安装包 → 复制配置 → 系统设置 → 启用服务
├── service.sh        # 服务管理：定义启用哪些服务
└── package.list      # 包清单：按功能组分类的软件包列表
```

### 各文件职责

| 文件 | 职责 | 运行环境 | 执行次数 |
|------|------|----------|---------|
| `build.sh` | rootfs **出生**——包管理器初始化、chroot 挂载/卸载、产物打包 | 宿主机（需 root） | 每次构建执行 **一次** |
| `setup.sh` | rootfs **配置**——安装包、写配置、设密码、配串口 | chroot 内 | 每种组合执行 **一次** |
| `service.sh` | **服务声明**——用 init 系统接口启用对应服务 | chroot 内（被 setup.sh source） | 按 infra 选择执行 |
| `package.list` | **物料清单**——每行一个包的声明式列表 | 声明式文件（被 setup.sh 解析） | 按 infra 选择执行 |

### 关键设计细节

**package.list 的声明式设计**：

```
# 基础系统包
[pm] bash openssh curl
[pm] chrony ntpsec

# 通过 HTTP 直接下载的二进制
[dl@] https://github.com/.../sing-box
[dl@] https://github.com/.../cloudflared
```

`[pm]` 行走原生包管理器（xbps-install / apt-get / apk add / emerge），`[dl@]` 行走 `download-helpers.sh` 的 `_dl_url` 函数，直接下载到 `/usr/local/bin/`。这套声明式格式在所有 5 个发行版中完全通用，`setup.sh` 只需要适配不同包管理器的命令行语法，逻辑结构一致。

**chroot 挂载的幂等处理**：

通过 `chroot-helper.sh` 统一管理：`mountpoint -q` 检测挂载点，若已挂载则跳过；状态文件记录挂载顺序，退出时逆序 `umount -l` 卸载，避免重复挂载和卸载残留。

**跨架构处理**：

非 ARM64 宿主机（如 x86_64 CI runner）自动注入 `qemu-aarch64-static`，利用 `binfmt_misc` 透明执行 ARM64 二进制。每个发行版的 build.sh 都会在 chroot 前做一次跨架构预检。

### 拆分的优势

1. **关注点分离**：改包清单只动 `package.list`，新增服务只改 `service.sh`，不动脚本逻辑。

2. **跨发行版复用**：`package.list` 格式完全一致，`setup.sh` 只需调整包管理器命令。添加一个新的发行版时，只需复制其他发行版的结构，替换包管理器和 init 系统相关代码即可，**不必重新设计架构**。

3. **避免单体文件膨胀**：最复杂的 Gentoo 发行版，其 Portage 配置、USE flag 管理、编译优化代码全部隔离在 `setup.sh` 内部，`build.sh` 保持与 Void 一致的流水线结构。横向对比时只看同一接口。

4. **调试定位**：构建失败看三个阶段——下载阶段失败查 `build.sh`，包安装失败查 `setup.sh`，服务起不来查 `service.sh`。

---

## 五、各发行版的优劣势分析

经过在实际硬件（NanoPi R3S，RK3566 四核 A55）上的反复构建和运行测试，同一套路由组件集（sing-box）下各发行版的最终体积如下：

| 发行版 | 最终 rootfs 打包体积 |
|--------|--------------------|
| **Alpine Linux** | 41 MB |
| **Void Linux** | 73 MB |
| **Gentoo Linux** | 75 MB |
| **Devuan** | 76 MB |
| **Debian** | 79 MB |

> 注：以上为 CI 构建的 artifact 体积（tar.xz），编译环境为 GitHub Actions 原生 ARM64 runner。

Alpine 以近一半的体积领先，musl + busybox 的组合在嵌入式场景下的优势一目了然。其余四个 glibc 发行版体积差距不大，都在 73–79 MB 之间——这意味着 init 系统的选择（runit / sysvinit / systemd / OpenRC）对最终体积的影响远小于 C 库的选择（musl vs glibc）。

### Void Linux ⭐ 推荐

**优势：**
- `xbps` 原生跨架构 bootstrap，无需额外工具链，构建流程最简洁
- runit 极度轻量，没有 systemd 的依赖包袱（但需要了解 runit 的 service 管理方式）
- base-minimal 仅 ~60MB，包体积控制优秀
- 滚动更新，版本新但没 Arch 那么激进，稳定性不错

**劣势：**
- 社区规模有限，部分小众包需要自己从源码打包
- 文档不如 Debian/Arch 全面

### Devuan

**优势：**
- 与 Debian 仓库兼容，软件极其丰富
- sysvinit 比 systemd 轻量
- `mmdebstrap` 构建速度最快之一

**劣势：**
- sysvinit 的 service 管理脚本比 runit 的 symlink 机制麻烦
- 部分现代软件（如某些桌面组件）倾向 systemd-only，在路由器场景下影响不大

### Debian

**优势：**
- 最大的包仓库、最广泛的社区支持
- 几乎所有问题都有现成答案

**劣势：**
- systemd 对路由器偏重（更多进程、更多内存占用）
- 包版本保守——稳定但不新

### Alpine Linux

**优势：**
- **极致精简**——musl + busybox，基础 rootfs ~5MB。完整路由器镜像 ~30MB
- 安全优先，默认 PaX 防护
- `apk` 包管理器设计干净，命令语法一致

**劣势：**
- musl 与部分 glibc 软件存在兼容性边界情况。我们的 core 组件（tailscale/sing-box）需要下载静态编译的二进制而非走 apk
- 调试时偶遇 musl 特有的行为差异（dns 解析、locale、线程局部存储），需要额外排障知识

### Gentoo Linux

**优势：**
- **最高定制自由度**——USE flag 精确控制每个包的编译特性，全局禁用 systemd/udev/python 等不相关依赖
- `ROOT=<target> emerge` 原生支持交叉编译到独立目录
- 适合"编译一次，重复使用"的嵌入式镜像模式

**劣势：**
- 构建速度最慢——emerge 编译源码即使在原生 ARM64 上也需要大量时间
- 构建复杂度最高——需要管理 Portage 配置、USE flag、accept_keywords、package.mask
- stage3 构建环境占用 ~2-3GB 磁盘空间
- 最终 rootfs 不保留 emerge，后续维护全部通过 CI 重新构建，放弃了 Gentoo 最引以为傲的"就地编译"能力，本质上只取 USE flag 定制这一项特性

---

## 六、AI 在这个项目中的作用

这个项目从架构设计到每一行代码落地，全程与 AI 深度协作。整个项目由 **DeepSeek V4 Pro** 构建架构设计、实现方案、计划，通过 **Claude Code**（调用 DeepSeek V4 Flash）完成 coding 和 testing。本质上这个项目全是 shell 脚本，并不复杂，所以 AI 能够很好处理。

### 代码生成

各发行版的 `build.sh`、`setup.sh`、`service.sh`、CI 工作流——都是从需求描述出发，由 AI 生成符合项目风格的初版代码。传统做法是自己写 v1、反复调试改到 vN；而 AI 生成的版本经常已经考虑了边界情况（跨架构检测 `QEMU_LD_PREFIX`、幂等挂载 `mountpoint -q`、错误处理 `set -euo pipefail`），迭代了最耗时的 80%。

### 调试修复

构建出错时直接贴日志给 AI 分析根因，比较典型的几个案例：

- **Gentoo fowners 失败**：AI 定位到缺少预创建系统用户（cron、messagebus），给出直写 `passwd`/`group` 的修复方案，跳过 `fowners` 阶段
- **Alpine CI 静默失败**：`wget -q` 吞掉了 HTTP 404 错误，AI 将 `-q` 改为 `-nv` 后错误信息可读
- **QEMU 跨架构自适应**：原生 ARM64 runner 启用多核 sandbox 加速编译，QEMU 模拟环境降级为单核并关闭 sandbox 避免死锁——这套自适应逻辑也是 AI 提供的
- **CI 依赖裁剪**：Gentoo 不需要 `mmdebstrap`，AI 建议在 workflow 中统一安装 `gnupg`，用 `case` 分支处理 distro 特定的依赖

### 架构设计

脚本拆分为四文件结构、`[pm]`/`[dl@]` 声明式包清单格式、infra 组件化设计——都是通过与 AI 讨论形成的。AI 在对话中扮演技术顾问角色：提出可选方案、分析 trade-off、给出推荐。

### 使用感受

AI 的角色相当于**一个 7×24 在线的资深工程师**——讨论方案、写代码、查问题、写文档。对个人开发者来说最直接的好处：**想法到落地之间的摩擦消失了**。以前一个人一个月才能跑通的构建框架，现在一个周末就能出可用的版本。

---

## 结语

多发行版 rootfs 构建框架听起来复杂，但合理的架构拆解 + AI 辅助让这件事变得相当直接。无论你想在路由器上跑熟悉的 apt 生态、Void 的简洁 xbps、还是 Gentoo 的极端定制，这套框架都提供了自由选择的空间。

项目开源：[github.com/allenmagic/nanopi-r3s-rootfs](https://github.com/allenmagic/nanopi-r3s-rootfs)
