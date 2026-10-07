# 协议支持矩阵

> 生成日期: 2026-10-07
>
> **数据来源**: 全部从代码取出 (`src/conf/all.sh` 的 `gen` 注册表 + 各协议脚本的
> `ask_*` 交互函数), 不是凭印象写的。改代码后请同步更新本文件。

---

## 一、一键全协议脚本 (all.sh) 实际生成的组合

`bash src/conf/all.sh --quick` 默认生成 **22 个档位** (含 7 个 CDN 档位)。

### 已剔除的过时组合

| 档位 | 内容 | 剔除理由 |
|------|------|---------|
| ~~VLESS+WS~~ | 无 TLS / 无 REALITY | **明文握手**, 被动 DPI 直接识别; 协议与 TLS 版相同, 唯一区别就是不加密 |
| ~~VLESS+xHTTP~~ | 同上 | 同上 |
| ~~VMess+WS~~ | 同上 | 同上 |

"贵在精"而不是"贵在多": 这 3 个**没有任何优势**, 协议相同只少了加密,
属于自报家门。删掉后**没有证书时依然有 5 个 REALITY 档位 + SS + Snell 可用**,
不缺入口。剩下的 22 档每一个都带真实加密或 REALITY 抗识别。
**协议 × 传输 × 伪装** 的实际组合如下:

| # | 档位 id | 中文名 | 协议 | 传输 | 安全层 | 端口 |
|---|---------|--------|------|------|--------|------|
| 1 | `reality` | VLESS+Reality | VLESS | TCP | REALITY | 20000 |
| 2 | `reality-grpc` | VLESS+gRPC+Reality | VLESS | gRPC | REALITY | 20002 |
| 3 | `reality-xhttp` | VLESS+xHTTP+Reality | VLESS | xHTTP | REALITY | 20003 |
| 4 | `trojan` | Trojan+Reality | Trojan | TCP | REALITY | 20004 |
| 5 | `trojan-grpc` | Trojan+gRPC+Reality | Trojan | gRPC | REALITY | 20005 |
| 6 | `vmess-reality` | VMess+TCP+Reality | VMess | TCP | REALITY | 20008 |
| 7 | `vmess-grpc` | VMess+gRPC+Reality | VMess | gRPC | REALITY | 20017 |
| 8 | `trojan-tls` | Trojan+TLS | Trojan | TCP | 真证书 TLS | 20018 |
| 9 | `vless-ws` | VLESS+WS+TLS | VLESS | WS | 真证书 TLS | 20019 |
| 10 | `xhttp-tls` | VLESS+XHTTP+TLS | VLESS | xHTTP | 真证书 TLS | 20020 |
| 11 | `xhttp-cdn` | VLESS+XHTTP+CDN | VLESS | xHTTP | **Cloudflare + ECH** | 20021 |
| 12 | `vless` | VLESS+WS | VLESS | WS | 裸 (无 TLS) | 20022 |
| 13 | `xhttp` | VLESS+XHTTP | VLESS | xHTTP | 裸 (无 TLS) | 20023 |
| 14 | `vmess` | VMess+WS | VMess | WS | 裸 (无 TLS) | 20024 |
| 15 | `hysteria2` | Hysteria2 | Hysteria2 | QUIC/UDP | TLS | 20031 |
| 16 | `tuicv5` | TUIC v5 | TUIC v5 | QUIC/UDP | TLS | 20032 |
| 17 | `anytls` | AnyTLS | AnyTLS | TCP | TLS | 20033 |
| 18 | `ss` | Shadowsocks | SS | — | — | 20034 |
| 19 | `snell` | Snell | Snell | TCP | — | 20035 |
| 20 | `cdn-v-ws` | CDN: VLESS+WS | VLESS | WS | Cloudflare + ECH | 边缘 443 |
| 21 | `cdn-v-grpc` | CDN: VLESS+gRPC | VLESS | gRPC | Cloudflare + ECH | 边缘 443 |
| 22 | `cdn-m-ws` | CDN: VMess+WS | VMess | WS | Cloudflare + ECH | 边缘 443 |
| 23 | `cdn-m-grpc` | CDN: VMess+gRPC | VMess | gRPC | Cloudflare + ECH | 边缘 443 |
| 24 | `cdn-t-ws` | CDN: Trojan+WS | Trojan | WS | Cloudflare + ECH | 边缘 443 |
| 25 | `cdn-t-grpc` | CDN: Trojan+gRPC | Trojan | gRPC | Cloudflare + ECH | 边缘 443 |

