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

### ★ 证书复制按 basename 落位, 两个域名互相覆盖

`cert_ensure_safe_path` 原来用 `$(basename "$cert")` 当落位文件名。
而从 `/etc/letsencrypt/live/<域名>/` 取到的 basename **恒为 `fullchain.pem`**:

```
节点1 选 域名A -> conf/certs/fullchain.pem
节点2 选 域名B -> conf/certs/fullchain.pem   ← 同一个文件, 证书+私钥一起被顶掉
```

之后节点1 对外发的是域名B 的证书, SNI 不匹配 → 客户端全部握手失败。
**而 `mihomo -t` 通过、service 是 active、监听一个不少** —— 正是本项目
最常见的那类静默失败。

已改为域名限定落位 (`cert-<域名>.crt` / `key-<域名>.key`), 并在写入前用
SPKI 校验证书与私钥配对, 落位用「临时文件 + 原子改名」。
同一个坑 `xray--core/tools/cert-sync.sh:41-45` 有独立记录。

### ★ `skip-cert-verify` 展开成 `falsetrue`，整个客户端配置加载失败

客户端模板里有 8 处写着：

```bash
skip-cert-verify: ${CERT_TRUSTED:+false}${CERT_TRUSTED:-true}
```

`CERT_TRUSTED=true`（**证书是 CA 签发的真证书**）时它展开成 `falsetrue`。
而内核要求 bool：

```
proxy 0: 'skip-cert-verify' expected type 'bool', got unconvertible type 'string'
configuration file test failed
```

**不是降级，是硬失败** —— mihomo 拒绝加载整个配置。

`CERT_TRUSTED` 为空时它又恰好是对的（`true`），所以这个坑只在
"证书确实可信"时引爆 —— 也就是最该正常工作的那条路径。

> 为什么之前没被发现：批量生成（添加节点 → 10）用的是另一个变量
> `CERT_SKIP_VERIFY`（写对了），所以 `out/` 里的产物一直是好的。
> 只有**单协议向导**（添加节点 → 2 VLESS / 5 TUIC / 6 AnyTLS）才会走到这 8 处。
> 复现方式：沙箱里跑一遍 AnyTLS 的新增向导，产物就是 `falsetrue`。

已修：判断收敛到 `cert.sh` 的 `cert_client_skip_verify()`（唯一真源）。
顺带记下同一件事在项目里原本有**三套写法**：

| 协议 | 原写法 | 结果 |
|---|---|---|
| hysteria2 | `if [[ $CERT_TRUSTED == true ]]` 显式分支 | ✅ 正确 |
| VLESS / TUIC / AnyTLS | `${CERT_TRUSTED:+false}${CERT_TRUSTED:-true}` | ❌ `falsetrue` |
| Trojan | 独立的 `ask_skip_cert_verify()` 交互提问，默认跳过 | ⚠️ 与证书可信度无关 |

Trojan 那套暂时保留：它在 `ask_features()` 里问，而 `ask_cert` 在 `add_config()` 里
—— **问的时候还不知道选的是哪张证书**，要自动推导得先调整次序。

### ★ 三道校验没有一道看证书文件

`合并 / 严格字段 / mihomo -t` 全都不检查配置里引用的证书是否真的存在。实测：

```
certificate 指向不存在的文件      -> "test is successful"
证书文件里塞的是垃圾内容          -> "test is successful"
```

而监听起不来只进日志（内核还会保留上一份有效证书，所以连"服务是活的"
都不能证明它没问题）。

已补：面板「校验配置 + 重载」从三道关变四道关，新增
`3/4 证书落位 (文件在不在 / 私钥配不配)` —— 按配置里**声明的**
certificate/private-key 成对校验，不用命名约定去猜（猜的漏判实测过：
私钥指向不存在的文件、指向另一张证书的私钥，用猜的都报"通过"）。

### ★ 批量生成挑证书：配对靠「位置」凑，配错了还不校验

