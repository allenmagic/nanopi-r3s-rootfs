# 网络配置重构计划

> 将 WAN/LAN IP、DHCP 配置从硬编码改为全局 `network.env` + per-distro `network.sh` 模式

---

## 一、当前问题

1. **LAN IP 硬编码在 3 个文件中**：`network/interfaces`、`dnsmasq.d/10-dhcp-eth1.conf`、`nftables.d/00-inet-vars.nft`
2. **WAN/LAN 配置方式各发行版不同**，但 `network/interfaces` 只适配 ifupdown（Debian/Devuan/Alpine），Void/Gentoo 不生效
3. **改一次 IP 需要跨 3 个文件手工联动**，容易遗漏

---

## 二、目标架构

```
nanopi-r3s-rootfs/
├── network.env                          # [新增] 全局网络拓扑数据源（唯一）
├── distros/<发行版>/
│   ├── network.sh                       # [新增] 读取 network.env，生成该 distro 原生网络配置
│   ├── build.sh                         # [修改] 复制 network.conf + network.sh 到 rootfs
│   ├── setup.sh                         # [修改] 部署阶段调用 configure_network()
│   ├── service.sh                       # 不变
│   └── package.list                     # 不变
└── infra/sing-box/config/
    ├── dnsmasq.d/
    │   └── 10-dhcp-eth1.conf            # [修改] 硬编码值 → __PLACEHOLDER__
    ├── nftables.d/
    │   └── 00-inet-vars.nft             # [修改] ROUTER_LAN_IP/LAN_NET → __PLACEHOLDER__
    └── network/
        └── interfaces                   # [删除] 由 network.sh 动态生成
```

### 数据流

```
network.env (纯 KV 数据)
        │
        ├─ 被 build.sh 复制到 ${ROOTFS}/network.env
        │
        ▼
network.sh (per-distro 读取 network.env)
        │
        ├─→ 该 distro 原生网络配置 (ifupdown / dhcpcd / netifrc)
        ├─→ sed 替换 dnsmasq 配置中的占位符
        └─→ sed 替换 nftables vars 中的占位符
```

### 接口约定

每个 `network.sh` 实现一个函数：

```bash
configure_network() {
    # 1. source /network.env（即 repo 根下的 network.env）
    # 2. 按 distro 生成 WAN/LAN 原生配置
    # 3. sed 替换 /etc/dnsmasq.d/ 和 /etc/nftables.d/ 中的占位符
}
```

`setup.sh` 在"部署配置"阶段调用：

```bash
. /network.sh
configure_network
```

调用时机在包安装之后、服务启用之前。

---

## 三、新增文件

### 3.1 `network.env`（项目根目录）

```bash
# ============================
# 路由器网络拓扑配置
# ============================

# ---------- WAN 口 ----------
WAN_IFACE=eth0
WAN_MODE=dhcp                      # dhcp | static | pppoe
# static 模式才需要以下
# WAN_IP=192.168.1.100
# WAN_GATEWAY=192.168.1.1
# WAN_DNS1=1.1.1.1
# WAN_DNS2=8.8.8.8

# ---------- LAN 口 ----------
LAN_IFACE=eth1
LAN_IP=192.168.8.1
LAN_NETMASK=255.255.255.0
LAN_NETWORK=192.168.8.0/24

# ---------- DHCP 服务器 ----------
DHCP_RANGE_START=192.168.8.100
DHCP_RANGE_END=192.168.8.200
DHCP_LEASE_TIME=12h
```

### 3.2 各发行版 `network.sh`

| 发行版 | WAN 工具 | LAN 配置方式 | 生成目标文件 |
|--------|---------|-------------|-------------|
| **Void** | dhcpcd（自动） | dhcpcd.conf static ip | `/etc/dhcpcd.conf` |
| **Devuan** | ifupdown dhcp | ifupdown static | `/etc/network/interfaces` |
| **Debian** | systemd-networkd 或 ifupdown | 同上 | `/etc/network/interfaces` |
| **Alpine** | udhcpc（busybox）| ifupdown static（格式同 Debian）| `/etc/network/interfaces` |
| **Gentoo** | netifrc dhcp 或 dhcpcd | netifrc static | `/etc/conf.d/net` |

