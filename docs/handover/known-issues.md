# 已知问题

按"要不要现在处理"排序。**已完成修复的也记在这里**, 因为它们的根因是静默的, 很容易重犯。

---

## 待处理

### 1. 切换客户端产物 IP 版本时, IPv6 → IPv4 不生效

`_ca_pick_family` 里算 `oldip=$(m_addr4_real)`, 于是从 IPv6 切到 IPv4 时
那个值本来就等于新的, 结果什么都没改。属于静默失败。

位置: `src/client.sh` 的客户端产物设置。

### 2. 回源域名没有重新探测的菜单项

证书换了 / 域名指向变了之后, 需要重跑一次探测才能更新,
但菜单里没有这个入口, 只能删了重新生成。

### 3. "重命名节点组"改名后, 组内节点名前缀不跟着变

现在节点名前缀是在**添加订阅那一刻**从组名推出来的。
用菜单 7 改名之后, 节点名还是旧前缀。

要做的话: 在 `node_rename` 里同步刷新一次前缀。
注意得先把旧前缀摘掉再加新的。

### 4. 生产服务器的 Cloudflare 配置待人工确认

生产环境上 4 个 CDN 节点曾经连不上。当时的证据:
失败的路径在 nginx access log 里**只有本机自测的 `127.0.0.1` 记录**,
而能通的 `cdnws-*` 有真实 Cloudflare 边缘 IP。

说明**请求压根没到源站**。怀疑是 Cloudflare 的 Origin Rule / WAF 覆盖不全。
**需要登录 Cloudflare 面板 → Security → Events 确认**, 脚本侧无法判断。

> ⚠ 这个结论当时没有最终确认。后来 ECH 的问题修好后这些节点就通了,
> 所以可能是 ECH 导致请求没发出去, 而不是 Cloudflare 拦的。
> 如果再次出现, 先按 [排障手册 A1](troubleshooting.md#a1-全部-cdn-节点连不上直连节点正常)
> 排除 DNS, 再去查 Cloudflare。

---

## 已修复, 但根因值得记住

### ★ 客户端 DNS 让 ECH 整体失效

**影响**: 全部 CDN 节点连不上, 直连节点正常。
**迷惑性**: 日志里没有任何一条指向 DNS。

根因是三个开关: `fallback-filter`、`#PROXY`、`respect-rules`。
详见 [排障手册 A1](troubleshooting.md#a1-全部-cdn-节点连不上直连节点正常)。

> 排查过程中走过的两条弯路:
> 1. nginx 日志显示路径返回 200 → 一度以为 CDN 没问题, 后来把 ECH 判成凶手,
>    **还按"实测连不上"把 CDN 的 ECH 默认关掉了** —— 结论是错的, 已改回开启。
> 2. 路由器 DNS 查 type 65 返回 0 字节 → 一度以为是"解析器不支持",
>    其实只要配置对了用哪个解析器都行, 问题在**谁被选中**。

### ★ CDN 的 gRPC 档位不通

- Trojan + gRPC + TLS: **绕过 Cloudflare 直连源站同样不通** → 内核侧。
  官方文档列了 grpc, 所以不是"不支持"。
- VLESS + gRPC + CDN: 直连通(731ms), 走 CDN 不通 → CDN 侧。
  但 VMess-gRPC-CDN 走 CDN 通(221ms), 说明 Cloudflare 支持 gRPC。

已移出默认档位, `ALL_CDN_GRPC=1` 可开回来。

### ★ 节点名撞车

多台服务器的订阅拉进同一个客户端, 节点名完全一样, **测速时分不清测的是哪台**。
已改为「组名同步到组内节点名」, 见 [排障手册 E1](troubleshooting.md#e1-节点名撞车)。

### ★ 证书 SAFE_PATHS 防护位置错了

防护跑在选证书菜单**之前**, 菜单里又把 `CRT` 覆盖回原始路径, 防护等于没写。
导致 13 个 TLS 节点绑不上。

### ★ `skip-cert-verify` 被写死成 true

15 处模板命中。有有效 Let's Encrypt 证书还跳过校验, 等于把 TLS 的意义丢掉。

### ★ 绑定核对在服务刚重启时就下结论

`systemctl restart` 是异步的, 重启返回时监听还没绑上。已加重试。

### ★ CDN 节点名字里丢了 "CDN"

`m_node_tag` 只读了第 4 个参数, 第 5 个 (`CDN`) 被静默丢弃。
结果 `mVLESS03-TLS-XHTTP`(CDN 节点) 和 `mVLESS02-TLS-XHTTP`(直连节点)
**看起来一模一样**。

> 顺带: `${*// /-}` 在 **zsh 下不替换**, bash 下才替换。
> 改成用 `tr` 更可靠。

---

## 设计上已知的取舍

### VMess / Snell / 无加密 Shadowsocks 不进默认

- VMess 特征明显、主动探测成本低, 而 REALITY 和 TLS 能把同样的需求做得更好
- 实测两个 VMess-CDN 节点连不上, 而同源的 VLESS-CDN 都通
- Shadowsocks / Snell **无加密**, 已有加密协议时明文没有任何存在理由
- Snell 协议本身早已停止维护

生成器全部保留, 用 `ALL_VMESS=1` / `ALL_PLAIN=1` 开回来。
裁剪的依据是"默认值应该是什么", 不是"这个能力有没有用"。

### mKCP / Mekya 默认关闭

实测会让客户端内核**整个卡死**, 端口还在听但不再出网, sshd 都起不来,
只能物理重启。用 `ALL_MKCP=1` 显式开启。

### REALITY 组不排 ws

实测 REALITY + ws 全 0/5。可用的只有 tcp / grpc / xhttp 三种传输。

### 没有 h2 传输

mihomo 的 trojan 出站没有 h2 传输。**不是漏写, 是内核没有。**