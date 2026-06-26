# router-base

自建路由器 base 系统 —— 为 [NanoPi R3S](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_R3S)（aarch64）构建最小化 rootfs 并生成运行时配置。

## 特性

- **多发行版支持**：Void Linux（成熟）、Devuan（成熟）、Debian（成熟）、Alpine（进行中）
- **模板化配置**：基于 Tera 模板引擎（Jinja2 语法），三层 TOML 配置自动合并渲染
- **跨架构构建**：x86_64 主机可通过 qemu-user-static 构建 aarch64 rootfs
- **最小化打包**：自动精简 rootfs（清理 locale/man、strip 调试符号、清空包缓存），xz 极限压缩
- **CI 就绪**：构建脚本内置 `GITHUB_OUTPUT` / `GITHUB_STEP_SUMMARY` 输出支持

## 快速开始

### 前置要求

- Linux 主机（推荐 Ubuntu 24.04 或等效环境）
- `sudo` 权限
- 跨架构构建需安装：

```bash
sudo apt-get install -y qemu-user-static binfmt-support
docker run --rm --privileged tonistiigi/binfmt --install arm64
```

### 构建 Void Linux rootfs

```bash
# 克隆仓库
git clone <repo-url> && cd nanopi-r3s-rootfs

# 构建 base-minimal rootfs（自动 sudo 提权）
./distros/void/build.sh

# 构建并打包为 .tar.xz
sudo PACK=1 ./distros/void/build.sh

# 自定义参数
sudo BUILD_BASE=/tmp/my-build ROOT_PASSWORD=mysecret \
  HOSTNAME_VAL=my-router ./distros/void/build.sh

# 使用镜像源别名（支持：default / tuna / tsinghua）
sudo REPO=tuna PACK=1 ./distros/void/build.sh

# 或直接指定完整镜像 URL
sudo REPO=https://mirrors.tuna.tsinghua.edu.cn/voidlinux/current/aarch64 \
  PACK=1 ./distros/void/build.sh
```

构建产物默认输出到 `build/void/void-rootfs/`（目录），打包后为 `build/void/void-rootfs-minimal.tar.xz`。

> **镜像源说明**：`build.sh` 内置了常用镜像源别名。`REPO` 支持三种形式：
> - 不传 → 官方源 `https://repo-default.voidlinux.org/current/aarch64`
> - 别名 → `tuna` / `tsinghua` 自动解析到对应镜像 URL 并推导 `XBPS_STATIC_URL`
> - 完整 URL → 直接使用，`XBPS_STATIC_URL` 按 Void 惯例 `{base}/static/…` 推导
>
> 如果自定义镜像的 xbps-static 路径不符合惯例，可用 `XBPS_STATIC_URL` 单独指定：
> ```bash
> REPO=https://my-mirror/voidlinux/current/aarch64 \
> XBPS_STATIC_URL=https://my-mirror/voidlinux/static/xbps-static-latest.aarch64-musl.tar.xz \
> sudo ./distros/void/build.sh
> ```

### 渲染配置

```bash
# 先下载 tera 模板引擎
./tools/lib/fetch-tera.sh

# 生成路由器配置文件（需要独立的 router-config 仓库）
./tools/render.sh \
  --site home-beijing \
  --secrets /path/to/router-config \
  --os void \
  --output /tmp/rendered
```

## 配置模型

配置分为三层 TOML 文件，存储在独立的 `router-config` 仓库中，按优先级从低到高合并：

```
Workspace（跨地点共享）
  └─ Location（物理地点网络拓扑）
       └─ Site（最终覆盖 + 设备 IP 绑定）
```

| 层级 | 文件 | 内容 |
|------|------|------|
| **Workspace** | `workspaces/<name>.toml` | 个人常驻设备（MAC + hostname）、偏好设置 |
| **Location** | `locations/<name>.toml` | LAN 拓扑、DHCP 范围、上游 DNS、地点专属设备 |
| **Site** | `sites/<workspace>-<location>.toml` | 设备 IP 绑定、临时覆盖 |

Site 命名约定：`<workspace>-<location>`，例如 `home-beijing`、`office-shanghai`。

## 支持的发型版

| 发行版 | 状态 | 包管理器 | 服务管理 | 串口 |
|--------|------|----------|---------|------|
| **Void Linux** | ✅ 成熟 | xbps | runit | ttyS2 @ 1500000 |
| **Devuan** | ✅ 成熟 | apt (mmdebstrap) | sysvinit | ttyS2 @ 1500000 |
| **Debian** | ✅ 成熟 | apt (mmdebstrap) | systemd | ttyS2 @ 1500000 |
| **Alpine** | 🚧 待完善 | apk | OpenRC | - |

### Void Linux 构建流程

1. 下载 `xbps-static` 到缓存（`build/void/cache/`）
2. `xbps-install -S base-minimal` 启动 rootfs
3. 挂载伪文件系统 + qemu（跨架构）+ DNS
4. chroot 内执行 `setup.sh`：
   - 安装工具包（ncurses、iproute2、dhcpcd、openssh 等）
   - `xbps-reconfigure -a`
   - 设置 root 密码、主机名
   - 配置串口控制台（`ttyS2` @ 1500000）
   - 启用 SSH 服务
