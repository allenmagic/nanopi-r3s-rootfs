# LAN 网段统一为 192.168.8.0/24 — 配置拆分设计

## 背景

`infra/sing-box/config/` 下的出厂默认配置存在子网不一致问题：

| 文件 | 网段 | 问题 |
|------|------|------|
| `network/interfaces` | `192.168.8.1/24` | ✅ 正确 |
| `nftables.d/00-inet-vars.nft` | `192.168.8.0/24` | ✅ 正确 |
| `sing-box/config.json` | `192.168.8.0/24` | ✅ 正确 |
| `dnsmasq.conf` | `192.168.1.x` | ❌ 不一致 |
| `dnsmasq.d/00-base.conf` | `192.168.10.x` | ❌ 不一致 |

同时，`dnsmasq.conf` 和 `00-base.conf` 的职责有重叠——各自定义了 DHCP 地址池和 option，不够清晰。

## 目标

1. 所有配置统一使用 `192.168.8.0/24` 网段
2. 按职责分拆 dnsmasq 配置，一个文件一个职责

## 配置拆分方案

### 文件变更一览

| 操作 | 文件 | 说明 |
|------|------|------|
| 修改 | `dnsmasq.conf` | 精简为核心绑定，网段改 `192.168.8.x` |
| 修改 | `dnsmasq.d/00-base.conf` | 只保留全局选项，网段改 `192.168.8.x` |
| 新增 | `dnsmasq.d/10-dhcp-eth1.conf` | eth1 接口的 DHCP 地址池 + 选项，网段 `192.168.8.x` |

### dnsmasq.conf（精简后）

只保留监听绑定和配置文件引入，不再混入 DHCP 池：

```
port=0
interface=eth1
bind-dynamic
conf-dir=/etc/dnsmasq.d/,*.conf
```

### dnsmasq.d/00-base.conf（全局选项）

只放不绑定接口的全局 DHCP 配置：

```
dhcp-authoritative
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
```

### dnsmasq.d/10-dhcp-eth1.conf（新增，eth1 接口池）

eth1 的完整 DHCP 配置，地址池改为 `192.168.8.x`：

```
# DHCP 地址池（192.168.8.0/24）
dhcp-range=eth1,192.168.8.100,192.168.8.200,255.255.255.0,12h

# 网关
dhcp-option=eth1,3,192.168.8.1

# DNS 服务器
dhcp-option=eth1,6,192.168.8.1

# 广播地址
dhcp-option=eth1,28,192.168.8.255

# 强制默认路由
dhcp-option=eth1,121,0.0.0.0/0,192.168.8.1

# DHCP 日志
log-dhcp
```

### 不做修改的文件

以下文件已经使用 `192.168.8.x`，不做改动：

- `network/interfaces`
- `nftables.d/00-inet-vars.nft`
- `nftables.d/10-inet-nat.nft`（引用 vars 中的变量）
- `nftables.d/20-inet-filter.nft`（引用 vars 中的变量）
- `sing-box/config.json`
- `hosts`
- `dnsmasq.d/10-static.conf`（示例静态分配，无 IP 硬编码）

## 影响分析

- **DHCP 客户端**：重启 dnsmasq 后，之前分配到 `192.168.1.x` 或 `192.168.10.x` 地址的客户端需要释放 IP 重新获取
- **接口配置**：`network/interfaces` 已经是 `192.168.8.1`，无需额外修改
- **nftables/sing-box**：均使用变量引用，已在 `192.168.8.x`，无影响

## 回滚

若需回滚，恢复三个文件的 git 原始版本即可：

```bash
git checkout -- infra/sing-box/config/dnsmasq.conf
git checkout -- infra/sing-box/config/dnsmasq.d/00-base.conf
rm infra/sing-box/config/dnsmasq.d/10-dhcp-eth1.conf
```
