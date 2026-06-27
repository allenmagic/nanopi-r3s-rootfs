# LAN 网段统一为 192.168.8.0/24 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `infra/sing-box/config/` 下 dnsmasq 配置统一到 `192.168.8.0/24` 网段，并按职责分拆文件。

**Architecture:** 三文件分拆——`dnsmasq.conf` 只做监听绑定和 conf-dir 引入；`00-base.conf` 只放全局 DHCP 选项；新增 `10-dhcp-eth1.conf` 放 eth1 接口的地址池和 DHCP 选项。所有 `192.168.1.x` 和 `192.168.10.x` 改为 `192.168.8.x`。

**Tech Stack:** dnsmasq 配置文件

## 全局约束

- 网段统一为 `192.168.8.0/24`，网关 `192.168.8.1`
- 每个文件一个职责，不混入无关配置
- 不修改已是 `192.168.8.x` 的文件（`network/interfaces`、nftables、sing-box/config.json）

---

### Task 1: 精简 dnsmasq.conf

**Files:**
- Modify: `infra/sing-box/config/dnsmasq.conf`

**Interfaces:**
- Produces: `dnsmasq.conf` 只包含监听绑定和 conf-dir，通过 `conf-dir` 引入分拆后文件

- [ ] **Step 1: 重写 dnsmasq.conf**

```conf
# ============================================================
# dnsmasq.conf —— 出厂默认配置（仅 DHCP，DNS 由 sing-box 提供）
# 被 render.sh 生成的站点配置覆盖
# ============================================================

# 关闭 DNS 功能（DNS 由 sing-box 接管）
port=0

# ============================================================
# 1. 监听配置
# ============================================================
# 只监听内网接口
interface=eth1

# 绑定动态接口，适应虚拟化环境（PVE）接口启动时序
bind-dynamic

# ============================================================
# 2. 引入模块化配置目录
# ============================================================
conf-dir=/etc/dnsmasq.d/,*.conf
```

- [ ] **Step 2: 验证文件内容正确**

Run: `head -20 infra/sing-box/config/dnsmasq.conf`

Expected: 只包含 port=0、interface=eth1、bind-dynamic、conf-dir，无 DHCP 池

- [ ] **Step 3: Commit**

```bash
git add infra/sing-box/config/dnsmasq.conf
git commit -m "refactor(dnsmasq): 精简 dnsmasq.conf，只保留监听绑定和 conf-dir"
```

---

### Task 2: 精简 00-base.conf 为全局选项

**Files:**
- Modify: `infra/sing-box/config/dnsmasq.d/00-base.conf`

**Interfaces:**
- Produces: `00-base.conf` 只保留 `dhcp-authoritative` 和 `dhcp-leasefile`

- [ ] **Step 1: 重写 00-base.conf**

```conf
# ============================================================
# DHCP 全局选项
# ============================================================
# 设置为权威 DHCP 服务器，加快局域网设备获取 IP 的速度
dhcp-authoritative

# 租约记录文件位置
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
```

- [ ] **Step 2: 验证文件内容正确**

Run: `cat infra/sing-box/config/dnsmasq.d/00-base.conf`

Expected: 只有 dhcp-authoritative 和 dhcp-leasefile

- [ ] **Step 3: Commit**

```bash
git add infra/sing-box/config/dnsmasq.d/00-base.conf
git commit -m "refactor(dnsmasq): 精简 00-base.conf 为全局 DHCP 选项"
```

---

### Task 3: 新增 10-dhcp-eth1.conf

**Files:**
- Create: `infra/sing-box/config/dnsmasq.d/10-dhcp-eth1.conf`

**Interfaces:**
- Produces: eth1 接口的 DHCP 地址池和选项，网段 `192.168.8.0/24`

- [ ] **Step 1: 创建 10-dhcp-eth1.conf**

```conf
# ============================================================
# eth1 接口 DHCP 地址池（192.168.8.0/24）
# ============================================================

# DHCP 地址池
dhcp-range=eth1,192.168.8.100,192.168.8.200,255.255.255.0,12h

# 网关
dhcp-option=eth1,3,192.168.8.1

# DNS 服务器（指向 sing-box 的 DNS 代理地址）
dhcp-option=eth1,6,192.168.8.1

# 广播地址
dhcp-option=eth1,28,192.168.8.255

# 强制默认路由通过指定网关
dhcp-option=eth1,121,0.0.0.0/0,192.168.8.1

# DHCP 日志
log-dhcp
```

- [ ] **Step 2: 验证文件创建成功**

Run: `cat infra/sing-box/config/dnsmasq.d/10-dhcp-eth1.conf`

Expected: 文件内容正确包含 192.168.8.x 地址池

- [ ] **Step 3: Commit**

```bash
git add infra/sing-box/config/dnsmasq.d/10-dhcp-eth1.conf
git commit -m "feat(dnsmasq): 新增 10-dhcp-eth1.conf，统一 DHCP 池为 192.168.8.0/24"
```