第 20–25 行连的是 **CDN 边缘 443**, 不是源站端口 (源站端口由 Cloudflare 的
Origin Rule 指向, 不出现在客户端配置里)。

### CDN 档位 (7 个, 全部默认生成)

**为什么一次生成 7 个而不是 1 个**: Cloudflare 边缘看到的是你的**流量形态**。
只用一种传输, 特征单一; 把 ws / gRPC / xHTTP 混着用, 同一批节点对外表现是异构的,
更难被聚类识别。

| # | 档位 id | 协议 | 传输 | nginx 回源方式 |
|---|---------|------|------|---------------|
| 1 | `xhttp-cdn` | VLESS | xHTTP | `grpc_pass` (xHTTP 必须用, 见下) |
| 2 | `cdn-v-ws` | VLESS | WS | `proxy_pass` + Upgrade |
| 3 | `cdn-v-grpc` | VLESS | gRPC | `grpc_pass` |
| 4 | `cdn-m-ws` | VMess | WS | `proxy_pass` + Upgrade |
| 5 | `cdn-m-grpc` | VMess | gRPC | `grpc_pass` |
| 6 | `cdn-t-ws` | Trojan | WS | `proxy_pass` + Upgrade |
| 7 | `cdn-t-grpc` | Trojan | gRPC | `grpc_pass` |

**为什么只有这 3 个协议能走 CDN**: Cloudflare 橙云代理的是 **HTTP 流**。
只有把协议包进 HTTP 承载 (ws / gRPC / xHTTP) 才过得去。REALITY / AnyTLS /
Hysteria2 / TUIC / SS / Snell 都是裸 TCP 或 UDP, Cloudflare 根本不转发 ——
症状同样是"节点在订阅里, 但连不上"。

**为什么 VMess / Trojan 没有 xHTTP 档位**: 不是漏写, 是**内核不支持**。
xHTTP 的 listener 字段是 `xhttp-config`, 而它只存在于 **vless** 的 listener 模式里
(`validate.py` 的 LISTENER / vless 分支才有)。写给 vmess/trojan 会被**静默忽略** —
listener 退化成裸 TCP, 客户端却按 xHTTP 连, 必然失败。
所以 CDN 组合是 **3+2+2 = 7**, 而不是理论上的 9。

**对比 sing-box**: 它是 3 协议 × {ws, grpc} = **6** 个。我们多一个 VLESS+xHTTP。

CDN 档位还有两条硬约束:
- **必须真证书**: Cloudflare 回源时不认自签 CA。自签必然回源失败,
  症状是"CDN 侧全绿、客户端连不上", 极难排查 —— 所以 `all.sh` 在生成前就拦。
- **客户端连的是边缘 443**, 不是源站端口。源站端口只出现在 listener 里, 供配 Origin Rule。

### 可选档位 (默认不生成)

| 档位 id | 中文名 | 开启方式 | 为什么默认关 |
|---------|--------|---------|--------------|
| `vmess-mkcp` | VMess+mKCP | `ALL_MKCP=1` | **实测会把客户端拖死** (见下) |
| `vmess-mekya` | VMess+Mekya | `ALL_MKCP=1` | 同上; 生态更小 |

`--only vmess-mkcp` 可单独点名生成, 不需要改默认集。

### ⚠ mKCP 默认关闭的原因 (实测, 不是保守起见)

