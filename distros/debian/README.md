# Debian 构建

## 构建命令

```bash
# 基础构建（默认 stable）
sudo ./distros/debian/build.sh

# 构建并打包
sudo PACK=1 ./distros/debian/build.sh

# 使用镜像源
sudo REPO=tuna PACK=1 ./distros/debian/build.sh
sudo REPO=tsinghua PACK=1 ./distros/debian/build.sh

# 自定义参数
sudo SUITE=testing ROOT_PASSWORD=secret \
  ./distros/debian/build.sh
```

## 包列表

`distros/debian/package.list` — 三段式：

| 段 | 内容 |
|----|------|
| base | openssh-server, chrony, curl, ncurses |
| sing-box | dnsmasq, nftables, tailscale(\*), sing-box(\*), cloudflared(\*) |

(\*) Debian stable 仓库中无此包，通过 `[dl@URL]` 下载安装。

## 镜像源说明

`REPO` 支持三种形式：
- 不传 → 官方源 `http://deb.debian.org/debian`
- 别名 → `tuna` / `tsinghua` 自动解析
- 完整 URL → 直接使用

## 产物

- 目录：`build/debian/debian-rootfs/`
- 打包：`build/debian/debian-rootfs-minimal.tar.xz`（`PACK=1`）