`all.sh` 的 `find_cert()` 先用文件名把证书和私钥配成对，配不上就退回
「**第 0 张证书 + 第 0 把私钥**」——纯按列表位置取，不看它们是否真是一对。

实测在服务端真实目录上，**按文件名配对 0 命中**，也就是说那条兜底**每次都在走**。
构造一个"字母序第一是孤儿私钥"的目录即可复现：

```
旧逻辑: fullchain.pem  <->  cert-000-privkey.pem      ❌ 两者根本不配对
新逻辑: fullchain.pem  <->  privkey.pem               ✅
```

更麻烦的是第二层：`all.sh` 的落位防护带着 `! cert_path_in_confdir "$CRT"`，
所以证书**已经在 `conf/certs` 里时整段跳过** —— 配对完全不验。
而批量路径的证书多半就是从那儿挑的。

结果：配错的一对写进配置 → 监听起不来（内核只保留上一份有效证书）→
而合并 / 严格字段 / `mihomo -t` 三道关**全绿**。

已修（三处一套）：

1. `find_cert` 的配对改成**公钥指纹真比对**（SPKI），有多张时**优先 CA 签发的真证书**；
   一张都配不上就什么都不输出，退回 `scan_certs`，不再用位置硬凑。
2. 配对校验**前移**：`all.sh` 与 `cert_ensure_safe_path` 都改成
   "不管证书在不在配置目录里都验一次"。
3. `CERT_IS_SELF` 改成**以证书内容为准**（`cert_is_trusted`）。
   原来它只在交互式选证书分支里赋值，`find_cert` 自动选择和 `--quick` 都不进那个分支
   —— 于是自签证书也会写 `skip-cert-verify=false`，客户端直接拒绝连接。

> 顺带说明：`conf/certs` 里那些历史遗留的孤儿副本不能**单独**清理。
> 清掉之后字母序第一会变成一张自签诱饵证书，旧逻辑会把自动选择翻到它身上。
> 三处一起改才成立（同步脚本现在也会维护目录里所有有 LE 出处的副本，
> 不再只管"被节点引用的"）。

### ★ 续期后没人把新证书同步进 conf/certs

第三方保活脚本 (`/root/auto_cert_renewal.sh`) 续签后只 `cp` 到
`/home/web/certs/` 并 reload nginx, **它不碰 `conf/certs`**。
内核也不检查有效期 —— 只有客户端握手时才拒。
于是副本会一直停在旧世代, 直到过期那天所有 TLS 节点一起断。

<SERVER_ALIAS> 上原本有个 `mihomo-hy2-cert-sync.timer` 干这件事, 但它指向的
`sync-hy2-certs.sh` 随清空重装一起消失, 从 2026-10-05 起每晚 `203/EXEC`
失败 (`docs/E2E_VERIFY_REPORT.md:440` 记为"未处理")。

已补 `src/lib/cert_sync.sh`, **从 mihomo 自己的配置反查**要维护哪些证书文件,
域名从证书本体读 —— 不硬编码主域名 (旧实现换一台主域名不同的机器就静默什么都不做)。

它由面板自己保证在位: **选中 LE 证书那一刻**和**每次面板启动**都会幂等地确认一次,
所以不存在"记得去装定时器"这一步。放在 `src/lib/` 而不是 `tools/`, 是因为
install.sh 的更新只把 `$tmp/src/.` 拷到 `$root/src/` —— 放 `tools/` 两条更新路径都覆盖不到,
定时器会一直跑一份再也不会被更新的旧脚本。

> **实测纠正**: 之前认为"续签后必须 restart mihomo 才能加载新证书"。
> 是错的。mihomo 每次握手都重新读证书文件, 换掉文件 **≤1 秒**生效,
> 不需要重启。附带: 证书与私钥不配对时它会**继续发上一份有效证书**,
> 是 fail-safe 的 —— 所以同步写坏文件的后果是"没生效", 不是"打挂服务"。

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