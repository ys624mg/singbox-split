# sing-box-split —— Google / Gemini 定向分流

把 VPS-A 上（本机 + podman 容器）访问 Google / Gemini 的流量送到 VPS-B 的 SOCKS5 出口，
其余流量保持 A 机直连。是原 `dhkZKHiE.sh` 的重构版。

```
                 ┌─────────────── VPS-A (本机, root) ───────────────┐
  podman 容器 ──▶│ nft(prerouting) ─┐                              │
                 │                  ├─▶ sing-box TUN ─┬─ 命中规则 ──┼──▶ SOCKS5 ──▶ VPS-B ──▶ Google
  本机进程   ──▶│ nft(output) ─────┘                  │             │
                 │                                     └─ 未命中 ────┼──▶ 直连（A 机原出口）
                 └──────────────────────────────────────────────────┘
```

## 急速安装 / 卸载（无交互）

全程不问任何问题，SOCKS5 四项直接写进命令：

```bash
# 安装（默认子命令，装完自动体检）
curl -fsSL https://raw.githubusercontent.com/ys624mg/singbox-split/main/deploy.sh -o /tmp/sb.sh && bash /tmp/sb.sh --socks5 1.2.3.4:1080:user:pass

# 安装并跳过体检（最快，约 10 秒）
curl -fsSL https://raw.githubusercontent.com/ys624mg/singbox-split/main/deploy.sh -o /tmp/sb.sh && bash /tmp/sb.sh install --fast --socks5 1.2.3.4:1080:user:pass

# 卸载（无交互，连二进制与规则集一起删）
curl -fsSL https://raw.githubusercontent.com/ys624mg/singbox-split/main/deploy.sh -o /tmp/sb.sh && bash /tmp/sb.sh uninstall --purge
```

`--socks5` 支持三种写法：

| 写法 | 说明 |
|---|---|
| `IP:PORT:USER:PASS` | 推荐，最省事 |
| `USER:PASS@IP:PORT` | 类 URL 写法，密码含 `:` 时更好读 |
| `IP:PORT` | 配合 `--b-user` / `--b-pass` 分开传 |

密码本身含 `:` 时，用 `--b-pass` 单独传（`--socks5` 会按冒号切分）。所有选项都支持 `--opt=value`。

装完后 `sing-box-split` 命令已在 `/usr/local/bin`，后续直接用：

```bash
sing-box-split status                  # 一行式状态
sing-box-split verify                  # 完整体检
sing-box-split verify --container app  # 连带检查容器
sing-box-split update-rules            # 刷新规则集（有变化才重启）
sing-box-split uninstall --purge       # 回滚
```

## 分步安装（需要自定义参数时）

```bash
# 凭据也可走环境变量（之后会存到 /etc/sing-box/proxy.env，重跑无需再传）
B_HOST=1.2.3.4 B_PORT=1080 B_USER=user B_PASS=pass bash deploy.sh

# 或者逐项传
bash deploy.sh --b-host 1.2.3.4 --b-port 1080 --b-user user --b-pass pass \
               --tun-addr 172.31.255.1/30 --log-level info
```

先看效果再落地：

```bash
bash deploy.sh render-config > /tmp/c.json && sing-box check -c /tmp/c.json
bash deploy.sh install --dry-run       # 只渲染 + 校验，不动系统
```

## 与原脚本的关键差异

| # | 原脚本的问题 | 后果 | 本版处理 |
|---|---|---|---|
| 1 | SOCKS5 用户名/密码硬编码在脚本里，脚本托管在匿名临时网盘 | 任何拿到链接的人都获得 B 机凭据 | 改为 env/参数传入，落盘 `/etc/sing-box/proxy.env`（0600），日志只打印 `user@host:port` |
| 2 | 从 `ghfast.top` 镜像下载二进制且**不校验**，以 root 安装 | 镜像方可植入任意代码 | 用 GitHub API 的 `digest` 字段取官方 sha256 强校验；无校验值时拒绝走镜像 |
| 3 | `dns-direct` 用 `8.8.8.8` UDP 作**直连流量的解析器** | 所有非 Google 域名都依赖"能直连 Google"——而这恰恰是被代理的对象；明文 UDP 还可被投毒 | 从 `/etc/resolv.conf`（含 `systemd-resolved` 的真实上游）自动探测本地解析器，`--dns-local` 可覆盖 |
| 4 | 为解析 `dns.google` 额外加了一级 `1.1.1.1` bootstrap | 多一个故障点，1.1.1.1 不通则 Google 分流全挂 | 直接用 IP 形式的 DoH：`8.8.8.8` + `tls.server_name=dns.google`，零 bootstrap |
| 5 | 用 `python3` 改 JSON，且 `"geosite-google" not in json.dumps(r)` 做子串匹配 | 精简镜像没 python3 直接失败；子串匹配会误删无关规则 | 纯 bash 生成配置，去掉 python/jq 依赖 |
| 6 | `auto_redirect` 只检查 `nft` 是否存在 | 内核缺 `nfnetlink_queue` 时容器流量静默不被接管，脚本却报成功 | 硬前置检查 `/sys/module/nfnetlink_queue`，不满足直接报错并给出补救方式 |
| 7 | `sysctl --system` 重载全机 sysctl | 连带影响其它服务 | 只 `sysctl -p` 本文件 |
| 8 | 每次执行 `cp config.json config.json.bak.<epoch>` 无上限 | 备份无限堆积 | 保留最近 5 份 |
| 9 | `pkill -x sing-box` 后再 `systemctl enable --now` | 与 systemd 监管竞争，可能双启动/被拉回 | 统一走 `systemctl restart` + 轮询确认 |
| 10 | `ExecReload=/bin/kill -HUP $MAINPID` | sing-box 不支持 SIGHUP 热重载，该行是无效的 | 删除，重启即 `systemctl restart` |
| 11 | 规则集下载失败才回退，但回退逻辑靠字符串匹配删规则 | 回退路径本身可能写坏配置 | 规则集按"魔数 `SRS` + 大小"校验，只保留真正可用的条目，缺失即从配置中剔除 |
| 12 | 本地 `.srs` 永不更新 | 新 Google 域名可能漏分 | `--auto-update` 装每日 timer，内容有变才重启 |
| 13 | 体检里 `grep -o 'edns_client_subnet...'` | 该字段在响应里不存在，这行**永远**输出"查询失败" | 改按 `Answer[].data` 里的 `edns0-client-subnet` 解析 |
| 14 | IPv6 泄漏判断只认 `2001:` 前缀 | `2400:`/`2600:`/`2a00:` 等全局单播全部漏检 | 改为"有 AAAA 且无 v6 默认路由"判定 |
| 15 | 无卸载、无状态、无 dry-run，verify 每次重写一遍 | 出事只能手工拆 | 子命令化：`install/verify/status/update-rules/render-config/uninstall` |
| 16 | 无条件覆盖 `/etc/sing-box/config.json` | 会踩坏机器上已有的 sing-box 部署 | 写入归属标记，非本脚本的配置默认拒绝覆盖，需 `--force` |
| 17 | 没有卸载手段，只能照文档手工拆 | 拆漏 `nft` 表或 sysctl 会导致断网 | `uninstall` 无交互一键拆，并顺带清理**原脚本**的残留（`99-sing-box.conf`、`/root/vps-a-google-via-b`、`inet sing-box` 表、`rp_filter`），拆完自检网卡与默认路由 |

