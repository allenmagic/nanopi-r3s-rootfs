# tailscaled-hs 双实例支持方案

## 背景

当前路由器系统支持两种部署模式（INFRA）：
- **base 模式**：基础网络功能
- **sing-box 模式**：包含透明代理功能

目前 base 模式只连接到 Tailscale 官方网络，但官方 DERP 服务器在国内速度较慢。需要添加第二个 Tailscale 实例连接到自建 Headscale 服务器 (hs.zyx1986.icu) 以提升速度。

## 目标

### base 模式
- `tailscaled` → Tailscale 官方网络 (接口 `tailscale0`)
- `tailscaled-hs` → Headscale 自建服务器 (接口 `ts0`)

### sing-box 模式
- `tailscaled` → Tailscale 官方网络 (接口 `tailscale0`)
- sing-box endpoint → Headscale 自建服务器 (接口 `ts0`)
- ❌ **不启用** `tailscaled-hs`（避免与 sing-box endpoint 冲突）

## 设计优势

1. **接口命名一致性**：`ts0` 在两种模式下都指向 Headscale，nftables 防火墙规则无需修改
2. **服务互斥**：sing-box 模式下 `tailscaled-hs` 不启用，避免冲突
3. **灵活性**：保留官方 Tailscale 连接，用于访问官方 tailnet 资源

## 实现方案

### 1. 创建服务单元文件

需要为每个 init 系统创建对应的 `tailscaled-hs` 服务单元：

#### 1.1 systemd (Debian, Devuan)

**文件路径**：`base/init/systemd/tailscaled-hs.service`

```ini
[Unit]
Description=Tailscale agent (Headscale)
After=network.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /var/lib/tailscale-hs /var/run/tailscale-hs
ExecStart=/usr/local/bin/tailscaled \
    --state=/var/lib/tailscale-hs/tailscaled.state \
    --socket=/var/run/tailscale-hs/tailscaled.sock \
    --tun=ts0
ExecStartPost=/bin/sh -c 'if [ -f /etc/tailscale-hs/authkey ]; then \
    sleep 2; \
    /usr/local/bin/tailscale --socket=/var/run/tailscale-hs/tailscaled.sock up \
        --login-server=https://hs.zyx1986.icu \
        --authkey=file:/etc/tailscale-hs/authkey \
        --accept-routes --accept-dns=false; \
fi'
RuntimeDirectory=tailscale-hs
StateDirectory=tailscale-hs
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**关键参数**：
- `--state`：独立状态文件，避免与官方实例冲突
- `--socket`：独立 socket 路径
- `--tun=ts0`：指定接口名称（与 sing-box endpoint 一致）
- `ExecStartPost`：服务启动后自动执行 `tailscale up` 连接到 Headscale
- `After=tailscaled.service`：确保官方 tailscaled 先启动

#### 1.2 OpenRC (Alpine, Gentoo)

**文件路径**：`base/init/openrc/tailscaled-hs`

```bash
#!/sbin/openrc-run

name="tailscaled-hs"
description="Tailscale agent (Headscale)"

command="/usr/local/bin/tailscaled"
command_args="--state=/var/lib/tailscale-hs/tailscaled.state --socket=/var/run/tailscale-hs/tailscaled.sock --tun=ts0"
command_background="yes"
pidfile="/var/run/tailscaled-hs.pid"

depend() {
    need net
    after firewall tailscaled
    use logger
}

start_pre() {
    mkdir -p /var/lib/tailscale-hs /var/run/tailscale-hs
}

start_post() {
    if [ -f /etc/tailscale-hs/authkey ]; then
        sleep 2
        /usr/local/bin/tailscale --socket=/var/run/tailscale-hs/tailscaled.sock up \
            --login-server=https://hs.zyx1986.icu \
            --authkey=file:/etc/tailscale-hs/authkey \
            --accept-routes --accept-dns=false
    fi
}
```

**关键配置**：
- `after tailscaled`：确保官方 tailscaled 先启动
- `start_post()`：服务启动后自动认证

#### 1.3 runit (Void Linux)

**文件路径**：`base/init/runit/tailscaled-hs/run`

```bash
#!/bin/sh
exec 2>&1

