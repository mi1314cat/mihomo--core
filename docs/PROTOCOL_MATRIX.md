# 协议支持矩阵

> 生成日期: 2026-10-07 · 对应提交 `7032bc1`
>
> **数据来源**: 全部从代码取出 (`src/conf/all.sh` 的 `gen` 注册表 + 各协议脚本的
> `ask_*` 交互函数), 不是凭印象写的。改代码后请同步更新本文件。

---

## 一、一键全协议脚本 (all.sh) 实际生成的组合

`bash src/conf/all.sh --quick` 默认生成 **19 个档位**。
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
| 一键档位 | 19 | 见第一节 |
| 可选档位 | 2 | mKCP / Mekya |
| 传输层 | 8 | ws / grpc / xhttp / h2 / tcp / mkcp / mekya / httpupgrade |
| 安全层 | 4 | REALITY / 真证书 TLS / Cloudflare+ECH / 裸 |
| 过 CDN 的 | 2 | `xhttp-cdn`、`vless-ws`(WS 也可套) |

---

## 五、当前状态 (2026-10-07 实测)

- 服务端: **19/19 档位生成成功**, 严格校验通过, `mihomo -t` 通过, 服务 active
- 客户端: **19/19 节点连通** (167–229 ms; CDN 档 1037 ms, 多一跳属正常)
- 双端证据链: <CLIENT_ALIAS> 无直连 → 经代理出口 = <SERVER_ALIAS> 同目标出口 ✅, DNS 返回 fake-ip `198.18.0.4` ✅
- ECH: 抓包带对照组验证 —— 开: 明文 SNI 仅 `cloudflare-ech.com`; 关: 真实域名暴露 ✅