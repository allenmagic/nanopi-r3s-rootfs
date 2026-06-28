# router-base

自建路由器 base 系统 —— 为 [NanoPi R3S](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_R3S)（aarch64）构建最小化 rootfs。

## 特性

- **多发行版支持**：Void Linux / Devuan / Debian / Alpine Linux
- **跨架构构建**：x86_64 主机可通过 qemu-user-static 构建 aarch64 rootfs
- **最小化打包**：自动精简 rootfs，xz 极限压缩
- **统一配置部署**：`infra/sing-box/config/` 下的配置文件自动复制到 `/etc/`
- **包管理分离**：三段式 `package.list`（base / sing-box / landscape），`[pm]` 走包管理器、`[dl@URL]` 走下载
- **CI 就绪**：GitHub Actions 自动构建并发布 Release

## 前置要求

- Linux 主机（推荐 Ubuntu 24.04）
- `sudo` 权限
- 跨架构构建（x86_64 构建 aarch64）需安装：

```bash
sudo apt-get install -y qemu-user-static binfmt-support
docker run --rm --privileged tonistiigi/binfmt --install arm64
```

## 通用构建命令

```bash
git clone <repo-url> && cd nanopi-r3s-rootfs

# 构建（自动 sudo 提权）
sudo ./distros/<distro>/build.sh

# 构建并打包为 .tar.xz
sudo PACK=1 ./distros/<distro>/build.sh

# 可选参数
sudo REPO=mirror-alias ROOT_PASSWORD=secret \
  HOSTNAME_VAL=my-router ./distros/<distro>/build.sh
```

## 支持的发型版

| 发行版 | C 库 | Init 工具 | 状态 | 构建说明 |
|--------|------|-----------|------|---------|
| **Void Linux** | glibc | runit | ✅ 成熟 | [查看](distros/void/README.md) |
| **Devuan** | glibc | sysvinit | ✅ 成熟 | [查看](distros/devuan/README.md) |
| **Debian** | glibc | systemd | ✅ 成熟 | [查看](distros/debian/README.md) |
| **Alpine Linux** | musl | OpenRC | ✅ 成熟 | [查看](distros/alpine/README.md) |

构建产物命名规则：`{distro}-{infra}-aarch64-rootfs.tar.xz`，如 `void-sing-box-aarch64-rootfs.tar.xz`。

## INFRA 选择

`INFRA` 环境变量控制部署的路由系统组件：

```bash
# 默认安装 sing-box 栈
sudo ./distros/void/build.sh

# 明确指定（等 landscape 就绪后）
sudo INFRA=landscape ./distros/void/build.sh
```

| INFRA 值 | 包含 |
|----------|------|
| `sing-box` | dnsmasq + nftables + tailscale + sing-box + cloudflared |
| `landscape` | （待定） |

## 构建环境变量

所有变量均可选，未设时使用默认值。

| 变量 | 默认值（Void） | 说明 |
|------|---------------|------|
| `REPO` | 官方源 | 镜像别名（`tuna` `tsinghua` `aliyun`）或完整 URL |
| `BUILD_BASE` | `build/<distro>` | 构建输出目录 |
| `ROOTFS` | `build/<distro>/<distro>-rootfs` | rootfs 具体路径 |
| `CACHE_DIR` | `build/<distro>/cache` | 下载缓存目录 |
| `ARCH` | `aarch64` | 目标架构 |
| `INFRA` | `sing-box` | 路由组件选择，参见上节 |
| `PACK` | `0` | `1` 时构建后打包 `.tar.xz` |
| `ROOT_PASSWORD` | `root` | root 用户密码 |
| `HOSTNAME_VAL` | `nanopi-r3s-<distro>` | 主机名 |

### 密钥注入（可选）

以下变量全部可选，未设则跳过对应的密钥部署。

| 变量 | 注入到 |
|------|--------|
| `SSH_PRIVATE_KEY` | `/root/.ssh/id_ed25519` |
| `SSH_PUBLIC_KEY` | `/root/.ssh/id_ed25519.pub` |
| `TAILSCALE_AUTH_KEY` | `/etc/tailscale/authkey` |
| `HEADSCALE_AUTH_KEY` | `sing-box config.json` 中的 `__ROUTER_HEADSCALE_AUTH_KEY__` 占位符 |

本地构建示例：

```bash
sudo TAILSCALE_AUTH_KEY=tskey-auth-xxx PACK=1 ./distros/void/build.sh
```

CI 构建时对应 GitHub Actions Secrets，由 workflow 自动注入。

## 项目结构

```
├── distros/               # 各发行版构建定义
│   ├── <os>/build.sh      #   rootfs 构建入口
│   ├── <os>/setup.sh      #   chroot 内初始化（包安装 + 配置 + 服务）
│   ├── <os>/service.sh    #   按 init 系统的服务启用
│   └── <os>/package.list  #   三段式包列表
├── lib/
│   ├── download-helpers.sh #  下载函数（_dl_url, _gh_latest_tag）
│   ├── chroot-helper.sh    #  通用 chroot 挂载/卸载/执行
│   └── slim-rootfs.sh      #  rootfs 精简与打包
├── infra/sing-box/config/  # 出厂默认配置文件
│   ├── dnsmasq.conf        #  映射到 /etc/ 的共用配置
│   ├── nftables.nft
│   └── init/               #  各 init 类型服务文件
│       ├── runit/
│       ├── openrc/
│       ├── sysvinit/
│       └── systemd/
└── tools/                  # 工具脚本
    ├── chroot-in.sh        #  交互式 chroot 进入
    ├── chroot-exit.sh      #  chroot 挂载清理
    └── inject-secrets.sh   #  密钥注入（write → ROOTFS，deploy → 系统）
```

## License

MIT