# 确保目录存在
mkdir -p /var/lib/tailscale-hs /var/run/tailscale-hs

# 启动 tailscaled
exec /usr/local/bin/tailscaled \
    --state=/var/lib/tailscale-hs/tailscaled.state \
    --socket=/var/run/tailscale-hs/tailscaled.sock \
    --tun=ts0
```

**文件路径**：`base/init/runit/tailscaled-hs-login/run` (oneshot 服务)

```bash
#!/bin/sh
exec 2>&1

# 等待 tailscaled-hs 启动
sv check tailscaled-hs || exit 1
sleep 3

# 如果 auth key 存在且未连接，则执行登录
if [ -f /etc/tailscale-hs/authkey ]; then
    if ! /usr/local/bin/tailscale --socket=/var/run/tailscale-hs/tailscaled.sock status >/dev/null 2>&1; then
        /usr/local/bin/tailscale --socket=/var/run/tailscale-hs/tailscaled.sock up \
            --login-server=https://hs.zyx1986.icu \
            --authkey=file:/etc/tailscale-hs/authkey \
            --accept-routes --accept-dns=false
    fi
fi

# oneshot 服务，执行完毕后退出
exec chpst -b tailscaled-hs-login pause
```

**关键配置**：
- runit 没有 `ExecStartPost`，需要单独的 oneshot 服务处理认证
- `sv check tailscaled-hs`：确保 tailscaled-hs 已启动
- `chpst -b tailscaled-hs-login pause`：标记为 oneshot 服务

### 2. 修改 service.sh 脚本

修改所有发行版的 `service.sh`，添加 `tailscaled-hs` 的条件启用逻辑。

#### 2.1 Debian/Devuan (systemd)

```bash
enable_router_services() {
    echo "[service] === 启用路由器服务 (INFRA=${INFRA:-base}) ==="

    # --- base 服务（按依赖顺序）---
    # 1. 防火墙（最先加载）
    _enable_nftables

    # 2. 核心网络服务
    _enable_service dnsmasq

    # 3. 基础应用服务
    _enable_service ssh
    _enable_service chrony

    # 4. VPN 和隧道服务
    _enable_service tailscaled
    
    # 4.1 仅 base 模式启用 tailscaled-hs（sing-box 模式使用 endpoint）
    if [[ ",${INFRA:-base}," != *",sing-box,"* ]]; then
        _enable_service tailscaled-hs
    fi
    
    _enable_cloudflared

    # --- 根据 INFRA 启用组件服务 ---
    case ",${INFRA:-base}," in
        *",sing-box,"*)
            echo "[service] --- sing-box 服务 ---"
            _enable_singbox
            ;;
    esac

    echo "[service] === 服务启用完成 ==="
}
```

#### 2.2 Alpine/Gentoo (OpenRC)

类似逻辑，使用 `rc-update add tailscaled-hs default`

#### 2.3 Void Linux (runit)

类似逻辑，使用 `ln -s /etc/sv/tailscaled-hs /var/service/`

### 3. Headscale 认证方式

复用现有的 `inject-secrets.sh` 密钥注入机制。

#### 3.1 当前密钥注入流程

项目已有 `tools/inject-secrets.sh` 脚本负责密钥注入：

1. **构建时（宿主机）**：
   ```bash
   inject-secrets.sh write <rootfs>
   ```
   从环境变量 `HEADSCALE_AUTH_KEY` 读取，写入 `/opt/installer/tmp/headscale_authkey`

2. **部署时（chroot 内）**：
   ```bash
   inject-secrets.sh deploy
   ```
   读取临时文件，替换 sing-box config.json 中的 `__ROUTER_HEADSCALE_AUTH_KEY__` 占位符

#### 3.2 扩展支持 tailscaled-hs

在 `inject-secrets.sh` 的 deploy 模式中添加逻辑：

```bash
# 3) tailscaled-hs: /etc/tailscale-hs/authkey
if [ -f "${SECRET_DIR}/headscale_authkey" ]; then
    mkdir -p /etc/tailscale-hs
    cp "${SECRET_DIR}/headscale_authkey" /etc/tailscale-hs/authkey
    chmod 600 /etc/tailscale-hs/authkey
    echo "  → tailscaled-hs authkey 已注入"