客户端一旦选中 mKCP 节点:
- 端口仍在监听 (7890/9090/1053 都能连)
- 但**代理不再出网**
- `sshd` 因 CPU 被吃光而**起不来** (TCP 能建连, 但 SSH banner 永远超时)
- **只能物理重启恢复**

mKCP 把 UDP 跑在 TCP 之上再自己管重传/拥塞, 在 `congestion: false` 时自旋倾向明显;
且它是传输层重实现, 各版本内核行为不一致。

---

## 二、各协议的可配置项 (独立交互脚本)

一键脚本只出"标准档位"。想要下面的细粒度配置, 用**独立脚本**:

```bash
bash src/conf/hysteria2.sh   # 交互式, 逐项提问
bash src/conf/TUIC.sh
bash src/conf/AnyTLS.sh
bash src/conf/Reality.sh
bash src/conf/Trojan.sh
bash src/conf/VLESS.sh
```

### Hysteria2 (`src/conf/hysteria2.sh`)

| 配置项 | 取值 | 说明 |
|--------|------|------|
| **obfs 混淆** | 关闭 / `salamander` / `gecko` | 抗主动探测。**salamander 是官方标准, 推荐** |
| obfs-password | 自定义 | ⚠ 有 obfs 无密码 → **硬报错**; 只给密码不给 obfs → **静默忽略** |
| obfs-min/max-packet-size | 数值 | ⚠ **仅 gecko 生效**, 配 salamander 静默无效 |
| **端口跳跃** | 见下 | UDP 抗封锁 |
| masquerade | 字符串 | 伪装站点 |
| up / down | Mbps 或 Brutal | 带宽 |

**端口跳跃三选一**:

| 模式 | 作用范围 | 特点 |
|------|---------|------|
| 1) 内核原生 `ports` + `hop-interval` | **仅客户端** | 不动防火墙, **重启不失效** ✅ 推荐 |
| 2) iptables DNAT | 服务端 | 改防火墙, **重启后需重加** |
| 3) 不开启 | — | — |

### TUIC v5 (`src/conf/TUIC.sh`)

| 配置项 | 取值 |
|--------|------|
| **拥塞控制** `congestion-controller` | `bbr`(默认, 也是内核 listener 默认) / `bbr_meta_v2` / `cubic` / `new_reno` |
| `udp-relay-mode` | `native`(默认, UDP 直传) / `quic`(走 QUIC DATAGRAM) |

⚠ **拥塞控制两侧必须一致**, 否则连不通。
⚠ `udp-relay-mode` **仅客户端**, 写错字会静默落回 `native`。

### AnyTLS (`src/conf/AnyTLS.sh`)

| 配置项 | 取值 | 说明 |
|--------|------|------|
| **padding-scheme** 抗主动探测填充 | 服务端选配 | ⚠ **只有 listener 能配**; 客户端走内置默认, 真实方案由服务端协议帧下发 |
| client-fingerprint | chrome / … | — |
| idle-session | 数值 | — |
| **smux 档位** | 网页党 / 视频党 / … | 见下 |

### REALITY (`src/conf/Reality.sh`)

| 配置项 | 取值 | 说明 |
|--------|------|------|
| client-fingerprint | chrome / firefox / safari | 拟真浏览器指纹 |
| **UDP 封装** `pkt-mode` | `xudp`(默认) / `packet-addr` / 不写 | **同时写时 xudp 优先** |
| features | — | — |

### Trojan (`src/conf/Trojan.sh`)

| 模式 | 可选传输 |
|------|---------|
| **Reality** | `tcp`(默认) / `grpc` (内核已接通 reality+grpc) |
| **纯 TLS** | `tcp`(默认, 裸 TCP+TLS) / `ws`(**可套 CDN**) / `grpc`(h2 多路复用) |

另有 `skip-cert-verify`、`client-fingerprint`。

### VLESS (`src/conf/VLESS.sh`)

