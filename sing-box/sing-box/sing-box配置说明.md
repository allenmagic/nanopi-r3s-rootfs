# sing-box 配置说明（基于 `config/sing-box/config.json`）

本文档基于当前仓库中的 `config/sing-box/config.json` 整理，重点说明：

- 当前 TUN 接管范围
- 默认直连、白名单代理的路由逻辑
- 流量是否一定经过 `tun0`
- 哪些路径存在“未经过 sing-box 决策”的边界

## 1. 当前配置目标

这份配置的目标不是“全局强制代理”，而是：

1. 由 `tun0` 接管 `LAN=eth1` 进入的流量；
2. 把接管到的流量交给 sing-box 决策；
3. 默认 `direct-out`；
4. 命中白名单规则集 `proxy-list` 的流量走 `ss-out`；
5. 广告类流量走 `block`；
6. 私网和代理服务器自身流量保持直连。

一句话概括：

**当前策略是“默认走直连，白名单走代理”，而不是“默认全代理”。**

## 2. 关键模块

### 2.1 日志

```json
"log": {
  "level": "info",
  "timestamp": true
}
```

- 日志级别为 `info`
- 开启时间戳

### 2.2 DNS

```json
"dns": {
  "servers": [
    { "type": "udp", "tag": "local", "server": "223.5.5.5", "server_port": 53 },
    { "type": "tls", "tag": "google", "server": "8.8.8.8" }
  ],
  "rules": [
    {
      "rule_set": ["adblock-reject", "geosite-ads", "adblock-cnlite"],
      "action": "predefined",
      "rcode": "NXDOMAIN"
    }
  ],
  "final": "local"
}
```

说明：

- 默认 DNS 上游为 `223.5.5.5:53`
- 另有一个 `8.8.8.8` 的 DoT 服务器定义
- 命中广告规则集的域名直接返回 `NXDOMAIN`
- 未命中时使用 `local`

### 2.3 TUN 入站

```json
{
  "type": "tun",
  "tag": "tun-in",
  "interface_name": "tun0",
  "address": ["172.19.0.1/30"],
  "mtu": 1280,
  "auto_route": true,
  "include_interface": ["eth1"],
  "auto_redirect": true,
  "strict_route": false,
  "stack": "system"
}
```

说明：

- 使用 `tun0` 作为透明接管入口
- 只显式接管 `eth1` 进入的流量
- `auto_route` 与 `auto_redirect` 用于自动配置接管路径
- `strict_route: false` 表示当前是“可用优先”，不是“严格防泄露优先”

这里最重要的一点是：

**开启 TUN 不等于系统里所有流量都必然经过 `tun0`。当前配置只明确接管 `eth1`。**

### 2.4 Endpoints

当前定义了以下 endpoint：

- `ts-ep`：Tailscale endpoint
- `wg-aliyun`：系统 WireGuard endpoint
- `wg-singbox`：sing-box 自建 WireGuard endpoint

### 2.5 Outbounds

```json
"outbounds": [
  {
    "type": "shadowsocks",
    "tag": "ss-out"
  },
  {
    "type": "direct",
    "tag": "direct-out"
  },
  {
    "type": "block",
    "tag": "block"
  }
]
```

说明：

- `ss-out`：代理出口
- `direct-out`：直连出口
- `block`：阻断出口

## 3. 当前路由决策逻辑

`route.rules` 的实际行为可以按顺序理解为：

1. `sniff`
   - 尝试识别目标域名/协议，供后续规则匹配

2. `protocol: dns` + `hijack-dns`
   - DNS 请求交给 sing-box 内部 DNS 模块处理

3. 广告规则集命中
   - 走 `block`

4. `source_ip_cidr = 192.168.8.180/32`
   - 走 `direct-out`
   - 这是为了让代理服务器自身不被再次送进代理，避免回环

5. `ip_cidr = 100.64.0.0/10`
   - 走 `ts-ep`

6. `ip_cidr = 10.10.10.0/24`
   - 当前写的是 `wg-ep`

7. `ip_is_private = true`
   - 走 `direct-out`

8. 命中 `proxy-list`
   - 走 `ss-out`

9. 兜底规则
   - 走 `direct-out`

同时 `route.final` 也是：

```json
"final": "direct-out"
```

因此当前模型非常明确：

**默认直连，白名单代理。**

## 4. 流量路径怎么理解

对来自 `LAN=eth1` 的普通客户端流量，可以这样理解：