fi
```

#### 3.3 服务启动后自动认证

**systemd** (Debian, Devuan)：

使用 `ExecStartPost` 在 tailscaled 启动后自动执行 `tailscale up`：

```ini
[Service]
ExecStartPost=/bin/sh -c 'if [ -f /etc/tailscale-hs/authkey ]; then \
    /usr/local/bin/tailscale --socket=/var/run/tailscale-hs/tailscaled.sock up \
        --login-server=https://hs.zyx1986.icu \
        --authkey=file:/etc/tailscale-hs/authkey \
        --accept-routes --accept-dns=false; \
fi'
```

**OpenRC** (Alpine, Gentoo)：

在 `start_post()` 钩子中执行：

```bash
start_post() {
    if [ -f /etc/tailscale-hs/authkey ]; then
        /usr/local/bin/tailscale --socket=/var/run/tailscale-hs/tailscaled.sock up \
            --login-server=https://hs.zyx1986.icu \
            --authkey=file:/etc/tailscale-hs/authkey \
            --accept-routes --accept-dns=false
    fi
}
```

**runit** (Void Linux)：

创建 `base/init/runit/tailscaled-hs/finish` 脚本，在服务启动后执行：

```bash
#!/bin/sh
# 等待 tailscaled 就绪
sleep 2

if [ -f /etc/tailscale-hs/authkey ]; then
    /usr/local/bin/tailscale --socket=/var/run/tailscale-hs/tailscaled.sock up \
        --login-server=https://hs.zyx1986.icu \
        --authkey=file:/etc/tailscale-hs/authkey \
        --accept-routes --accept-dns=false
fi
```

**注意**：runit 的 `finish` 脚本在服务停止时执行，不适合用于初始化。需要创建独立的初始化服务或使用 oneshot 脚本。

**更好的方案**：创建 `base/scripts/tailscale-hs-init.sh` 一次性初始化脚本，由 setup.sh 在构建时执行，或由 systemd/openrc oneshot 服务在首次启动时执行。

### 4. 构建流程集成

#### 4.1 服务文件复制

服务文件已经在各发行版的 `setup.sh` 中复制，只需确保新增的 `tailscaled-hs` 服务文件被包含：

- systemd: `base/init/systemd/tailscaled-hs.service` → `/etc/systemd/system/`
- OpenRC: `base/init/openrc/tailscaled-hs` → `/etc/init.d/`
- runit: `base/init/runit/tailscaled-hs/run` → `/etc/sv/tailscaled-hs/`

#### 4.2 修改 inject-secrets.sh

在 `tools/inject-secrets.sh` 的 deploy 部分添加 tailscaled-hs 支持（约第 115 行之后）：

```bash
# 3) tailscaled-hs: /etc/tailscale-hs/authkey
if [ -f "${SECRET_DIR}/headscale_authkey" ]; then
    mkdir -p /etc/tailscale-hs
    cp "${SECRET_DIR}/headscale_authkey" /etc/tailscale-hs/authkey
    chmod 600 /etc/tailscale-hs/authkey
    echo "  → tailscaled-hs authkey 已注入"