5. 可选：`slim-rootfs.sh` 精简并打包为 `.tar.xz`

### Devuan 构建流程

```bash
# 默认官方源构建
sudo ./distros/devuan/build.sh

# 构建并打包
sudo PACK=1 ./distros/devuan/build.sh

# 使用镜像源别名（支持：default / tuna / tsinghua）
sudo REPO=tuna PACK=1 ./distros/devuan/build.sh

# 或直接指定完整镜像 URL
sudo REPO=https://mirrors.tuna.tsinghua.edu.cn/devuan/merged \
  PACK=1 ./distros/devuan/build.sh

# 自定义参数
sudo SUITE=testing ROOT_PASSWORD=mysecret \
  ./distros/devuan/build.sh
```

> **镜像源说明**：`build.sh` 内置了常用镜像源别名。`REPO` 支持三种形式：
> - 不传 → 官方源 `http://deb.devuan.org/merged`
> - 别名 → `tuna` / `tsinghua` 自动解析到对应镜像 URL 并推导 keyring 路径
> - 完整 URL → 直接使用，keyring 路径按 Devuan 惯例 `{base}/devuan/pool/…` 推导
>
> 如果自定义镜像的 keyring 路径不符合惯例，可用 `KEYRING_POOL` 单独指定：
> ```bash
> REPO=https://my-mirror/devuan/merged \
> KEYRING_POOL=https://my-mirror/pool/devuan-keyring/ \
> sudo ./distros/devuan/build.sh
> ```

### Debian 构建流程

```bash
# 默认官方源构建（默认 stable）
sudo ./distros/debian/build.sh

# 构建并打包
sudo PACK=1 ./distros/debian/build.sh

# 使用镜像源别名（支持：default / tuna / tsinghua）
sudo REPO=tuna PACK=1 ./distros/debian/build.sh

# 自定义参数
sudo SUITE=testing ROOT_PASSWORD=mysecret \
  ./distros/debian/build.sh
```

> **镜像源说明**：Debian 的 `build.sh` 同样支持别名机制，keyring 从 mirror pool 自动下载。

## 项目结构

```
├── distros/                    # 发型版构建定义
│   ├── void/                   #   Void Linux（完整实现）
│   │   ├── build.sh            #     rootfs 构建入口
│   │   └── setup.sh            #     chroot 内初始化脚本
│   ├── devuan/                 #   Devuan（完整实现）
│   │   ├── build.sh            #     rootfs 构建入口（mmdebstrap）
│   │   └── setup.sh            #     chroot 内初始化脚本
│   ├── debian/                 #   Debian（完整实现）
│   │   ├── build.sh            #     rootfs 构建入口（mmdebstrap, systemd）
│   │   └── setup.sh            #     chroot 内初始化脚本
│   └── alpine/                 #   Alpine（进行中）
├── lib/                        # 共享库
│   ├── chroot-helper.sh        #   通用 chroot 挂载/卸载/执行
│   └── slim-rootfs.sh          #   rootfs 精简与打包
├── templates/                  # Tera 模板
│   ├── _merged.tera            #   设备合并逻辑
│   ├── _macros/                #   宏模板（被 include 使用）
│   │   ├── nft.tera            #     nftables 防火墙宏
│   │   ├── singbox.tera        #     Sing-box 代理宏
│   │   └── systemd.tera        #     systemd 单元宏
│   └── etc/                    #   生成的路由器配置文件
│       ├── dnsmasq.conf.tera   #     DHCP/DNS
│       ├── nftables.conf.tera  #     防火墙
│       ├── hostname.tera       #     主机名
│       ├── hosts.tera          #     hosts
│       └── resolv.conf.tera    #     DNS 解析
├── schema/                     # 三层配置文档
│   ├── workspace.example.toml  #   workspace 配置示例
│   ├── location.example.toml   #   location 配置示例
│   └── site.example.toml       #   site 配置示例
├── tools/                      # 工具脚本
│   ├── render.sh               #   模板渲染主流程
│   ├── chroot-in.sh            #   交互式 chroot 进入
│   ├── chroot-exit.sh          #   chroot 挂载清理
│   ├── lib/
│   │   ├── common.sh           #     公共函数（日志、校验）
│   │   ├── fetch-tera.sh       #     下载 tera 二进制
│   │   └── concat-context.sh   #     TOML 上下文合并（待实现）
│   ├── versions.toml           #   外部依赖版本锁定
│   └── install.sh              #   路由器安装入口（待实现）
└── build/                      # 构建产物（gitignore）
```

## 模板渲染约定

- 以下划线 `_` 开头的模板文件/目录不被直接渲染，仅供 `include`/`macro` 使用
- 模板文件 `.tera` 后缀在渲染时自动去除，`etc/dnsmasq.conf.tera` → `etc/dnsmasq.conf`
- 通用模板在 `templates/` 下，OS 特定模板在 `distros/<os>/templates/` 下，输出到同一目录

## License

MIT
