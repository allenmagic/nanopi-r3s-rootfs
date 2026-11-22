# nftables 规则说明

本文档对应当前目录下的：

- `00-inet-vars.nft`
- `10-inet-nat.nft`
- `20-inet-filter.nft`

## 1. 接口变量

| 变量 | 值 | 说明 |
|---|---|---|
| `WAN` | `eth0` | WAN 口 |
| `LAN` | `eth1` | LAN 口 |
| `SB_TUN` | `singtun0` | sing-box 的 TUN |
| `YUNSHU_TUN` | `tun0` | yunshu（podman host 网络）的 TUN |
| `YUNSHU_DNS` | `10.251.1.1` | yunshu 隧道 DNS |
| `WG` | `wg0` | WireGuard |
| `TS` | `{ ts0, tailscale0 }` | Tailscale |

集合：

- `lan_interfaces` / `wan_interfaces` / `vpn_interfaces`
- `tun_interfaces` = `{ singtun0 }`
- `yunshu_interfaces` = `{ tun0 }`
- `wan_mgmt_nets`：WAN 侧管理网段，由 `wan-mgmt` 动态维护
- `flood_blacklist_v4` / `flood_blacklist_v6`
- `flowtable f`：`eth0` + `eth1`

## 2. NAT（`10-inet-nat.nft`）

`prerouting`（dstnat）：

```nft
iifname @lan_interfaces udp dport 53 redirect to :53;
iifname @lan_interfaces tcp dport 53 redirect to :53;
```

- LAN 客户端自带 DNS 也强制归口到 sing-box 的 `dns-in`；
- `dns-in` 监听 `LAN_IP:53`。

`postrouting`（srcnat）：

```nft
meta nfproto ipv4 oifname @wan_interfaces masquerade;
meta nfproto ipv4 iifname @vpn_interfaces oifname @lan_interfaces masquerade;
```

- WAN 口统一 masquerade；
- VPN 访问 LAN 时 masquerade；
- LAN → `singtun0` / `tun0` **不做** SNAT，yunshu 需要看到真实 LAN 源地址。

## 3. INPUT（发往路由器本机）

默认 `drop`。主要放行：

- `lo`、`established,related`
- WAN 的 WireGuard/Tailscale UDP 握手、受限 ICMP/ICMPv6
- LAN / TUN / VPN / WAN 同网段的 SSH
- LAN DHCP
- LAN / TUN 的 53（sing-box `dns-in`）
- 来自 yunshu `tun0` 的 `10.251.1.1:53` 回包
- LAN / TUN 的 ICMP
- `vpn_interfaces` / `tun_interfaces` / `lan_interfaces` 的整段放行

未命中的流量限速记录 `INPUT_DROP` 后丢弃。

## 4. FORWARD（转发）

默认 `drop`。关键规则：

| 方向 | 说明 |
|---|---|
| `LAN -> @tun_interfaces` | LAN 流量进入 sing-box（`auto_redirect`） |
| `@tun_interfaces -> WAN` | sing-box 处理后的转发 |
| `@tun_interfaces -> LAN` | 回程 |
| `"sbbr*" -> @yunshu_interfaces` | bridge 内部 TUN 把 fake-IP 转给 yunshu |
| `@yunshu_interfaces -> "sbbr*"` | 回程 |
| `LAN -> @yunshu_interfaces` | sing-box 停机时 fake-IP 直通兜底 |
| `@yunshu_interfaces -> LAN` | 回程 |
| `LAN -> LAN` | 内网互访 |
| `VPN <-> LAN` | VPN 访问内网 |
| `VPN <-> @tun_interfaces` | VPN 流量进入 sing-box |
| `VPN <-> @yunshu_interfaces` | VPN 的 fake-IP 兜底 |
| `VPN -> WAN` | VPN 客户端普通上网 |

**有意不放行 `LAN -> WAN`**：普通 LAN 流量由 sing-box 全量接管，默认
`direct-out` 发出；保留内核直通会形成旁路。

`flow offload @f` 仅对 `eth0`/`eth1` 生效。

## 5. OUTPUT

默认 `accept`；只对 `ct state new` 做限速日志（`OUTPUT_NEW`）。

## 6. 与 sing-box / yunshu 的对应关系

```text
LAN DNS  ──► nft redirect :53 ──► sing-box dns-in
LAN 数据 ──► auto_redirect  ──► singtun0 ──► route rules
fake-IP  ──► yunshu-bridge  ──► sbbr* ──► tun0 ──► yunshu
普通数据 ──► direct-out     ──► WAN
```

- `singtun0` 与 `tun0` 必须同时存在且名字不同；
- `bridge` 出站创建 `sbbr*`，nftables 用 `iifname "sbbr*"` 放行；
- 内核需支持 `NF_TABLES` / `NF_NAT` / `NFT_NAT` / `NFT_MASQ` / `NFT_CT` /
  `NFT_FLOW_OFFLOAD` / `IP_MULTIPLE_TABLES`；不启用 iptables/xtables。