fi
```

**注意**：这段逻辑复用现有的 `headscale_authkey` 文件，无需创建新的环境变量。

### 5. nftables 防火墙规则

**无需修改**！当前 nftables 规则已经支持 `ts0` 接口：

```nft
define TS_NET = ts0  # 或者同时支持 ts0 和 tailscale0
```

只要 `ts0` 存在，防火墙规则就能正常工作。

### 6. 网络接口命名总结

| 接口名称 | 用途 | base 模式 | sing-box 模式 |
|---------|------|----------|---------------|
| `tailscale0` | Tailscale 官方网络 | ✅ tailscaled | ✅ tailscaled |
| `ts0` | Headscale 自建网络 | ✅ tailscaled-hs | ✅ sing-box endpoint |
| `tun0` | sing-box TUN 接口 | ❌ | ✅ sing-box |

## 实施步骤

### Phase 1: 创建服务单元文件
1. ✅ 创建 `base/init/systemd/tailscaled-hs.service`
2. ✅ 创建 `base/init/openrc/tailscaled-hs`
3. ✅ 创建 `base/init/runit/tailscaled-hs/run`

### Phase 2: 修改密钥注入脚本
4. ✅ 修改 `tools/inject-secrets.sh`，添加 tailscaled-hs authkey 注入逻辑

### Phase 3: 修改服务启用脚本
5. ✅ 修改 `distros/debian/service.sh`
6. ✅ 修改 `distros/devuan/service.sh`
7. ✅ 修改 `distros/alpine/service.sh`
8. ✅ 修改 `distros/gentoo/service.sh`
9. ✅ 修改 `distros/void/service.sh`

### Phase 4: 测试验证
10. ⏳ 构建 base 模式 rootfs，验证两个 tailscale 实例共存
11. ⏳ 构建 sing-box 模式 rootfs，验证 tailscaled-hs 未启用
12. ⏳ 验证网络连通性和防火墙规则
13. ⏳ 验证 auth key 注入和自动认证流程

## 潜在问题与解决方案

### 问题 1: 两个 tailscale CLI 如何区分？

**解决方案**：通过 `--socket` 参数指定：
```bash
# 官方实例
tailscale status

# Headscale 实例
tailscale --socket=/var/run/tailscale-hs/tailscaled.sock status
```

可以创建 alias：
```bash
alias tailscale-hs='tailscale --socket=/var/run/tailscale-hs/tailscaled.sock'
```

### 问题 2: auth key 轮换

Headscale auth key 可能需要定期轮换。

**解决方案**：
- 使用 reusable auth key（Headscale 支持）
- 或者通过配置管理系统定期更新

### 问题 3: sing-box endpoint 与 tailscaled-hs 同时启动

如果 sing-box 模式下误启用了 `tailscaled-hs`，两者会争抢 `ts0` 接口。

**解决方案**：
- 在 service.sh 中明确互斥逻辑
- 添加启动前检测脚本，检查 `ts0` 是否已存在

### 问题 4: 状态持久化

rootfs 重启后，`tailscaled-hs` 的状态会丢失吗？

**解决方案**：
- `/var/lib/tailscale-hs` 应该持久化存储
- 或者使用 auth key 自动重新认证

## 依赖关系

- Tailscale 二进制文件：已在 `package.list` 中配置下载
- Headscale 服务器：`https://hs.zyx1986.icu`（需保持可用）
- Auth key：需要从 Headscale 控制台生成

## 兼容性

### 向后兼容
- 现有 base 模式构建不受影响（新增服务默认不启用）
- 现有 sing-box 模式构建不受影响（逻辑互斥）

### 前向兼容
- 未来如果需要更多 Tailscale 实例，可以继续复制这个模式

## 测试清单

- [ ] base 模式：两个 tailscale 实例同时运行
- [ ] base 模式：`tailscale0` 连接到官方网络
- [ ] base 模式：`ts0` 连接到 Headscale
- [ ] sing-box 模式：只有一个 tailscale 实例运行
- [ ] sing-box 模式：`ts0` 由 sing-box endpoint 管理
- [ ] 防火墙规则：`ts0` 流量正常转发
- [ ] 重启后状态保持
- [ ] 手动停止/启动服务正常工作

## 参考资料

- Tailscale 官方文档：https://tailscale.com/kb/
- Headscale 文档：https://headscale.net/
- systemd 服务配置：https://www.freedesktop.org/software/systemd/man/systemd.service.html
- OpenRC 服务配置：https://wiki.gentoo.org/wiki/OpenRC
- runit 服务配置：http://smarden.org/runit/
