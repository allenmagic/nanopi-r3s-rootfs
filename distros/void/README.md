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
| base | openssh, chrony, curl, ncurses |
| sing-box | dnsmasq, nftables, tailscale, sing-box, cloudflared |
| landscape | （待定） |

## 镜像源说明

`REPO` 支持三种形式：
- 不传 → 官方源
- 别名 → `tuna` / `tsinghua` 自动解析
- 完整 URL → 直接使用

## 产物

- 目录：`build/void/void-rootfs/`
- 打包：`build/void/void-rootfs-minimal.tar.xz`（`PACK=1`）