| 配置项 | 说明 |
|--------|------|
| xhttp level | xHTTP 档位 |
| client-fingerprint | 拟真指纹 |
| **ECH** | `-E <域名>` 开启。需 Cloudflare (REALITY 互斥) |
| mTLS | 客户端证书认证 (与 ECH 冲突, 开 ECH 时自动跳过) |
| Brutal | 硬顶吞吐, 速率不匹配会静默变 0 |

### smux (多路复用)

支持脚本: `VLESS.sh` / `Reality.sh` / `Trojan.sh` / `AnyTLS.sh` / `TUIC.sh`
档位按用途分: **网页党**(复用最大化, 轻量) / **视频党**(并行承载)。

---

## 三、内核支持 vs 项目生成 (缺口一览)

| 传输层 | 内核支持 | 项目生成 |
|--------|:-------:|---------|
| ws | ✅ | ✅ |
| grpc | ✅ | ✅ |
| xhttp | ✅ | ✅ |
| h2 | ✅ | ⚠️ 有 schema, **无生成入口** |
| **mkcp** | ✅ | ⚠️ 生成器有, **默认关闭** |
| **mekya** | ✅ | ⚠️ 生成器有, **默认关闭** |
| httpupgrade | ✅ | ✅ (CDN 档) |
| smux | ✅ | ✅ (5 个脚本) |

**⚠ 探测方法的坑 (记录下来免得再踩)**:
`mihomo -t` **不校验** `network:` 枚举 —— `network: bogusproto` 同样能通过。
所以"档位生成成功 + `-t` 通过"**证明不了**传输合法。
正确判据是对内核二进制做子串查找 (`strings <bin> | grep -c <标识>`)。

---

## 四、协议覆盖统计

| 类别 | 数量 | 明细 |
|------|:----:|------|
| 协议种类 | 9 | VLESS / VMess / Trojan / Hysteria2 / TUIC / AnyTLS / SS / Snell / (mihomo 另支持 Hysteria1·ShadowTLS·SSH·WireGuard·Mieru 等, 项目未生成) |
| 一键档位 | **22** | 见第一节 (含 7 个 CDN 档位) |
| 可选档位 | 2 | mKCP / Mekya |
| 传输层 | 8 | ws / grpc / xhttp / h2 / tcp / mkcp / mekya / httpupgrade |
| 安全层 | 4 | REALITY / 真证书 TLS / Cloudflare+ECH / 裸 |
| 过 CDN 的 | **7** | 见上表 |

---

## 五、当前状态 (2026-10-07 实测)

- 服务端: **22/22 档位生成成功**, 0 警告, 严格校验通过, `mihomo -t` 通过, 服务 active
- 客户端: **22/22 节点连通**, 其中 **CDN 档 7/7 全通**
- 双端证据链: <CLIENT_ALIAS> 无直连 → 经代理出口 = <SERVER_ALIAS> 同目标出口 ✅, DNS 返回 fake-ip `198.18.0.4` ✅
- ECH: 抓包带对照组验证 —— 开: 明文 SNI 仅 `cloudflare-ech.com`; 关: 真实域名暴露 ✅
---

## 六、推荐配置 (presets) —— 每个协议菜单开头都有

进入任一协议的交互菜单，**第一件事**就是问「要哪种推荐配置」，**一路回车 = ① 推荐档**。

| 协议 | 预置数 | ① 推荐档 |
|------|:-----:|---------|
| VLESS | 9 | 隐匿优先 · REALITY（裸 TCP + XTLS Vision，抗 DPI 最强） |
| VMess | 6 | 隐匿优先 · REALITY（裸 TCP，无 Web 特征） |
| Trojan | 7 | 隐匿优先 · REALITY |
| AnyTLS | 3 | 自签 + 钉扎（一路回车即可建，无需先备 crt/key） |
| Hysteria2 | 2 | 推荐默认（salamander 混淆 + 内核原生端口跳跃） |
| TUIC | 2 | 推荐默认 · BBR（拥塞控制两侧必须一致） |

