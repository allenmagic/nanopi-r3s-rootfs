# 2026-07-31: 服务启动顺序优化与 sing-box 配置修复

## 概述

本次更新主要解决了以下问题：
1. 优化所有发行版的服务启动顺序，确保防火墙在网络服务之前加载
2. 修复 sing-box 配置文件的多个关键问题（死循环风险、DNS 污染、语法错误）
3. 升级 sing-box 版本从 1.13.11 到 1.13.15
4. 修复 Gentoo 发行版的 INFRA 模式逻辑错误

## 一、服务启动顺序优化

### 问题描述
原有的服务启动顺序不合理，nftables 防火墙在 SSH、chrony 等网络服务之后启动，存在安全风险。

### 修改内容
将所有发行版的服务启动顺序统一调整为：
```
nftables → dnsmasq → ssh/chrony → tailscaled/cloudflared → sing-box
```

### 涉及文件
- `distros/debian/service.sh`
- `distros/alpine/service.sh`
- `distros/void/service.sh`
- `distros/devuan/service.sh`
- `distros/gentoo/service.sh`

### 原理
确保防火墙规则在任何网络服务启动前就已经生效，避免短暂的暴露窗口期。

## 二、sing-box 配置修复

### 2.1 代理服务器死循环风险（严重）

**问题描述**：
代理服务器 192.168.8.180 的流量可能命中 `proxy-list` 规则，导致流量回环：
```
192.168.8.180 → sing-box → proxy-list 命中 → ss-out → 192.168.8.180 → ...
```

**修复方案**：
将 `source_ip_cidr` 规则移动到最高优先级（第3位，仅次于 sniff 和 DNS 劫持）：

```json
{
  "source_ip_cidr": ["192.168.8.180/32"],
  "outbound": "direct-out"
}
```

**涉及文件**：`sing-box/sing-box/config.json`

### 2.2 DNS 污染问题

**问题描述**：
Google DNS (8.8.8.8) 在国内会被 GFW 劫持/污染，无法正常查询 proxy-list 中的域名。

**修复方案**：
1. 为 Google DNS 服务器添加 `detour: "ss-out"`，确保 DNS 查询通过代理
2. 添加 DNS 路由规则，让 proxy-list 中的域名使用 Google DNS 解析

```json
"dns": {
  "servers": [
    {
      "type": "udp",
      "tag": "google",
      "server": "8.8.8.8",
      "server_port": 53,
      "detour": "ss-out"
    }
  ],
  "rules": [
    {
      "rule_set": ["proxy-list"],
      "server": "google"
    }
  ]
}
```

**涉及文件**：`sing-box/sing-box/config.json`

### 2.3 DNS 服务器优化

**变更内容**：
- 移除 Cloudflare DNS (1.1.1.1)，因为没有任何规则引用它
- 保留三个 DNS 服务器：
  - `local` (223.5.5.5, 阿里): 国内域名，直连
  - `tencent` (119.29.29.29, 腾讯): 备用国内 DNS，直连
  - `google` (8.8.8.8, Google): proxy-list 域名，通过代理

**涉及文件**：`sing-box/sing-box/config.json`

### 2.4 移除 NTP 配置

**变更内容**：
移除 sing-box 配置中的 NTP 部分，时间同步由系统服务负责（busybox ntpd/chrony）。

**涉及文件**：`sing-box/sing-box/config.json`

### 2.5 proxy_list.json 语法错误

**问题描述**：
缺少两处逗号，导致 JSON 语法错误。

**修复内容**：
在 `"sing-box.sagernet.org"` 和 `"claude.ai"` 后添加逗号。

**涉及文件**：`sing-box/sing-box/rules/proxy_list.json`

## 三、sing-box 版本升级

### 变更内容
将所有发行版的 sing-box 版本从 1.13.11 升级到 1.13.15，以支持 `system_interface` 等新字段。

### 涉及文件
- `distros/debian/package.list`
- `distros/devuan/package.list`
- `distros/gentoo/package.list`

### 下载链接
```
https://github.com/sagernet/sing-box/releases/download/v1.13.15/sing-box-1.13.15-linux-arm64.tar.gz
```

## 四、Gentoo INFRA 逻辑修复

### 问题描述
Gentoo 的 `service.sh` 中，INFRA 模式默认值错误设置为 `sing-box`，且 dnsmasq/tailscale/cloudflared 被放在 sing-box 条件分支中。

### 修复内容
1. 将 INFRA 默认值改为 `base`
2. 将 dnsmasq、tailscale、cloudflared 移动到 base 段（所有模式都需要）

### 涉及文件
- `distros/gentoo/service.sh`

## 五、文档更新

### 更新内容
更新 `sing-box/sing-box/sing-box配置说明.md`，反映以下变更：
1. DNS 三服务器配置与 detour 机制
2. 路由规则顺序调整与死循环防护机制
3. Endpoint 双向特性说明
4. Tailscale 接口命名策略（ts0 vs tailscale0）

### 涉及文件
- `sing-box/sing-box/sing-box配置说明.md`

## 六、配置验证

使用 sing-box 1.13.15 验证配置文件：
```bash
sing-box check -c sing-box/sing-box/config.json
```

验证结果：✅ 通过

## 七、关键技术要点

### 7.1 sing-box Endpoint 的特殊性
Endpoint 是 sing-box 的特殊功能，同时作为 inbound 和 outbound（双向通道），可以在路由规则中直接作为 outbound 引用。

### 7.2 Tailscale 接口命名策略
- sing-box Headscale endpoint: 使用 `ts0` 接口名
- Tailscale 官方服务: 使用 `tailscale0` 接口名
- 两者可以共存，避免冲突

### 7.3 路由策略
当前配置采用"默认直连，白名单代理"策略：
- 默认出口：`direct-out`
- proxy-list 域名：`ss-out`（SOCKS5 代理）
- 广告域名：`block`
- 私网流量：`direct-out`
- Tailscale 网段 (100.64.0.0/10)：`hs-aliyun` endpoint

### 7.4 规则匹配顺序
sing-box 路由规则按顺序匹配，first match wins，因此：
1. 最高优先级：代理服务器源 IP（防死循环）
2. 其次：广告拦截
3. 再次：proxy-list 白名单
4. 最后：兜底直连

## 八、影响范围

### 安全性提升
- ✅ 消除代理服务器死循环风险
- ✅ 防火墙提前加载，减少暴露窗口

### 稳定性提升
- ✅ DNS 污染问题解决，proxy-list 域名可正常解析
- ✅ 语法错误修复，配置文件可正常加载

### 兼容性提升
- ✅ sing-box 版本升级，支持最新特性

## 九、测试建议

1. 验证代理服务器 192.168.8.180 自身流量是否直连
2. 验证 proxy-list 中的域名（如 github.com）是否通过代理访问
3. 验证广告域名是否被拦截
4. 验证防火墙规则在系统启动时是否优先加载
5. 验证 DNS 解析是否正常（特别是 Google DNS 通过代理查询）

## 十、回滚方案

如遇问题，可回退到修改前的版本：
```bash
git log --oneline  # 查看提交历史
git revert <commit-hash>  # 回退指定提交
```

关键配置文件备份建议：
- `sing-box/sing-box/config.json`
- `sing-box/sing-box/rules/proxy_list.json`
- `distros/*/service.sh`
