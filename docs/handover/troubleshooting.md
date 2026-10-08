# 排障手册

**症状 → 根因 → 怎么确认 → 怎么修。**

按症状查。每一条都是这个项目**实际踩过**的坑, 不是假想。

---

## 目录

- [A. 节点连不上](#a-节点连不上)
- [B. 生成/部署阶段就错了](#b-生成部署阶段就错了)
- [C. 校验和门禁](#c-校验和门禁)
- [D. 服务和端口](#d-服务和端口)
- [E. 客户端](#e-客户端)
- [F. Git 与发布](#f-git-与发布)

---

## A. 节点连不上

### A1. 全部 CDN 节点连不上, 直连节点正常

**这是 DNS 问题, 不是 ECH, 不是 Cloudflare, 也不是 nginx。**

典型表现: 面板节点都在, 延迟全 0, **日志里没有任何一条提到 DNS**。

确认:

```bash
# 客户端上直接问实例自己的 DNS 要 type 65 记录
dig +short @127.0.0.1 -p 1053 HTTPS <CDN 域名>
# 返回 0 字节 = 问不到 HTTPS/SVCB 记录 = ECH 拿不到配置
```

根因是客户端 DNS 的两个配置项:

- **`fallback-filter` 存在** → 走 CDN 的域名解析出来是 Cloudflare 的境外 IP,
  geoip 判为非 CN, 查询被改派给 `fallback` 组(`1.0.0.1` / `dns.google`)。
  这两个在国内不可达, **超时后被静默丢弃** —— 丢的不只是 A 记录,
  HTTPS/SVCB (type 65) 一条也没要到。而 Cloudflare 下发的 ECHConfig
  就装在那条记录里。
- **`nameserver` 带 `#PROXY`** → 解析域名要先连代理, 而代理节点地址本身是域名,
  又要解析。循环依赖, mihomo 遇到死锁**不报错**, 同样静默丢弃。

实测对照 (同一批节点, 同一台客户端, 只差这一段):

```
无 fallback-filter   7 / 7 可用
有 fallback-filter   0 / 7 可用
```

`respect-rules: true` 是同一个问题的第三个开关 —— 它也让 DNS 走代理。

**修**: 客户端 DNS 去掉 `fallback` / `fallback-filter`,
主解析 DoH 去掉 `#PROXY`, `respect-rules` 设为 `false`。

> ⚠ **有个陷阱**: 客户端 DNS 有**两个来源**。
> 一是 `src/client.sh` 里生成 `config.yaml` 的 dns 段,
> 二是菜单「16) DNS 管理」→ 套用预设, 走 `src/lib/dns.sh` 的 `dns_preset_client()`。
> **只改一个不够**, 用户在菜单 16 点一下"套用安全默认"就会把问题带回来。
> 默认值错了比默认值缺失更糟 —— 它看起来是对的。

---

### A2. 某协议 + gRPC + TLS 连不上, 但同协议 + gRPC + REALITY 正常

**实测遇到过: Trojan。**

确认办法是**绕过 CDN 直连源站**再测一次 —— 这一步能立刻区分是 CDN 侧还是内核侧:

```bash
# 把产物的 server 改成源站 IP、port 改成 fragment 里的端口, ech-opts 删掉
# 直连能通 = CDN 侧问题; 直连也不通 = 内核侧问题
```

实测结果:

| 节点 | 直连源站 | 走 CDN | 判断 |
|---|---|---|---|
| mTrojan-…-gRPC | **不通** | 不通 | 内核侧 |
| mVLESS-…-gRPC | 731ms ✅ | 不通 | CDN 侧 |
| mVMess-…-gRPC | 851ms ✅ | 221ms ✅ | 正常 |

官方文档列了 Trojan 支持 grpc, 所以**不是"不支持", 是实现层面的问题**。

---

### A3. gRPC 走 CDN 全部不通 —— 先别下结论

**gRPC 走 Cloudflare 是支持的**(实测 VMess-gRPC-CDN 221ms 通)。

被 Cloudflare 边缘拦掉的特征是: **请求根本没到源站**。判据是 nginx access log
里那条路径**一条记录都没有**。

如果日志里有记录且状态码是 200, 说明请求到了、nginx 也转发了 —— 那就不是
Cloudflare 拦的, 得往里面查。

对照查法:

```bash
# 三条路径各查一遍, 对照一条已知能通的
grep "cg0abc123" /home/web/log/nginx/access.log | tail -5 | awk '{print $1, $9}'
# 来源是 162.158.x / 104.22.x = Cloudflare 边缘 (到了)
# 来源是 127.0.0.1 = 本机自测
```

---

### A4. 节点绑不上 / 报 "address already in use"

见 [D1](#d1-端口没有绑上-假的)。

---

### A5. 证书相关连不上

见 [B1](#b1-tls-节点绑不上端口)。

---

## B. 生成/部署阶段就错了

### B1. TLS 节点绑不上端口

**根因: mihomo 的 SAFE_PATHS 限制。**

内核拒绝加载工作目录 `-d` 之外的证书文件。但 **`mihomo -t` (配置测试) 会通过** ——
所以校验显示成功, 实际启动时静默失败。

表现是"生成全绿, 但 13 个 TLS 节点绑不上"。

**最容易踩的坑是这个防护放错了位置。** 本项目踩过一次: 防护写在选证书菜单
**之前**, 菜单里又把 `CRT` 覆盖回原始路径, 防护等于没写。

规则: **任何会写 `CRT` / `KEY` 的代码路径之后, 必须重新执行路径检查。**

---

### B2. `skip-cert-verify` 被写死成 true

即使配置了有效的 Let's Encrypt 证书, 模板里如果写死 `skip-cert-verify: true`,
客户端就永远不校验证书 —— 等于把 TLS 的全部意义丢掉。

本项目 15 处模板命中过这个问题。

正确做法是条件化:

```bash
# 只有自签证书才跳过校验
CERT_SKIP_VERIFY="true"
if [[ "${CERT_IS_SELF:-0}" != "1" ]]; then
    CERT_SKIP_VERIFY="false"
fi
```

---

### B3. 节点名里少了标识

见 [E2](#e2-节点名撞车)。

---

## C. 校验和门禁

### C1. 关卡没过, 但改动看起来是对的

```bash
bash tools/check_all.sh
```

13 项, 全部必须过。这一套门禁存在的唯一理由:

> 本项目的**主导 bug 类型是「两处必须一致, 但没有任何机制保证」**。
> 已经出现过 10+ 次, 每次都是同一副面孔 —— 面板能启动、界面正常、设置能保存,
> 但某个地方悄悄不生效。

单点修复不够 —— 修完这次, 下次改动还会漂。**每修一处, 就配一个机械校验。**

---

### C2. pre-push 钩子缺失或过期

`tools/git-hooks/pre-push` 是版本控制的一部分, 但 git 只认 `.git/hooks/` 下的副本。
换机器 clone 出来是没有的。

```bash
cp tools/git-hooks/pre-push .git/hooks/pre-push && chmod 755 .git/hooks/pre-push
```

这个坑踩过三次: 每次都报 forced update 且**退出码 0**, 看起来像成功。

---

### C3. scrub 报隐私残留

GitHub 仓库是功能性的, 不能带部署信息。这个坑**重犯过** ——
手动跑过一次脱敏, 之后改了代码, 新注释里又把真实 IP 带回来了。

```bash
python3 tools/scrub.py src/xxx.sh    # 修, 不是 --check
```

**常见误报**: 注释里写了自己公网 IP 的片段、或真实域名片段。
改成 `<SERVER_IPV6>` / `<域名>` 这类占位符。

---

## D. 服务和端口

### D1. "端口没有绑上" — 假的

**`systemctl restart` 是异步的。** 命令返回时监听可能还没绑上, 于是立刻去查端口
会得到"没绑上"的错误结论。

```bash
# 重启后最多重试 8 次, 每次 1 秒
for i in $(seq 1 8); do
    <检查监听> && break
    sleep 1
done
```

**配套**: 报"绑不上"时不要另起一个 mihomo 去试 —— 端口本来就被占着,
会得到 `address already in use`, 把真正的错误掩盖掉。
正确做法是读服务日志:

```bash
journalctl -u mihomo -n 50
```

---

### D2. nginx 配置改了但不生效 —— 可能在 Docker 里

本项目的 nginx **跑在 Docker 容器里**。宿主机上 `nginx -T` 看到的是**另一个**
配置文件, 改它没有意义。

```bash
docker exec nginx nginx -T        # 看真实生效的配置
docker exec nginx nginx -s reload # 重载
```

---

## E. 客户端

### E1. 节点名撞车

**症状**: 同一个客户端拉了多台服务器的订阅, 两组节点名**完全一样**
(都是 `mVLESS01-REALITY`)。面板里分不开, **测速时根本不知道测的是哪台**。

原因: 每台服务器都是同一套脚本生成的, 名字必然一致。

解法: **组名同步到组内节点名**。组名是用户自己起的, 已经存在了,
所以复用它而不是再问一次前缀:

```
"两字母-自建节点"  →  两字母-mVLESS01-REALITY
"另一台 生产"   →  另一台-mVLESS01-REALITY
```

只改 provider 文件里的 `proxies[].name` —— 客户端 `config.yaml` 里所有组都是
`use: <provider>` 引用, **没有一处按节点名引用**, 所以不会产生悬空引用。

⚠ **更新订阅会重新下载覆盖文件**, 所以更新后必须重新应用前缀。
不补的话用户刚更新完, 不会再去怀疑名字又变回去了。要求幂等(不重复加前缀)。

---

### E2. 订阅更新逻辑走错分支

订阅有两种类型: `http` (手动更新) 和 `http-auto` (自动更新)。
**客户端的默认值是「自动更新 = 不更新」**。

自动更新的节点 `interval` 字段会被内核处理, 只能靠「更新配置」手动拉 ——
所以给用户的选项文案要写清楚。

---

### E3. 交互式菜单输入错位

`timeout N script -qec "bash src/server.sh" /dev/null < /tmp/i.txt` 驱动菜单时,
**启动需要约 8 秒**, 输入太早会被吞掉。

另外: 菜单项编号**不能凭印象**。本项目「全协议一键生成」是添加节点里的**第 10 项**,
不是第 7 项(第 7 项是 VMess)。改动菜单后要用 `tools/check_menu_ids.sh` 校验。

---

## F. Git 与发布

### F1. 两个地方都要推

```bash
git push origin HEAD:refs/heads/refactor/v2
git push origin HEAD:refs/heads/main
```

### F2. 推送会自动 bump 版本号

pre-push 钩子会自动更新 `src/VERSION` 并生成一个提交。
所以推 `main` 之前**先推一次 `refactor/v2`** 让钩子跑完。

### F3. 长任务会被 SSH 断开

SSH 连接会因为空闲/超时被掐断, 长脚本会跟着死。
**在远端后台跑, 轮询日志**:

```bash
setsid nohup bash -c '...' > /tmp/run.log 2>&1 < /dev/null &
# 之后轮询 tail /tmp/run.log
```

---

## 附: 一条通用的排障顺序

遇到"连不上", 按这个顺序缩小范围, **每一步都问, 不要假设**:

1. **请求到哪了?** nginx access log 有没有记录?
   - 没有 → 客户端没发出去, 或 CDN 边缘拦了
   - 有, 来源是 162.158.x / 104.22.x → 过了 Cloudflare
2. **DNS 要到东西了吗?** `dig +short @127.0.0.1 -p 1053 HTTPS <域名>`
   - 0 字节 → 查客户端 DNS 配置 (见 A1)
3. **源站转发了吗?** nginx 的 upstream 状态码
   - `connect() failed` → 端口/服务没起来 (见 D1)
   - 200 → 继续往下
4. **内核那边呢?** `journalctl -u mihomo -n 50`
5. **客户端能直连源站吗?** 绕开 CDN 直连测一次 —— 这一步能一刀切开
   "CDN 侧" 和 "内核侧" (见 A2)