# Landscape Router 集成

`INFRA=landscape` 的落地实现记录。目前只接了 Alpine（OpenRC），其余发行版待做。

## 目录布局

程序 / 状态 / 日志分在三棵树，避免默认的 `/root/.landscape-router`（hidden、`/root` 权限 700、
和 OS 用户配置混在一起）：

| 路径 | 内容 |
|------|------|
| `/usr/local/bin/landscape-webserver` | 二进制（上游 `-static` musl 产物） |
| `/usr/share/landscape-router/static/` | 前端资源（`static.zip`） |
| `/var/lib/landscape-router/` | home：`landscape_init.toml` + `landscape_db.sqlite` |
| `/var/log/landscape-router/` | 日志 |

这样分是因为前端资源是**版本锁定的程序数据**（必须与二进制同版本），不该混进要备份的状态目录；
`/var/lib` 里只剩一个小 db。

启动参数（`landscape/init/openrc/landscape-router`）：

```
landscape-webserver --config-dir /var/lib/landscape-router \
                    --web /usr/share/landscape-router/static \
                    --log_path /var/log/landscape-router
```

`--config-dir`（`-c`，环境变量 `LANDSCAPE_CONF_PATH`）是 home 的总开关：`web_root`、`logs`、
`db_url` 的默认值全由它派生，只给这一个参数就能整体搬家。

## 构建期生成 landscape_init.toml

上游 `landscape-webserver config` 子命令是**明确给部署工具用的稳定接口**，源码注释：

> This is a stable, public interface. Deployment tooling should depend only on these flags,
> never on the on-disk `landscape_init.toml` layout.

所以不手写 TOML，而是下载完二进制后直接用**同一个二进制**生成（产物带版本号，只能被同版本导入）。
`landscape/install.sh` 的 `_ls_init_conf()` 从 `/network.env` 读拓扑：

```
--wan-iface eth0 --wan-mode dhcp \
--lan-iface br_lan --lan-ip 192.168.8.1/24 --lan-member eth1 \
--lan-dhcp-range 192.168.8.100-192.168.8.200 --lan-dhcp-lease 43200 \
--enable nat,firewall,route-wan,route-lan
```

landscape 的 LAN 是**网桥**：`br_lan` 由它创建，`eth1` 作为成员挂上去（`network.env` 里的
`LAN_BRIDGE`）。

`config` 子命令不碰数据库、eBPF 和运行环境（源码里在 init_logger / time sync 之前就 return），
所以构建期跑它不需要 bpffs 和 BTF。

## 与 base 网络栈互斥

landscape 接管 DNS/DHCP/防火墙/路由后，base 那套会和它抢。整段不装、不启用：

| 组件 | 原因 |
|------|------|
| `dnsmasq` | 占住 `:53`，landscape 的 DNS 起不来（上游明确要求先确认 53 空闲） |
| `nftables` | 规则由 landscape 的 eBPF 管 |
| `tailscale` | 改路由 + 写 `resolv.conf`，与 landscape 的 route-wan/lan 冲突 |
| `cloudflared` | 隧道由 landscape 侧接管 |
| `wan-mgmt` / `network-watchdog` | 都要改 WAN 和路由表 |
| `yunshu` | `network_mode: host` + 注入 `198.18.0.0/15` 路由，还会 restart dnsmasq |

前四项在 `package.list` 的 **base-net** 段（landscape 整段跳过）；后三项的 init 脚本仍随
`base/` 部署，但 `service.sh` 在 landscape 模式下不注册。`podman` 保留 —— 它是 landscape
的容器运行时（见下节）。

## 容器运行时：podman 顶替 docker