#### Void `network.sh` 伪代码

```bash
configure_network() {
    . /network.env
    # WAN: dhcpcd 自动获取，无需额外配置
    # LAN: 追加到 dhcpcd.conf
    cat >> /etc/dhcpcd.conf << EOF
interface ${LAN_IFACE}
static ip_address=${LAN_IP}/${LAN_NETMASK#255.255.255.}  # TODO: 子网掩码转 CIDR
nogateway
EOF
    _replace_placeholders
}
```

#### Debian/Devuan `network.sh` 伪代码

```bash
configure_network() {
    . /network.env
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto ${WAN_IFACE}
iface ${WAN_IFACE} inet dhcp

auto ${LAN_IFACE}
iface ${LAN_IFACE} inet static
    address ${LAN_IP}
    netmask ${LAN_NETMASK}
EOF
    _replace_placeholders
}
```

#### Alpine `network.sh` 伪代码

```bash
configure_network() {
    . /network.env
    # 安装 udhcpc 包（Alpine 默认只有 busybox udhcpc）
    apk add --no-cache udhcpc 2>/dev/null || true
    # interfaces 格式与 Debian 相同
    # （同上 Debian 逻辑）
    _replace_placeholders
}
```

#### Gentoo `network.sh` 伪代码

```bash
configure_network() {
    . /network.env
    cat > /etc/conf.d/net << EOF
config_${WAN_IFACE}="dhcp"
config_${LAN_IFACE}="${LAN_IP}/${LAN_NETMASK#255.255.255.}"
EOF
    # 创建符号链接激活 netifrc
    ln -s /etc/init.d/net.lo /etc/init.d/net.${LAN_IFACE}
    _replace_placeholders
}
```

#### 通用占位符替换（所有 distro 共用）

```bash
_replace_placeholders() {
    # dnsmasq DHCP 配置
    _TGT="/etc/dnsmasq.d/10-dhcp-eth1.conf"
    [ -f "${_TGT}" ] || _TGT="/etc/dnsmasq.d/10-dhcp-${LAN_IFACE}.conf"
    if [ -f "${_TGT}" ]; then
        sed -i \
            -e "s/__LAN_IFACE__/${LAN_IFACE}/g" \
            -e "s/__LAN_IP__/${LAN_IP}/g" \
            -e "s/__DHCP_RANGE_START__/${DHCP_RANGE_START}/g" \
            -e "s/__DHCP_RANGE_END__/${DHCP_RANGE_END}/g" \
            -e "s/__DHCP_LEASE_TIME__/${DHCP_LEASE_TIME}/g" \
            -e "s/__LAN_NETMASK__/${LAN_NETMASK}/g" \
            -e "s/__LAN_NETWORK__/${LAN_NETWORK}/g" \
            "${_TGT}"
    fi
    # nftables vars
    _NFT="/etc/nftables.d/00-inet-vars.nft"
    if [ -f "${_NFT}" ]; then
        sed -i \
            -e "s/__ROUTER_LAN_IP__/${LAN_IP}/g" \
            -e "s/__LAN_NET__/${LAN_NETWORK}/g" \
            "${_NFT}"
    fi
}
```

---

## 四、修改文件

### 4.1 dnsmasq DHCP 配置（占位符化）

**文件**：`infra/sing-box/config/dnsmasq.d/10-dhcp-eth1.conf`