```text
LAN client
  -> eth1
  -> tun0
  -> sing-box route.rules
  -> direct-out / ss-out / block
```

这意味着：

- 流量先被接到 `tun0`
- 但最终不一定走代理
- 是否代理，取决于 sing-box 规则匹配结果

所以“经过 TUN”和“经过代理”是两件不同的事：

- 经过 `tun0`：表示流量进入 sing-box 决策路径
- 经过 `ss-out`：表示流量最终被代理
- 经过 `direct-out`：表示流量虽然进入过 sing-box，但最终选择直连

## 5. 是否存在未经过 sing-box 决策的旁路

从当前仓库的静态配置看，可以分成两部分判断。

### 5.1 对 `eth1` 的 LAN 转发流量

当前 `nftables` 转发链只显式允许：

- `LAN -> TUN`
- `TUN -> WAN`
- `TUN -> LAN`
- `TS_NET -> TUN`
- `VPN -> LAN`
- `LAN -> VPN`

没有显式的 `LAN -> WAN` 直通规则。

因此对 `eth1` 进来的普通 LAN 客户端流量来说：

- 静态规则层面没有看到明显的 `LAN -> WAN` 绕过路径
- 当前设计更接近“必须先进入 sing-box 决策，再决定直连或代理”

### 5.2 仍然需要注意的边界

以下流量不能简单理解为“必经 `tun0`”：

1. 路由器本机自己发起的流量
   - `include_interface` 只写了 `eth1`
   - 本机服务流量不等同于从 `eth1` 进入的转发流量

2. `wg0` / `ts0` 进入的流量
   - 当前并没有把所有 VPN 入口都声明为 TUN 接管源
   - 这类流量更多依赖 sing-box endpoint 和 nft 转发规则协同处理

3. sing-box 自己发起的出站连接
   - 例如访问上游代理、下载规则集、DNS 查询
   - 这类连接不应再回灌进自身 TUN，而是按自身出站逻辑工作

4. 接管故障或规则异常时的行为
   - 当前 `strict_route = false`
   - 它不是“代理异常宁可断网”的严格防泄露模式

结论是：

**当前更接近“LAN 流量先交给 sing-box 决策”，而不是“系统里所有流量绝对都从 tun 流转”。**

## 6. “默认直连，白名单走代理”是否等于泄露

不等于。

如果你的设计目标就是：

- 默认直连
- 只有命中白名单时才代理

那么 `direct-out` 不是泄露，而是预期行为。

真正需要警惕的是：

- 本应先交给 sing-box 决策的流量，结果绕过了 sing-box
- 本应命中白名单代理的流量，结果没有命中规则而走了直连

前者是“旁路问题”，后者是“规则命中问题”。

## 7. 当前配置中的注意事项

### 7.1 文档与实际配置曾经不一致

旧版说明里写的是“只有 direct/block 两种出站、没有代理节点”，这与当前 `config.json` 不一致。

当前实际已经存在：

- `ss-out`
- `direct-out`
- `block`
- `proxy-list`

### 7.2 `wg-ep` 引用与当前 endpoint 定义不一致

当前路由规则里有一条：

```json
{
  "ip_cidr": ["10.10.10.0/24"],
  "outbound": "wg-ep"
}
```

但当前 `config.json` 中定义的 endpoint tag 是：

- `ts-ep`
- `wg-aliyun`
- `wg-singbox`

并没有 `wg-ep`。

这说明当前配置里存在一个需要进一步确认的点：

- 要么这里是旧 tag 遗留
- 要么应改为现有的 WireGuard endpoint tag

在仓库根目录 `issue.txt` 中也能看到对应启动报错记录。

## 8. 适合当前配置的正确理解

最准确的表述是：

1. `tun0` 用来接管 `eth1` 进入的 LAN 流量；
2. 这些流量会先进入 sing-box；
3. sing-box 再决定走 `direct-out`、`ss-out` 或 `block`；
4. 因此“经过 TUN”不等于“经过代理”；
5. 当前不是全局防泄露模式，而是“默认直连，白名单代理”的分流模式。

## 9. 如果以后要切换到更严格模式

如果未来想改成“未命中白名单也不能直接出 WAN”，才需要进一步考虑：

- 把默认出口从 `direct-out` 改为代理出口
- 或把默认出口改成 `block`
- 同时把 `strict_route` 调整为更严格的模式
- 再配合 nftables 明确禁止任何旁路出口

但这不属于当前配置目标。
