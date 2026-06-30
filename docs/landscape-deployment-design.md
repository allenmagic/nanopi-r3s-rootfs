# Landscape Router 集成设计方案

将 Landscape Router 集成到 rootfs 构建系统中的设计方案。

## 设计原则

### 1. INFRA 互斥逻辑

`INFRA=landscape` 时，**不安装 sing-box 体系下的任何工具**：
- `dnsmasq` — landscape 自带 DNS/DHCP 服务
- `tailscale` — landscape 通过插件系统支持虚拟组网
- `sing-box` — landscape 自带分流引擎
- `cloudflared` — landscape 自带隧道支持

实现方式：各发行版 `service.sh` 的 `case` 语句中，`sing-box` 和 `landscape` 已经是互斥分支。但 `setup.sh` 中 `[dl@]` 下载项（tailscale/sing-box/cloudflared）也需要按 INFRA 区分。当前 landscape 段 `package.list` 是空的，下载项不应出现在 landscape 段中。

### 2. 安装路径

Landscape Router 默认配置目录为 `/root/.landscape-router/`，但自动化构建时不应依赖 `/root`：
- **二进制**：`/usr/local/bin/landscape-webserver`
- **配置文件**：`/etc/landscape-router/`（参考 landscape 的 `--config` 参数，需确认是否支持自定义路径）
- **数据目录**：`/var/lib/landscape-router/`（数据库、运行时状态）
- **静态页面**：`/usr/share/landscape-router/static/`
- **日志**：`/var/log/landscape-router/`

启动时通过 `LANDSCAPE_HOME_PATH` 环境变量或命令行参数指定路径，而非硬编码 `/root/.landscape-router/`。具体参数需在集成时阅读 landscape-webserver `--help` 确认。

### 3. 各 OS 的 init 脚本

根据发行版使用不同的初始化脚本，统一放在 `infra/landscape/config/init/` 下：

```
infra/landscape/config/init/
├── openrc/landscape-router    # Gentoo / Alpine
├── runit/landscape-router/run # Void Linux
├── systemd/                   # Debian
│   └── landscape-router.service
└── sysvinit/landscape-router  # Devuan
```

**OpenRC** (`/etc/init.d/landscape-router`)：
```sh
#!/sbin/openrc-run
description="Landscape Router"
command="/usr/local/bin/landscape-webserver"
command_user="root:root"
pidfile="/run/landscape-router.pid"
start_pre() {
    ulimit -l unlimited  # 对应 LimitMEMLOCK=infinity
}
depend() {
    need net
    after firewall
}
```

**runit** (`/etc/sv/landscape-router/run`)：
```sh
#!/bin/sh
ulimit -l unlimited
exec /usr/local/bin/landscape-webserver
```

**systemd** (`/etc/systemd/system/landscape-router.service`)：
```ini
[Unit]
Description=Landscape Router
[Service]
ExecStart=/usr/local/bin/landscape-webserver
Restart=always
User=root
LimitMEMLOCK=infinity
[Install]
WantedBy=multi-user.target
```

**sysvinit** (`/etc/init.d/landscape-router`)：
```sh
#!/bin/sh
### BEGIN INIT INFO
# Provides:          landscape-router
# Required-Start:    $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Description:       Landscape Router
### END INIT INFO
ulimit -l unlimited
case "$1" in
    start)    /usr/local/bin/landscape-webserver & ;;
    stop)     killall landscape-webserver ;;
    restart)  $0 stop; sleep 1; $0 start ;;
esac
```

### 4. 共用初始化配置

所有发行版共用一套 `landscape_init.toml`，部署到 `/etc/landscape-router/landscape_init.toml`（仅首次启动读取）：

```toml
# Landscape Router 初始配置（仅在首次运行时读取）
[system]
home_path = "/var/lib/landscape-router"

[web]
listen_http = "[::]:6300"
listen_https = "[::]:6443"
web_root = "/usr/share/landscape-router/static"

[auth]
admin_user = "admin"
admin_pass = "landscape"

[log]
path = "/var/log/landscape-router"
max_files = 7
debug = false

[store]
database = "/var/lib/landscape-router/db.sqlite"
```

此配置跳过首次交互式设置，构建时直接写入目标 rootfs，使得刷机后 landscape 可直接启动。

## 实施顺序

1. 确认 `landscape-webserver --help` 是否支持 `--home-path` / `--config` 参数自定义路径
2. 创建 4 种 init 脚本（openrc/runit/systemd/sysvinit）
3. 编写 `landscape_init.toml` 模板
4. 填写 `infra/landscape/install.sh`：下载二进制 + 静态文件 + 部署目录
5. 填写 `infra/landscape/service.sh`：按 init 类型启用服务
6. 填写各发行版 `service.sh` 的 landscape 分支
7. 在各 `package.list` 的 landscape 段添加 `[dl@]` 下载项
8. 在各 `setup.sh` 中处理 landscape 段配置部署（与 sing-box 相同逻辑，走 `infra/landscape/config/`）