CDN 相关档位（VLESS/VMess/Trojan 的 ws / gRPC / xHTTP）全部带 **ECH**。

### 为什么预置里刻意**没有**的组合

| 组合 | 原因 |
|------|------|
| REALITY + WS | 实测 mihomo 0/3~0/5 稳定失败（裸 TCP/gRPC/h2 全通过） |
| AnyTLS + REALITY | 实测 0/5；SB 的表里也注明「仅 sing-box 客户端」 |
| VLESS + h2 | mihomo 的 vless listener 结构性不支持 h2（`listener/sing_vless/server.go`） |

这些是**实测结论**，不是保守起见 —— 写进预置表就是避免用户配出连不上的节点。

### 预置是真生效的，不是只显示菜单

已用「有预置 / 无预置」对照组验证：
- 选 AnyTLS ③（真证书+padding）→ `padding-scheme` 实际写入配置；
  不选预置 → `PADDING_BLOCK` 为空。
- 选 VLESS ③（gRPC）→ 传输被定死为 `grpc`、smux 取 `video`，**不再重复提问**。

实现位置：`src/lib/preset.sh`（预置表 + `preset_ask`/`preset_apply`），
各协议脚本在问特性之前先调 `preset_ask`，消费完再 `preset_reset`。

---

## 七、SOCKS 入站 (服务端面板 · 菜单 19)

协议档位都是**给外面用的**节点；SOCKS 入站是**给自己或内网用**的——
内部跑脚本、让同网段机器借道出网。不需要证书，也不做抗封锁，所以只问三件事：

| 项 | 取值 |
|---|---|
| **监听地址** | `127.0.0.1`(默认, 仅本机) / `0.0.0.0`(所有 IPv4) / `::`(所有 IPv6) / `::1` / 手输 |
| **端口** | 1–65535, 占用预检 (bind 失败会导致**整个服务端起不来**) |
| **账号密码** | 用户名必填; 密码留空则自动生成 |
| UDP | 可选开关 (SOCKS5 UDP ASSOCIATE) |

实测（<SERVER_ALIAS>）：正确凭据出网正常；错误密码拒绝；无凭据拒绝；
监听 `127.0.0.1` 时从公网 IP 连不上。

---

## 八、出站 / 规则集 / 端口转发 (服务端面板 · 菜单 18)

对标 sing-box 的「网络管理」。三项都有，且已实测：

| 功能 | 说明 | 产物 |
|------|------|------|
| **出站管理** | `direct` / `reject` / `socks5` / `http` 上游 | `outbounds` |
| **端口转发** | 本机端口 → 目标地址，tcp/udp | `tunnel` listener |
| **规则集** | 域名/IP → 走哪个出口 | `rule-providers` + `rules` |

### ⚠ 两条踩过的坑（都会「全绿但功能没生效」）

**1. 规则被追加到 `MATCH` 之后 = 死规则**
mihomo 的 `rules` 从上到下匹配、命中即返回，而 `MATCH,xxx` 匹配一切。
新规则原先一律追加到末尾，于是：

```
MATCH,DIRECT               ← 终结匹配
RULE-SET,testset,DIRECT    ← 永远轮不到
```
现象是文件写进了 `config.d`、`validate` 通过、`-t` 通过、重载成功、面板显示
「已生效」——**但那条规则一次都不会生效**，且没有任何报错指向它。
现已改为插入到第一条终止规则之前。

**2. `_extra_dir` 依赖未赋值的 `CONF_DIR`**
原实现 `printf '%s' "$CONF_DIR"`，而 `CONF_DIR` 只有 `conf/all.sh` 和各协议
脚本会赋值，**`server.sh` 从没设过它**。于是从服务端菜单调用时为空串，
片段被写到**文件系统根目录**（`/outbound-01.yaml`、`/pfwd-01.yaml` …）。
上面这三项功能**因此从来没有真正工作过**，直到本轮修复。

`_extra_apply` 现在会先确认片段真的落到 `config.d` 再重载，堵住这类假阳性。