依据上游 [可使用 Podman 替换 Docker](https://landscape.whileaway.dev/zh/faq/podman.html)：
landscape 通过 `docker.sock` 与容器运行时通信，所以让该路径指向 podman 的 rootful socket 即可。
镜像里**从不安装 docker**，只用 podman。

| 上游（systemd） | 本仓库（Alpine/OpenRC） |
|---|---|
| `systemctl enable --now podman.socket` | `rc-update add podman default` |
| `podman-docker-socket` oneshot：`rm -f` + `ln -s` | `landscape-router` 的 `start_pre()` 里做同样两步 |
| `After=podman.socket` / `Requires=podman.socket` | `depend() { want podman; after localmount podman }` |

`/var/run/docker.sock -> /run/podman/podman.sock`。Alpine 的 `podman` 服务默认就是 rootful
（`/etc/conf.d/podman` 的 `podman_user=root`），`start_pre` 会 `checkpath -d /run/podman`，
`podman system service --time 0` 监听 `/run/podman/podman.sock`。

**与上游的一处有意偏差**：用的是 `want` 而不是 `need`。systemd 那个 `Requires=` 指向的是
`podman.socket`（很轻的 socket 单元），而 Alpine 的 `podman` 服务更重——它的 `start_post` 还会
`podman start --all --filter restart-policy=...`，失败会让服务起不来。用 `need` 等于让容器运行时的
抖动连累整个路由控制面不启动，不划算。`want` + `after` 保住了启动顺序；真晚到了，landscape
的 docker 事件循环每 300 秒重连一次（`landscape/src/docker/mod.rs`）。

ifupdown 也退到只配 `lo`（`network.sh`）——否则它和 landscape 会同时改 eth0/eth1 的地址和路由。
`networking` 服务本身保留，供 lo 和 landscape 的 `need net` 用。

**`lan-mac` 的例外**：RTL8111H 无 EEPROM，不给 MAC 就是每次开机随机。别的 INFRA 靠 ifupdown 的
`pre-up` 触发，landscape 模式下 ifupdown 不碰 eth1，所以改由 `landscape-router` 的 `start_pre()`
调用，赶在它建桥之前。

## bpffs：Alpine 上必须自己挂

上游兼容性表把 Alpine 标成 ❌，真因是 `/sys/fs/bpf` 没挂载（不是 musl 不兼容）：

- systemd 发行版自动挂 bpffs；OpenRC 不会。
- 未挂载时 `/sys/fs/bpf` 只是 sysfs 里的只读占位目录，landscape pin eBPF map 报**奇怪的 ENOENT**。

修法（上游 FAQ）：`/etc/fstab` 加一行 `bpf /sys/fs/bpf bpf defaults 0 0`，由 `localmount` 开机
`mount -a`。`_ls_bpffs()` 写这行，`enable_landscape()` 注册 `localmount`；init 脚本的 `start_pre()`
再兜底 `mount -t bpf` 一次，避免 localmount 没跑时静默失败。

前置条件：内核要有 `CONFIG_BPF_SYSCALL` 且 `/sys/kernel/btf/vmlinux` 存在 —— 即内核仓库的
`--mode full`（eBPF + BTF）。**`INFRA=landscape` 要配 `kernel_mode=full`。**

## 认证

`landscape_init.toml` 里 `[config.auth]` 是空的，凭据只能走 CLI/环境变量
（`--user` / `--pass`，即 `LANDSCAPE_ADMIN_USER` / `LANDSCAPE_ADMIN_PASS`，默认都是 `root`）。

密码写进 `/etc/conf.d/landscape-router`，权限 **0600**（`/etc/init.d/*` 是 0755，不能写密码），
init 脚本 source 后 export。用户名 `admin`，密码取构建期的 `ROOT_PASSWORD`。

## 验证

构建日志里 `[check] landscape:` 段会校验：二进制、`lan-mac`、前端资源、`landscape_init.toml`、
两个服务的 runlevel 注册、conf.d 权限、fstab 的 bpffs 行，以及 **dnsmasq 没有被注册进 default**。

真机侧：

```sh
mount | grep /sys/fs/bpf          # 应有 bpf on /sys/fs/bpf type bpf
ls -l /sys/kernel/btf/vmlinux     # 必须存在（CO-RE 要 BTF）
rc-service landscape-router status
```

Web 管理端 `http://<LAN_IP>:6300`。

## 与原方案的差异

早期设想里有几处和实测不符，已按实际改写：

- ~~`/etc/landscape-router/landscape_init.toml`~~ —— 该文件必须在 **home 目录**里（`--dir` 默认即 home），
  不在 `/etc`。
- ~~`LANDSCAPE_HOME_PATH` 环境变量~~ —— 实际是 `--config-dir` / `LANDSCAPE_CONF_PATH`。
- ~~手写 `landscape_init.toml`（`[system]` / `[web]` / `[store]` 之类字段）~~ —— 真实格式由
  `config` 子命令生成，字段名是 `[config.web]`、`[config.store]`、`[[ifaces]]` 等，不要手写。
- ~~`lib/install-router-software.sh`~~ —— 该文件从未存在，实际契约是各发行版 `setup.sh` 直接
  source `landscape/install.sh` + `landscape/service.sh`。
- `yunshu` 原先不在互斥清单里，实测它注入路由并 restart dnsmasq，必须一并排除。

## 尚未做

- 其余发行版的 landscape 链路（systemd / runit / sysvinit 的服务单元）
- `redirect_pkg_handler`（PPPoE 重定向，当前 WAN 是 dhcp，不需要）
- `WAN_MODE=pppoe`：`_ls_init_conf()` 目前只支持 `dhcp` / `static`，pppoe 需要先在 `network.env`
  里定义账号密码变量