另外两处结构性调整：

- **TUN 网段** 从 `172.18.0.1/30` 改为 `172.31.255.1/30`。`172.18.0.0/16` 是 docker compose 的常用段，容易撞。
- **路由规则** 增加 `ip_cidr` → `direct`（RFC1918 + 链路本地 + CGNAT）。放在域名规则之前，防止 `domain_keyword: gemini` 误伤内网主机名（如 `gemini.corp.local`）。

## 保留了什么

架构没动，因为它是这个场景的合理选择：

- **TUN + `auto_redirect`**：要按域名分流又要覆盖 podman 容器，且不想牺牲 UDP，这是唯一不别扭的方案。TPROXY 需要额外的策略路由且 QUIC 处理更麻烦。
- **`dns_mode: hijack`**（1.14 新增）：比手工写 53 端口劫持规则干净。
- **`final: direct` + `strict_route: false`**：分流的正确姿势，非 Google 流量不受影响。
- **`udp_over_tcp: false`**：Google/Gemini 主要走 TCP，DoH 也是 TCP，不依赖服务端的 UDP ASSOCIATE。

## 前置条件

| 项 | 要求 | 不满足时 |
|---|---|---|
| 架构 | x86_64 / aarch64 / armv7 | 安装前报错 |
| init | systemd | 安装前报错 |
| TUN | `/dev/net/tun` 存在 | 安装前报错（OpenVZ/LXC 常见） |
| nftables | `nft` 命令 | 安装前报错 |
| 内核 | `nfnetlink_queue` 模块 | 安装前报错 |
| sing-box | ≥ 1.14（`dns_mode` 字段） | `sing-box check` 拦截，不会写坏线上配置 |

## 已知限制

1. **ICMP 不走代理**。`ping google.com` 会进 TUN 后被丢弃，TCP/HTTPS 正常。这是 TUN + SOCKS5 的固有边界。
2. **sing-box 成为全机流量的必经路径**。因为 `auto_route` 会接管默认路由，进程崩溃期间（`RestartSec=3s`）全机断网 3 秒左右；配置非法则 sing-box 起不来、TUN 消失、网络自动恢复正常。
3. **`domain_keyword: gemini` 有误伤面**。任何含 `gemini` 的域名都会走代理；内网域名靠前面那条 `ip_cidr → direct` 兜住。
4. **`rp_filter` 被全局放宽为 0**。这是容器 + TUN 非对称路由的通行做法，但在多网卡机器上会削弱源地址校验。介意的话可改成 `net.ipv4.conf.all.rp_filter = 2`（松散模式）。
5. **体检里"是否被送中"是启发式**。靠 `www.google.com` 是否 302 到 `google.com.hk` 判断，最终取决于 B 机 IP 的归属质量，脚本改不了。

## 排障

```bash
journalctl -u sing-box -f                  # 实时日志
sing-box-split verify                      # 分层体检
bash deploy.sh install --log-level debug    # 临时开 debug（记得改回 warn）
nft list ruleset | grep -A20 sing-box       # 确认 auto_redirect 规则
ip rule show; ip route show                 # 策略路由是否正常
```

典型现象对照：

| 现象 | 大概率原因 |
|---|---|
| 本机能上 Google，容器不能 | `nfnetlink_queue` 或 nft 规则没生效 → 看 `nft list ruleset` |
| 本机全部断网 | sing-box 没起来且 TUN 路由残留 → `systemctl status sing-box` |
| Google 能开但跳 `google.com.hk` | B 机 IP 被判定为中国大陆，换 B 机或换 IP |
| 一切正常但很慢 | `dns-local` 探测到了不可达的上游 → `--dns-local 1.1.1.1` 重装 |
| `sing-box check` 报 `dns_mode` 未知 | 版本低于 1.14，用 `--sb-version 1.14.4` |