```diff
- dhcp-range=eth1,192.168.8.100,192.168.8.200,255.255.255.0,12h
+ dhcp-range=__LAN_IFACE__,__DHCP_RANGE_START__,__DHCP_RANGE_END__,__LAN_NETMASK__,__DHCP_LEASE_TIME__

- dhcp-option=eth1,3,192.168.8.1
+ dhcp-option=__LAN_IFACE__,3,__LAN_IP__

- dhcp-option=eth1,6,192.168.8.1
+ dhcp-option=__LAN_IFACE__,6,__LAN_IP__

- dhcp-option=eth1,28,192.168.8.255
+ dhcp-option=__LAN_IFACE__,28,__LAN_NETWORK__

- dhcp-option=eth1,121,0.0.0.0/0,192.168.8.1
+ dhcp-option=__LAN_IFACE__,121,0.0.0.0/0,__LAN_IP__
```

### 4.2 nftables 变量（占位符化）

**文件**：`infra/sing-box/config/nftables.d/00-inet-vars.nft`

```diff
- define ROUTER_LAN_IP = 192.168.8.1
+ define ROUTER_LAN_IP = __ROUTER_LAN_IP__

- define LAN_NET = 192.168.8.0/24
+ define LAN_NET = __LAN_NET__

- define WAN = eth0
+ define WAN = __WAN_IFACE__

- define LAN = eth1
+ define LAN = __LAN_IFACE__
```

### 4.3 5 个 `build.sh`

```diff
+ cp -f "${REPO_ROOT}/network.env" "${ROOTFS}/network.env"
+ cp -f "${SCRIPT_DIR}/network.sh" "${ROOTFS}/network.sh"
```

在"拷贝安装框架到 rootfs"阶段追加。

### 4.4 5 个 `setup.sh`

```diff
  # ============================================================
  #  2. 部署配置文件
  # ============================================================
+ . /network.sh
+ configure_network
```

在"部署配置文件"阶段最开始调用，先于服务启用。

---

## 五、删除文件

| 文件 | 原因 |
|------|------|
| `infra/sing-box/config/network/interfaces` | 由各 distro 的 `network.sh` 动态生成 |

---

## 六、改动影响总览

| 类型 | 文件 | 改动量 |
|------|------|--------|
| 新增 | `network.env` | ~25 行 |
| 新增 | `distros/void/network.sh` | ~35 行 |
| 新增 | `distros/devuan/network.sh` | ~30 行 |
| 新增 | `distros/debian/network.sh` | ~30 行 |
| 新增 | `distros/alpine/network.sh` | ~35 行 |
| 新增 | `distros/gentoo/network.sh` | ~40 行 |
| 修改 | `dnsmasq.d/10-dhcp-eth1.conf` | 7 行替换 |
| 修改 | `nftables.d/00-inet-vars.nft` | 4 行替换 |
| 修改 | 5× `build.sh` | 各 +2 行 |
| 修改 | 5× `setup.sh` | 各 +2 行 |
| 删除 | `network/interfaces` | 1 个文件 |
| **合计** | **15 个文件** | 新增 ~200 行，修改 ~30 行 |

---

## 七、不涉及的部分

以下文件中的 IP 因属于应用配置而非网络拓扑，**暂不纳入本次重构**：

| 文件 | IP | 原因 |
|------|-----|------|
| `sing-box/config.json` 中 `192.168.8.0/24` | tailscale advertise_routes | 应用层配置，由 render 模板管理 |
| `sing-box/config.json` 中 `192.168.8.180` | headscale server | 同上 |

后续可由 Tera 模板渲染管线统一处理。

---

## 八、边界情况

1. **子网掩码转 CIDR**：`255.255.255.0` → `/24`。在 `network.env` 中加 `LAN_CIDR=24` 避免 shell 计算。
2. **Void dhcpcd 接管行为**：dhcpcd 默认接管所有接口，LAN 设为 `nogateway` 避免添加默认路由。
3. **Gentoo netifrc 启动**：netifrc 通过 `/etc/init.d/net.<iface>` 符号链接激活，需在 `service.sh` 中处理或由 `network.sh` 自动创建。
4. **WAN_MODE=pppoe**：暂不实现，保留入口。各 distro 的 PPPoE 配置差异较大（ppp + rp-pppoe vs NetworkManager）。
