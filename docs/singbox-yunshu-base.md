# Alpine sing-box + YunShu 基础网络

本文档描述 `INFRA=sing-box` 在 Alpine 上的基础网络实现。范围和取舍：

- ✅ dnsmasq DHCP、nftables、sing-box DNS/分流、podman yunshu
- ✅ sing-box 全量接管 LAN（`auto_redirect`），默认 `direct-out`
- ✅ 只有 `yunshu-domains` 命中的域名走 yunshu
- ⏸ Tailscale / headscale / WireGuard / Cloudflared 保持现状，后续单独调试
- ❌ 不使用 iptables / xtables / TProxy
- ❌ 不是“所有 DNS 都走 yunshu”

## 数据流

```text
LAN 客户端
  │
  ├─ DHCP ─────────────► dnsmasq (port=0，只做 DHCP)
  │
  ├─ DNS :53 ──────────► nftables redirect（客户端自带 DNS）
  │                      └─► sing-box dns-in (LAN_IP:53)
  │                            ├─ yunshu-domains → 10.251.1.1 (bind tun0)
  │                            └─ 其他 → 223.5.5.5
  │
  └─ 数据 ─────────────► nftables auto_redirect
                         └─► singtun0
                               ├─ yunshu-domains / 198.18.0.0/15 → yunshu-bridge → tun0
                               └─ 其他 → direct-out → WAN
```

## 接口

| 接口 | 归属 | 说明 |
|---|---|---|
| `singtun0` | sing-box | TUN 入站，`auto_route` + `auto_redirect` |
| `tun0` | yunshu | podman host 网络，固定接口名 |
| `sbbr*` | sing-box bridge | bridge 出站内部 TUN，转给 `tun0` |

`sing-box` 与 `yunshu` 都创建 TUN，**必须使用不同接口名**。yunshu 的 headless
payload 固定创建 `tun0`，因此 sing-box 使用 `singtun0`。

## 服务顺序

```text
nftables → dnsmasq(DHCP) → yunshu(podman) → sing-box
```

- `yunshu` 启动时：
  - sing-box 模式不写 `/etc/dnsmasq.d/15-vpn-tunnel-dns.conf`；
  - 等待 `tun0` 出现（最多 60 秒）；
  - 启动 `vpn-routes`，只维护 `198.18.0.0/15 dev tun0` 和 `10.251.1.1/32 dev tun0`。
- `sing-box` 启动前：
  - 从 `yunshu-domains.txt` 重新生成 `yunshu-domains.json`；
  - 执行 `sing-box check`。

## 域名清单

```sh
yunshu-domain list
yunshu-domain add corp.example.com
yunshu-domain del corp.example.com
yunshu-domain apply       # render + check + restart
```

源文件 `/etc/sing-box/rules/yunshu-domains.txt`，生成文件
`/etc/sing-box/rules/yunshu-domains.json`。支持：

- `example.com`
- `*.example.com`
- `*..example.com`
- 不含点的裸关键词 → `domain_keyword`

当前清单来自 `yunshu-nix/docs/分流域名清单.txt`（2026-09-15，360 条）。
后续可从容器状态目录的 `pa_conf.cache` 自动生成。

## 内核要求

`INFRA=sing-box` 建议搭配 `kernel_mode=full`：

- TUN / nftables / NAT / flow offload / policy routing；
- Podman：namespaces、cgroups、overlay、veth、bridge、nftables `NFT_FIB_INET`；
- 纯 nftables，不开 iptables/xtables/BRIDGE_NETFILTER。

详见 `nanopi-r3s-kernel` 的 `docker`/`full` 模式。

## 已知边界

- Docker engine 的默认 iptables 防火墙路径不支持；Podman 必须使用
  `firewall_driver = "nftables"`。
- 客户端如果使用 DoH/DoT 或完全绕过路由器 DNS，域名策略可能被绕过；
  nftables 目前只强制重定向 53 端口。
- fake-IP 的 DNS 缓存跟随 yunshu DNS 的 TTL；如果出现连接异常，先检查
  `sing-box` 日志和 yunshu 隧道状态。
- sing-box 的 `bridge` 出站需要 1.14+。Alpine 仓库为 1.13.x，构建时直接
  下载上游 `v1.14.4`。

## 验收

```sh
sing-box check -c /etc/sing-box/config.json
ip -d link show singtun0
ip -d link show tun0
ip route show table 2022
ip rule show | head

dig +short @192.168.8.1 <清单内域名>   # 198.18.x.x
dig +short @192.168.8.1 baidu.com      # 真实 IP

tcpdump -ni singtun0 port 443
tcpdump -ni tun0 port 443
```
