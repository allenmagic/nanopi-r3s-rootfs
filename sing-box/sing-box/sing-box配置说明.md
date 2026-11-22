# sing-box 配置说明（Alpine / INFRA=sing-box）

本文档对应当前仓库的 `sing-box/sing-box/config.json`。

## 1. 角色划分

```text
dnsmasq        —— 只做 DHCP（port=0，不监听 53）
nftables       —— 防火墙 / NAT / DNS 归口
sing-box       —— DNS 决策 + LAN 流量总控 + 默认直连
podman(yunshu) —— 特定域名的流量处理后端（tun0）
```

- LAN 客户端的 DNS 由 `dns-in`（`direct` inbound，监听 `LAN_IP:53`）接收；
- LAN 数据由 `tun-in`（`singtun0`，`auto_redirect`）接管；
- 只有 `yunshu-domains` 命中的域名会拿到 fake-IP（`198.18.0.0/15`），
  再由 `bridge` 出站送进 yunshu 的 `tun0`；
- 其余流量走 `direct-out`，默认直连。

## 2. DNS

```json
"servers": [
  { "tag": "local",  "type": "udp", "server": "223.5.5.5" },
  { "tag": "yunshu", "type": "udp", "server": "10.251.1.1",
    "detour": "yunshu-dns" }
],
"rules": [
  { "rule_set": ["yunshu-domains"], "server": "yunshu" }
],
"final": "local"
```

- `yunshu-domains` → 问 yunshu 的隧道 DNS（绑定 `tun0`）；
- 其他域名 → 本地 `223.5.5.5`；
- **不会把所有 DNS 都发给 yunshu**。

`10.251.1.1` 是 yunshu 在 `tun0` 上监听的 DNS 地址（不是 loopback）。
`yunshu-dns` 出站必须是 `direct + bind_interface: "tun0"`：`bridge` 只接受 L3，
DNS 是 L4，不能用 `bridge`。

## 3. 域名清单

- 源文件：`/etc/sing-box/rules/yunshu-domains.txt`
- 生成文件：`/etc/sing-box/rules/yunshu-domains.json`（sing-box local source rule-set）
- 运维命令：`yunshu-domain {list|add|del|render|apply}`

构建期和 sing-box 启动前都会从 txt 重新生成 JSON；手工改 txt 后执行：

```sh
yunshu-domain apply
```

清单来自 `yunshu-nix/docs/分流域名清单.txt` 的 2026-09-15 快照；
后续可从容器内 `/var/lib/yunshu/config/<corp>/pa_conf.cache` 自动刷新。

## 4. TUN

```json
{
  "type": "tun",
  "tag": "tun-in",
  "interface_name": "singtun0",
  "address": ["172.19.0.1/30"],
  "auto_route": true,
  "auto_redirect": true,
  "route_exclude_address": ["10.251.1.1/32", "__LAN_NET__"],
  "route_exclude_address_set": ["bypass-cidrs"],
  "include_interface": ["__LAN_IFACE__"]
}
```

- **接口名必须是 `singtun0`**，yunshu 固定占用 `tun0`；
- `auto_redirect` 把 LAN 流量送进 `singtun0`；
- 只排除 `10.251.1.1/32`（sing-box 自己的 tunnel DNS 查询）和 LAN 网段；
  fake-IP 必须进 sing-box，才能由它分给 yunshu。

## 5. 出站

```json
[
  { "type": "direct", "tag": "direct-out" },
  { "type": "direct", "tag": "yunshu-dns", "bind_interface": "tun0" },
  {
    "type": "bridge",
    "tag": "yunshu-bridge",
    "interface": "tun0",
    "bridge_name": "sbbr",
    "iproute2_table_index": 2200,
    "iproute2_rule_index": 500
  }
]
```

`bridge` 需要 **sing-box 1.14+**。Alpine 仓库仍为 1.13.x，因此
`package.list` 直接下载上游 `v1.14.4` 的 arm64 tarball，安装到
`/usr/local/bin/sing-box`。

## 6. 路由

```json
"rules": [
  { "inbound": ["dns-in"], "action": "hijack-dns" },
  { "action": "sniff" },
  { "protocol": "dns", "action": "hijack-dns" },
  { "preferred_by": ["yunshu-bridge"],
    "rule_set": ["yunshu-domains"],
    "action": "route", "outbound": "yunshu-bridge" },
  { "preferred_by": ["yunshu-bridge"],
    "ip_cidr": ["198.18.0.0/15"],
    "action": "route", "outbound": "yunshu-bridge" },
  { "process_path": ["/usr/sbin/tailscaled", "/usr/bin/tailscale"],
    "action": "route", "outbound": "direct-out" },
  { "ip_cidr": ["100.64.0.0/10"],
    "action": "route", "outbound": "hs-aliyun" },
  { "ip_is_private": true, "action": "route", "outbound": "direct-out" },
  { "action": "route", "outbound": "direct-out" }
],
"final": "direct-out"
```

- 域名/ fake-IP → `yunshu-bridge`；
- 其余 → `direct-out`；
- Tailscale endpoint（`hs-aliyun`）和 `100.64.0.0/10` 规则保持原样，后续再调试。

## 7. 与 nftables / 内核的约定

- 内核必须支持 `NF_TABLES`、`NF_TABLES_INET`、`NF_NAT`、`NF_NAT_MASQUERADE`、
  `NFT_NAT`、`NFT_MASQ`、`NFT_CT`、`NFT_FLOW_OFFLOAD`、
  `IP_MULTIPLE_TABLES`、`IPV6_MULTIPLE_TABLES`；
- Podman / netavark 走纯 nftables 后端（`firewall_driver = "nftables"`），
  docker/full 内核模式保留 `NFT_FIB_INET`；
- 不启用 iptables / xtables / `BRIDGE_NETFILTER`；
- nftables 负责：
  - LAN DNS 强制归口到 `LAN_IP:53`；
  - 放行 `LAN ↔ singtun0`、`sbbr* ↔ tun0`、`tun0 ↔ LAN`；
  - 不再放行 `LAN → WAN` 直通（普通流量由 sing-box `direct-out` 发出）。

## 8. 验证

```sh
sing-box check -c /etc/sing-box/config.json
ip -d link show singtun0
ip -d link show tun0
ip route show table 2022
ip rule show | head

dig +short @192.168.8.1 <清单内域名>   # 期望 198.18.x.x
dig +short @192.168.8.1 baidu.com      # 期望真实 IP

tcpdump -ni singtun0 port 443          # 普通流量（direct-out）
tcpdump -ni tun0 port 443              # 清单内 fake-IP 流量（yunshu）
```
