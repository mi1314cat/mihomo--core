# Mihomo 各协议「可选配项」规格文档

> 目标：为 `mihomo--core` 面板补齐「除核心必需字段外，还应该暴露给用户当选配的字段」。
>
> - 内核源码：`/tmp/mihomo-1.19.32/`（v1.19.32，只读）
> - 项目源码：`<repo>/`（只读，本次只新建 `docs/`）
> - 参考内核：sing-box（部分选配已先行实现）
>
> **纪律**：本文每条结论都带 `文件:行号`。找不到证据的一律写「未找到证据」。

---

## 阅读须知：内核解码器的三条硬语义

这三条决定了后面所有的「静默失效」结论，先读。

| 语义 | 证据 | 后果 |
|---|---|---|
| **未知键静默忽略** | `common/structure/structure.go:579` 的 `ErrorUnused` 在全仓库**从未被置位**（`grep -rn ErrorUnused` 只命中这一行注释自身）；`adapter/parser.go:12` / `listener/parse.go:12` 构造 decoder 时都没开该选项 | 写错键名 **不会报错**，`mihomo -t` 也过，节点照常跑但字段根本没生效 |
| **键名大小写不敏感 + `_`→`-` 归一化** | `common/structure/structure.go:522` 用 `strings.EqualFold(mK, fieldName)`；`:22` `DefaultKeyReplacer = strings.NewReplacer("_", "-")` | `CLIENT-FINGERPRINT`、`client_fingerprint`、`client-fingerprint` 都能命中同一个字段 |
| **不带 `,omitempty` 的字段缺失 = 硬报错** | `structure.go:532` 只有在 `!omitempty` 时才记入 `targetValKeysUnused`；`:583-592` 汇总为 `'xxx' has unset fields: ...` 错误 | 反过来，**无 omitempty 的 tag 是事实上的必填项**（如 vmess 的 `alterId`/`cipher`，见 §1.3） |

> ⚠️ 推论：**不能用「`mihomo -t` 过了」来证明某个字段被解析了**。要验证字段是否真被读取，必须读源码，或喂一个**类型不可转换的垃圾值**（例如给 bool 字段写字符串 `xxx`，`WeaklyTypedInput` 也救不回来，会在 `structure.go` 的赋值阶段报错）。

---

## 0. 项目当前基线：每个协议现在实际写了什么

来源：`src/conf/*.sh` 的 heredoc 生成段。下表是**现状**，不含任何建议。

> ⚠️ **快照说明**：本节取自撰写期间的一次原子快照（`cp` 到 `/tmp/*.snapshot.sh`）。当时 `git status` 显示 `VLESS.sh`/`Trojan.sh`/`AnyTLS.sh`/`TUIC.sh`/`Reality.sh`/`hysteria2.sh`/`all.sh` 均为已修改状态（` M`），说明有人在并发改动。行号若对不上请以现场 `grep -n` 为准；**本文 §1-§3 的内核行号不受此影响**（`/tmp/mihomo-1.19.32/` 是只读源码，全程未变）。

### 0.1 VLESS（`src/conf/VLESS.sh`，ws / xhttp 两分支）

服务端 `conf/config.d/*.yaml`（快照 `VLESS.sh:714-728` xhttp / `:738-753` ws）：
```yaml
listeners:
  - name: vless-N
    type: vless
    listen: "$LISTEN_ADDR"
    port: $VLESS_PORT
    users:
      - username: vless-N
        uuid: $UUID
    certificate: $CERT_FILE
    private-key: $KEY_FILE
    ws-path: $WS_PATH          # ws 分支
    xhttp-config:              # xhttp 分支
      mode: $XHTTP_MODE
      path: $XHTTP_PATH
    client-auth-type: RequireAndVerifyClientCert   # 仅 MTLS_ENABLED=true
    client-auth-cert: $MTLS_CA
```

客户端 `out/vless_client-*.yaml`（快照 `VLESS.sh:755-777` xhttp / `:781-800` ws；重建分支 `:949-971` / `:1075-1097`）：
```yaml
proxies:
  - name: vless-N
    type: vless
    server: $CLIENT_HOST
    port: 443
    uuid: $UUID
    servername: $CLIENT_SNI      # ✅ 已修正（见下方说明）
    client-fingerprint: chrome  # 硬编码
    udp: true
    network: ws|xhttp
    tls: true
    skip-cert-verify: true       # 硬编码（B3，共 6 处）
    ws-opts: {path, headers.Host}
    xhttp-opts: {mode, path}
    ech-opts: {enable, query-server-name}   # 仅 ECH_ENABLED
    certificate: | / private-key: |          # 仅 MTLS_ENABLED
    smux: {enabled, protocol, max-connections, min-streams, max-streams}  # 仅 SMUX_PROFILE 非空
```

> 📌 **已修复的 P0 缺陷（记录在案）**：撰写本文期间，`src/conf/VLESS.sh` 被并发修改，6 处 vless 客户端块的 `sni: $CLIENT_SNI` 已全部改为 `servername: $CLIENT_SNI`（快照行 `764, 788, 953, 976, 1085, 1108`）。
> 内核依据不变：vless proxy **只有 `servername`**（`adapter/outbound/vless.go:89`；grep `proxy:"sni"` 全仓只命中 trojan `adapter/outbound/trojan.go:52` / hysteria2 `:53` / tuic `:65` / anytls `:34`），而未知键被静默丢弃（`common/structure/structure.go:566-581`）。
> ⚠️ **这个修复本身证明了两件事**：① `sni` 确实会被无声丢弃；② **不能靠 `mihomo -t` 发现这类问题**。

smux 档位（`render_smux()`，见 `VLESS.sh` `smux_profile()` / `render_smux()`）：

| 档 | max-connections | min-streams | max-streams |
|---|---|---|---|
| web（默认） | 1 | 1 | 32 |
| video | 2 | 2 | 16 |
| download | 4 | 4 | 64 |

### 0.2 Reality（`src/conf/Reality.sh`，快照约 `:243-286`）

服务端：
```yaml
listeners:
  - name: reality-N
    type: vless
    listen: "0.0.0.0"
    port: $REALITY_PORT
    users:
      - uuid: $UUID
        flow: xtls-rprx-vision        # 硬编码
    reality-config:
      dest: $dest_server:443
      private-key: $PRIVATE_KEY
      short-id: [$SHORT_ID]
      server-names: [$dest_server]
```
客户端：
```yaml
proxies:
  - name: Reality-N
    type: vless
    server/port/uuid/network: tcp/tls: true/udp: true
    flow: xtls-rprx-vision
    servername: $dest_server        # ✅ 正确写法
    reality-opts: {public-key, short-id}
    client-fingerprint: chrome
    smux: {...}                     # 可选
    packet-encoding: xudp           # 仅 XUDP_ENABLED  ⚠️ 见陷阱表
```

### 0.3 Trojan（`src/conf/Trojan.sh`，快照约 `:479-556`）

- reality 模式服务端：`users[{username,password}]` + `reality-config{dest,private-key,short-id,server-names}`
- tls 模式服务端：`users[{username,password}]` + `certificate` + `private-key` + 可选 `client-auth-*`
- 客户端：`password` / `sni` / `client-fingerprint: chrome` / `udp: true` / `network: tcp` / `tls: true` / 可选 `reality-opts`、`skip-cert-verify: true`、`certificate`+`private-key`、`smux`

> ⚠️ Trojan **没有 `tls` 字段**（`adapter/outbound/trojan.go` 全文无 `proxy:"tls"`），写 `tls: true` 会被忽略。VLESS 才有（`adapter/outbound/vless.go:65`）。

### 0.4 Hysteria2（`src/conf/hysteria2.sh`，快照 listener `:626-637` + `render_client_yaml()` `:437-457`）

服务端：
```yaml
listeners:
  - name: hysteria2-N
    type: hysteria2
    listen: "$listen_ip"
    port: $port
    users:
      user1: $password          # ← map，不是 list
    masquerade: https://bing.com  # 硬编码
    certificate: $CERT_FILE
    private-key: $KEY_FILE
```
客户端：
```yaml
proxies:
  - name: Hysteria2-N
    type: hysteria2
    server/port/password/sni
    up: "60" ; down: "200"              # 默认 上行 60 / 下行 150~200 (Mbps);
                                        # 可在面板「客户端产物设置 → 6) hysteria2 带宽」改, 用户设过就以用户的为准
    skip-cert-verify: false   或   fingerprint: $CERT_PIN
    alpn: [h3]
```
端口跳跃已实现，但是走 **iptables DNAT**（`hysteria2.sh` 的 `ask_port_hopping()`），**不是** mihomo 原生的 `ports`/`hop-interval` 字段。

### 0.5 TUIC（`src/conf/TUIC.sh`，快照 `:222-253`）

服务端：`type: tuic` + `users{$uuid: $pass}`（map）+ `certificate`/`private-key` + 硬编码 `congestion-controller: bbr` / `max-idle-time: 15000` / `authentication-timeout: 1000` / `alpn: [h3]` / `max-udp-relay-packet-size: 1500`
客户端：`uuid`/`password`/`sni`/`congestion-controller: bbr`/`udp-relay-mode: native`/`skip-cert-verify: true`/`alpn: [h3]`

### 0.6 AnyTLS（`src/conf/AnyTLS.sh`，快照 `:265-297`）

服务端：`type: anytls` + `users{$UUID: $PASSWORD}`（map）+ `certificate`/`private-key` + 可选 `client-auth-*`
客户端：`password`/`sni`/`client-fingerprint: chrome`/`udp: true`/硬编码 `idle-session-check-interval: 30` + `idle-session-timeout: 30`/`skip-cert-verify: true`/`alpn: [h2, http/1.1]` + 可选 mTLS + `smux`

### 0.7 `all.sh` 批量（`src/conf/all.sh`）

| 协议 | 服务端 | 客户端 | 行号 |
|---|---|---|---|
| vmess | `users[uuid, alterId: 0]` + `ws-path` | `uuid` / `alterId: 0` / `cipher: auto` / `network: ws` / `tls: false` / `ws-opts.path` | `:421-447` |
| shadowsocks | `cipher: aes-128-gcm` + `password` + `udp` | 同左 | `:539-559` |
| snell | `psk` + `version: "3"` | `psk` + `version: "3"` | `:563-581` |
| hysteria2 | `users{user1: ...}` + `masquerade` | `password`/`sni`/`skip-cert-verify`/`up`/`down` | `:451-475` |
| tuic / anytls / trojan / vless | 见上 | 见上 | — |

> ⚠️ `all.sh:430,440` 的 `alterId: 0` **不是装饰**。`adapter/outbound/vmess.go:58` 的 tag 是 `proxy:"alterId"`（**无 omitempty**），配合 §0 的解码器语义，proxy 侧不写 `alterId` 会硬报 `has unset fields: alterId`；`cipher`（`vmess.go:60`，同样无 omitempty）同理。所以 vmess proxy 的 S 档必填是 **uuid + alterId + cipher**，不是只有 uuid。

### 0.8 基线小结：现在**完全没碰**的高价值字段

| 领域 | 完全没用到的字段 |
|---|---|
| 填充 | `global-padding`、`authenticated-length`、xhttp `x-padding-*` 全家、anytls `padding-scheme` |
| 混淆 | `obfs`(hy2)、`obfs-password`、ss `plugin`/`plugin-opts`、snell `obfs-opts`、`shadow-tls`、`res-tls`、`jls-config`/`jls-opts` |
| 指纹 | `client-fingerprint` **全部硬编码 `chrome`**；`name-cert-verify`、`ca-fingerprint` 未用；`fingerprint` 仅 hysteria2 用（快照 `hysteria2.sh:452`） |
| 多路复用 | 只有三档 smux 的 `enabled/protocol/max-connections/min-streams/max-streams`；`smux.padding`、`smux.statistic`、`smux.only-tcp`、`brutal-opts`、`listener mux-option` 全未用 |
| 传输层 | ws 的 `max-early-data`/`v2ray-http-upgrade*`；grpc 全部；h2 全部；xhttp 的 `session-*`/`seq-*`/`uplink-*`/`reuse-settings` |
| 其他 | `packet-addr`、`encryption`(vless ML-KEM)、`udp-over-tcp`(ss)、`udp-over-stream`(tuic)、`ports`/`hop-interval`(hy2 原生)、`congestion-controller` 档位选择 |

---
## 1. S / A / B / C / D 分级总表

### 档位定义

| 档位 | 含义 | 判据 |
|---|---|---|
| **S 必选** | 不配就工作不了 | 字段 tag **无 `,omitempty`**，或协议核心身份凭据。**S 档必须两侧成对** |
| **A 强烈建议暴露** | 显著影响抗识别 / 性能 / 稳定性，用户应该能选 | 默认值对生产环境不友好（如 `skip-cert-verify: true`、硬编码 `client-fingerprint: chrome`），或改一个数就明显改变行为 |
| **B 建议暴露** | 有明确场景，按需开启 | 需要外部资源/对端配合（证书、域名、CDN），或需要用户懂协议 |
| **C 可选/实验** | 小众或仍在演进，暴露要谨慎 | 单一实现、协议未定型、内核文档滞后于代码 |
| **D 不要暴露** | 遗留、已废弃、或语义危险 | 全仓零引用 / 已删 / 会静默降级 / 会关闭安全校验 |

---

### 1.1 VLESS

#### proxy 侧（`adapter/outbound/vless.go:58-91`）

| 字段 | 档 | proxy | listener | 源码位置 | 说明 |
|---|---|---|---|---|---|
| `name` | S | ✅ | — | `adapter/outbound/vless.go:60` | 无 omitempty |
| `server` | S | ✅ | — | `:61` | |
| `port` | S | ✅ | — | `:62` | |
| `uuid` | S | ✅ | ✅(在 users) | `:63` / `listener/inbound/vless.go:34` | |
| `flow` | A | ✅ | ✅(在 users) | `:64` / `:35` | 唯一合法值 `xtls-rprx-vision`（`transport/vless/vless.go:15`）；>15 字符静默截断（`:464-465`） |
| `tls` | S | ✅ | — | `:65` | 所有 security mode 强制要求（`:556-558`） |
| `udp` | A | ✅ | — | `:67` | |
| `alpn` | B | ✅ | — | `:66` | VLESS 无默认；h2 强制 `["h2"]`（`:326-328`） |
| `servername` | S* | ✅ | — | `:89` | **VLESS proxy 侧没有 `sni`**；空则回落 ws Host 头（`:179-183`） |
| `client-fingerprint` | **A** | ✅ | — | `:90` | 现在硬编码 `chrome`（快照 `VLESS.sh:765,789,954,977,1086,1109`）；取值全表见 §2.3 |
| `skip-cert-verify` | A | ✅ | — | `:84` | 现在硬编码 `true`（快照 `VLESS.sh:769,793,958,981,1090,1113`，共 6 处），应改为按证书可信度分支 |
| `name-cert-verify` | B | ✅ | — | `:85` | 比 skip-cert-verify 更安全的替代 |
| `fingerprint` | B | ✅ | — | `:86` | 证书 SHA256 pinning |
| `packet-addr` | A | ✅ | — | `:68` | 与 `xudp`/`packet-encoding` 互斥（`:474-485`） |
| `xudp` | A | ✅ | — | `:69` | **默认自动 true**（`:478-481`）；Reality 快照 `:285,391` 显式写 `packet-encoding: xudp` 是 legacy 写法 |
| `packet-encoding` | **D** | ✅ | — | `:70` | legacy 别名，只 `packetaddr`/`packet` 生效；写 `xudp` 落 default 分支 |
| `encryption` | C | ✅ | ✅(对侧 `decryption`) | `:71` / `listener/inbound/vless.go:15` | ML-KEM 768+X25519 混合加密，格式见 `transport/vless/encryption/factory.go:14-59`（客户端）/ `:66-116`（服务端） |
| `network` | S | ✅ | **❌ 无** | `:72` | listener 侧结构性缺失，见 §3 |
| `ech-opts` | A | ✅ | ✅(对侧 `ech-key`) | `:73` / `listener/inbound/vless.go:23` | VLESS.sh 已实现 |
| `reality-opts` | B | ✅ | ✅(对侧 `reality-config`) | `:77` / `listener/inbound/vless.go:28` | Reality.sh 已实现 |
| `shadow-tls-opts` | B | ✅ | ✅(对侧 `shadow-tls`) | `:74` / `listener/inbound/vless.go:25` | |
| `restls-opts` | C | ✅ | ✅(对侧 **`res-tls`**) | `:75` / `listener/inbound/vless.go:26` | 名字完全不同，见 §3 陷阱表 |
| `jls-opts` | C | ✅ | ✅(对侧 `jls-config`) | `:76` / `listener/inbound/vless.go:27` | |
| `ws-opts` | S(用 ws 时) | ✅ | ✅(对侧 `ws-path`) | `:81` / `listener/inbound/vless.go:16` | |
| `xhttp-opts` | S(用 xhttp 时) | ✅ | ✅(对侧 `xhttp-config`) | `:82` / `listener/inbound/vless.go:17` | |
| `grpc-opts` | B | ✅ | ✅(对侧 `grpc-service-name`) | `:80` / `listener/inbound/vless.go:18` | |
| `http-opts` | B | ✅ | **❌ 无** | `:78` / `adapter/outbound/vmess.go:145-149` | listener 不支持 http 传输 |
| `h2-opts` | B | ✅ | **❌ 无** | `:79` / `adapter/outbound/vmess.go:151-154` | 同上 |
| `ws-headers` | **D** | ✅ | — | `:83` | **死字段**，全仓除定义处零引用；用 `ws-opts.headers` |
| `certificate` / `private-key` | B | ✅ | ✅ | `:87-88` / `listener/inbound/vless.go:19-20` | proxy=客户端自签(mTLS)，listener=服务端证书，**同名反义** |

`encryption` 语法（`transport/vless/encryption/factory.go:14-59`）：
- `""` / `"none"` = 不加密（`:14`）
- 否则必须为 `mlkem768x25519plus.<xorMode>.<rtt>[.<padding>.<keys>]` 且段数 ≥4（`:17`）
- `xorMode` ∈ `native` / `xorpub` / `random`（`:19-27`）；`rtt` ∈ `1rtt` / `0rtt`（`:29-35`）
- 长度 <20 的段当 padding，≥20 需 base64 RawURL 且长度 ∈ {X25519PasswordSize, MLKEM768ClientLength}（`:38-51`）
- 非法 → 报错 `invaild vless encryption value`（源码拼写如此，`:59`）

#### listener 侧独有（`listener/inbound/vless.go:12-30`）

| 字段 | 档 | 源码位置 | 说明 |
|---|---|---|---|
| `users` (list) | S | `listener/inbound/vless.go:14` | 必须是 **list**；`[]VlessUser`（`:32-36`），`username` 只是内部标识不是密码（`:33`） |
| `ws-path` | S(用 ws 时) | `:16` | 扁平化，非空即注册 WS 路由（`listener/sing_vless/server.go:167-180`） |
| `xhttp-config` | S(用 xhttp 时) | `:17` | 21 个子字段，见 §2.1.3 |
| `grpc-service-name` | S(用 grpc 时) | `:18` | 扁平化（`sing_vless/server.go:181-199`） |
| `certificate` / `private-key` | S | `:19-20` | **必须同时非空**才生效（`sing_vless/server.go:95-110`） |
| `client-auth-type` | B | `:21` | 枚举 `request`/`require-any`/`verify-if-given`/`require-and-verify`，默认 NoClientCert（`component/ca/auth.go:17-30`）；VLESS.sh 已实现 |
| `client-auth-cert` | B | `:22` | 非空会自动升级为 RequireAndVerify（`sing_vless/server.go:112-116`）；无服务端证书则报错（`:124-126`） |
| `ech-key` | B | `:23` | 仅当 certificate+private-key 同时存在才加载（`sing_vless/server.go:104-109`） |
| `decryption` | C | `:15` | 对侧 `encryption` 的服务端密钥 |
| `allow-insecure` | **D** | `:24` | 无任何 TLS 层时允许明文启动（`sing_vless/server.go:275-277`） |
| `reality-config` | B | `:28` | 以 `private-key` 非空为启用判据（`sing_vless/server.go:131-133`） |
| `mux-option` | A | `:29` | 见 §2.4 |

`reality-config` 子字段（`listener/inbound/reality.go:5-15`）：`dest`(6) / `private-key`(7，**启用判据**，base64 RawURL 须 32 字节 `listener/reality/reality.go:48-54`) / `short-id`(8，**list**，hex ≤8 字节 `:62-72`) / `server-names`(9，list `:45-47`) / `max-time-difference`(10，⚠️**单位微秒** `listener/reality/reality.go:57`) / `proxy`(11) / `limit-fallback-upload`(13) / `limit-fallback-download`(14)。`limit-fallback-*` 子字段：`after-bytes`(18) / `bytes-per-sec`(19) / `burst-bytes-per-sec`(20)。

固定不可配（⚠️ 回退流量日志固定 DEBUG）：`SessionTicketsDisabled=true`(`:39`) / `Type="tcp"`(`:40`) / `Time=ntp.Now`(`:42`) / `Log=log.Debugln`(`:44`)。

---

### 1.2 TROJAN

#### proxy 侧（`adapter/outbound/trojan.go:45-69`）

| 字段 | 档 | 源码位置 | 说明 |
|---|---|---|---|
| `name`/`server`/`port` | S | `:47-49` | 无 omitempty |
| `password` | S | `:50` | 走 `trojan.Key()` = SHA224 hex 前 56 字节（`:304`） |
| `sni` | S* | `:52` | **TROJAN 用 `sni`，VLESS 用 `servername`**；空则回落 `server`（`:286-288`） |
| `tls` | — | **不存在** | 全文无 `proxy:"tls"`；写了被静默忽略。VLESS 才有（`adapter/outbound/vless.go:65`） |
| `alpn` | A | `:51` | ⚠️ 默认 TCP `["h2","http/1.1"]`（`:153-156`）、WS `["http/1.1"]`（`:106-109`）；判空用 `!= nil`，**显式 `alpn: []` 会得到空 ALPN 而非默认**（源码注释 `:107`） |
| `udp` | A | `:58` | |
| `client-fingerprint` | **A** | `:68` | 现在硬编码 `chrome`（快照 `Trojan.sh:527,546,692,712,775,795`） |
| `skip-cert-verify` | A | `:53` | 快照 `Trojan.sh:548,714,813` 硬编码 true |
| `name-cert-verify` | B | `:54` | |
| `fingerprint` | B | `:55` | |
| `network` | S | `:59` | 仅 `ws`(`:80`)/`grpc`(`:148,212`)；**default=裸 TCP+TLS**（`:150-172`） |
| `ech-opts` | A | `:60` | |
| `reality-opts` | B | `:64` | Trojan.sh 已实现 |
| `shadow-tls-opts` | B | `:61` | |
| `restls-opts` | C | `:62` | ⚠️ 传的是 `option.SNI`（`:317`），而 VLESS 传 `ServerName` |
| `jls-opts` | C | `:63` | |
| `ss-opts` | C | `:67` | trojan-go 兼容 SS 叠加层，见下 |
| `ws-opts` / `grpc-opts` | B | `:66` / `:65` | ⚠️ ws 分支忽略 ECH/REALITY（`:111-124`） |
| `certificate` / `private-key` | B | `:56-57` | mTLS |

`ss-opts`（`adapter/outbound/trojan.go:72-76`）：`enabled`(73) / `method`(74，**默认 `"AES-128-GCM"`** `:350-352`) / `password`(75，⚠️ enabled 且空 → `empty password` `:347-349`)。

#### listener 侧（`listener/inbound/trojan.go:12-29`）

| 字段 | 档 | 源码位置 | 说明 |
|---|---|---|---|
| `users` (list) | S | `:14` | `[]TrojanUser`（`:31-34`），必须 list |
| `ws-path` / `grpc-service-name` | S | `:15-16` | 扁平化，**无 `network`**（`listener/trojan/server.go:163,177`） |
| `certificate` / `private-key` | S | `:17-18` | 同时非空才生效（`server.go:91-106`） |
| `client-auth-type` / `-cert` | B | `:19-20` | Trojan.sh 已实现 |
| `ech-key` | B | `:21` | `server.go:100-105` |
| `allow-insecure` | **D** | `:22` | ⚠️ 与 VLESS 不同：**`ss-option` 开启即可绕过该检查**（`server.go:215-217`） |
| `reality-config` | B | `:26` | |
| `mux-option` | A | `:27` | |
| `ss-option` | C | `:28` | ⚠️ **单数**，proxy 侧是复数 `ss-opts` |
| `shadow-tls`/`res-tls`/`jls-config` | B/C | `:23-25` | |
| `decryption` / `xhttp-config` | — | **不存在** | 与 VLESS 相反 |

---

### 1.3 VMESS

#### proxy 侧（`adapter/outbound/vmess.go:54-88`）

| 字段 | 档 | listener | 源码位置 | 说明 |
|---|---|---|---|---|
| `name`/`server`/`port` | S | ✅ | `:56-58` | |
| `uuid` | S | ✅(在 users) | `:59` | |
| **`alterId`** | **S** | ✅(在 users) | `:60` | ⚠️ tag `proxy:"alterId"` **无 omitempty** → proxy 侧漏写会硬报 `has unset fields: alterId`（`common/structure/structure.go:532,583-592`）。all.sh:440 写 `alterId: 0` 是**必须**的 |
| **`cipher`** | **S** | ❌ | `:61` | ⚠️ 同样无 omitempty，漏写硬报错。透传给 `vmess.NewClient(..., security, ...)`（`:485`），仅 `strings.ToLower`（`:476`），**mihomo 侧不做枚举校验**。all.sh:441 写 `auto` |
| `network` | S | **❌ 无** | `:62` | |
| `tls` | S | — | `:63` | |
| `udp` | A | — | `:65` | |
| `global-padding` | **A** | ❌ | `:86` | **proxy-only bool**，见 §2.1.1 |
| `authenticated-length` | **A** | ❌ | `:87` | **proxy-only bool**，见 §2.1.1 |
| `packet-addr` | A | ❌ | `:83` | |
| `xudp` | A | ❌ | `:84` | |
| `packet-encoding` | D | ❌ | `:85` | legacy 别名 |
| `client-fingerprint` | **A** | ❌ | `:88` | |
| `servername` | S* | ❌ | `:72` | **vmess 与 vless 一样只有 `servername`，没有 `sni`** |
| `skip-cert-verify`/`name-cert-verify`/`fingerprint` | A/B/B | ❌ | `:66-68` | |
| `certificate`/`private-key` | B | ✅ | `:69-70` | |
| `ech-opts` | A | ✅(ech-key) | `:71` | |
| `ws-opts` | S(用 ws) | ✅(ws-path) | `:79` / `listener/inbound/vmess.go:15` | |
| `grpc-opts` | B | ✅(grpc-service-name) | `:77` / `:16` | |
| `http-opts`/`h2-opts` | B | ❌ | `:75-76` | |
| `shadow-tls-opts`/`restls-opts`/`jls-opts`/`reality-opts` | B/C | ✅ | `:73-76` | |
| **`tlsmirror-opts`** | C | ✅(`tlsmirror-config`) | `:77`→`adapter/outbound/tlsmirror.go` | ⚠️ **独立传输层**（非 tls 包装），小众 |
| **`mekya-opts`** | C | ✅(`mekya-config`) | `:78`→`adapter/outbound/mekya.go` | ⚠️ 独立传输层 |
| **`mkcp-opts`** | C | ✅(`mkcp-config`) | `:79`→`adapter/outbound/vmess.go:91-95` | ⚠️ mKCP，`MTU`/`TTI`/`UplinkCapacity`/`DownlinkCapacity` |

> ⚠️ `mkcp-opts` / `mekya-opts` / `tlsmirror-opts` 是 **vmess 独有的三种额外传输**，属于 C 档（实验性、单实现）。

#### listener 侧（`listener/inbound/vmess.go:12-30`）

| 字段 | 档 | 源码位置 | 说明 |
|---|---|---|---|
| `users` (list) | S | `:14` | `[]VmessUser`（`:32-36`）：`username`(33) / `uuid`(34) / `alterId`(35，omitempty) |
| `ws-path` / `grpc-service-name` | S | `:15-16` | 扁平化，无 `network` |
| `certificate` / `private-key` | S | `:17-18` | |
| `client-auth-type` / `-cert` / `ech-key` | B | `:19-21` | |
| `mux-option` | A | `:29` | |
| `shadow-tls` / `res-tls` / `jls-config` / `reality-config` | B/C | `:22-25` | |
| `tlsmirror-config` / `mekya-config` / `mkcp-config` | C | `:26-28` | 与 proxy 侧 `*-opts` 对称 |
| `decryption` / `xhttp-config` | — | **不存在** | vmess listener 无 xhttp |

---

### 1.4 HYSTERIA2

#### proxy 侧（`adapter/outbound/hysteria2.go:39-73`）

| 字段 | 档 | listener | 源码位置 | 说明 |
|---|---|---|---|---|
| `name`/`server` | S | ✅ | `:41-42` | |
| `port` | S | ✅ | `:43` | 无 omitempty；与 `ports` 至少要有一个，否则 `invalid port`（`:266-268`） |
| `password` | S | (在 users) | `:48` | |
| `sni` | S* | ❌ | `:53` | 非空覆盖 `server` 作为 TLS ServerName（`:165-168`） |
| `up` / `down` | A | ✅ | `:46-47` | 默认 **上行 60 / 下行 200**（用户偏好 150~200，见 `M_HY2_UP_DEFAULT`/`M_HY2_DOWN_DEFAULT`），用户改过就用 `.hy2-bandwidth` 里的值；语法（`100 Mbps` / `50 mbps` / 纯数字=Mbps）见 `common/utils/mbps.go:9-46`。⚠️ 链接侧只认 `up=`/`down=`，`upmbps=`/`downmbps=` 是 hysteria v1 的名字（写了会被静默忽略） |
| `obfs` / `obfs-password` | **A** | ✅ | `:49-50` | **完全对称**，枚举 `salamander` / `gecko`，见 §2.2.1 |
| `obfs-min-packet-size` / `obfs-max-packet-size` | B | ✅ | `:51-52` | **仅 gecko 生效**（`:158-159`）；配 salamander 静默无效 |
| `ports` | **A** | ❌ | `:44` | 原生端口跳跃，**比项目现在的 iptables DNAT 更优**；语法（最多 28 段）见 `common/utils/ranges.go:17-28` 与 `:65-87` |
| `hop-interval` | **A** | ❌ | `:45` | ⚠️ **string 类型、单位秒**，不是 time.Duration |
| `udp-mtu` | B | ✅ | `:63` | 默认 **1197**（`:195-199`） |
| `handshake-timeout` | B | ❌ | `:64` | int **秒**（`:234`） |
| `cwnd` / `bbr-profile` | B | ✅ | `:61-62` | `bbr-profile` ∈ standard/conservative/aggressive |
| `ech-opts` | A | ✅(对侧 ech-key) | `:54` | |
| `skip-cert-verify` / `name-cert-verify` / `fingerprint` | A/B/B | ❌ | `:55-57` | hysteria2 快照 `:449-453` 已按证书可信度分支，做得好 |
| `alpn` | B | ✅ | `:60` | `!= nil` 才覆盖；空数组会显式清空（`:185-187`） |
| `certificate` / `private-key` | B | ✅(必需) | `:58-59` | |
| `realm-opts` | C | ✅(+`proxy`) | `:66` | hy2 独有（`adapter/outbound/hysteria2.go:75-90` / `listener/inbound/hysteria2.go:44-60`） |
| `client-fingerprint` | **不存在** | ❌ | — | hy2 只有 `fingerprint` |
| `udp` | **不存在** | ❌ | — | UDP 硬编码 true（`:137`），无 yaml tag |
| `initial/max-stream/connection-receive-window` | C | ✅ | `:69-72` | quic-go 原始项，一般不动 |
| `ca` / `ca-str` / `up-mbps` / `down-mbps` / `disable-sni` / `zero-rtt-handshake` | **D 不存在** | — | 全仓 grep 零命中 |

#### listener 侧（`listener/inbound/hysteria2.go:12-42`）

| 字段 | 档 | 源码位置 | 说明 |
|---|---|---|---|
| `users` (**map**) | S | `listener/inbound/hysteria2.go:14` | `map[string]string`；拆成两条 slice 传 `UpdateUsers`（`listener/sing_hysteria2/server.go:241-247`） |
| `certificate` / `private-key` | S | `:19-20` | **无 omitempty**，事实必填 |
| `obfs` / `obfs-password` | A | `:15-16` | 对称于 proxy |
| `masquerade` | A | `:29` | 现在硬编码 `https://bing.com`（快照 `hysteria2.sh:634`）；scheme 仅 `file`/`http`/`https`，否则 `unknown masquerade URL scheme`（`server.go:155`） |
| `up` / `down` | A | `:26-27` | 服务端限速，映射 `SendBPS`/`ReceiveBPS`（`server.go:219-220`） |
| `ignore-client-bandwidth` | B | `:28` | **仅 listener 有**，客户端无对应项 |
| `alpn` | B | `:25` | 默认 `["h3"]`（`server.go:96-100`） |
| `mux-option` | A | `:33` | |
| `ech-key` / `client-auth-*` | B | `:21-23` | |
| `cwnd` / `bbr-profile` / `udp-mtu` | B | `:30-32` | |
| `realm-opts` | C | `:35` | 比 proxy 多一个 `proxy`（`:59`） |
| `max-idle-time` | **D 死字段** | `:24` | ⚠️ 透传到 `LC.Hysteria2Server`（`:112`）但 `listener/sing_hysteria2/server.go` **全文从未读取** |
| `ports` / `hop-interval` | **不存在** | — | 端口跳跃是纯客户端行为 |
| `udp` / `sni` / `token` | 不存在 | — | UDP-only 协议，服务端固定 `ListenPacket(..., "udp", ...)`（`server.go:254`） |

`up`/`down` 语法（`common/utils/mbps.go:9-46`，正则 `^(\d+)\s*([KMGT]?)([Bb])ps$`）：
空串→0(`:12-14`)；纯数字按 Mbps(`:17-19`)；**不匹配正则静默返回 0**(`:22-24`)；单位逐级 ×1000(`:26-38`)；大写 `B`=字节、小写 `b`=bit 需 ÷8(`:41-44`)。
→ 陷阱：`up: "50"` 合法（=50 Mbps），`up: "50 mbps"`（空格+小写 m）**不匹配 → 静默 0**。

---

### 1.5 TUIC

#### proxy 侧（`adapter/outbound/tuic.go:34-70`）

| 字段 | 档 | listener | 源码位置 | 说明 |
|---|---|---|---|---|
| `name`/`server` | S | ✅ | `:36-37` | |
| `port` | S | ✅ | `:38` | **无 omitempty** |
| `uuid` + `password` | S | ✅(users map) | `:40-41` | v5；⚠️ **非法 UUID 静默变全 0 且不报错**（`uuid.FromStringOrNil`，`:289`） |
| `token` | C | ✅(**[]string**) | `:39` | ⚠️ **proxy 是 string，listener 是 []string**；非空走 tuicV4（`:271-282`） |
| `sni` | S* | ❌ | `:65` | 非空覆盖 `server`（`:131-134`） |
| `congestion-controller` | **A** | ✅(默认 **bbr**) | `:48` | 枚举 `cubic`/`new_reno`/`bbr`/`bbr_meta_v1`/`bbr_meta_v2`，**其它值静默保留内核默认**（`transport/tuic/common/congestion.go:20-53` 无 default 分支）。TUIC.sh 硬编码 bbr |
| `udp-relay-mode` | A | ❌ | `:47` | `quic` 或任意其它(=native)。⚠️ **写错字静默落 native**（`:165-168`） |
| `reduce-rtt` | A | ❌ | `:45` | **这就是 0-RTT 开关**（`DialQuicOption{Early: ...}` `:114`） |
| `disable-sni` | **D** | ❌ | `:49` | ⚠️⚠️ true 时 `ServerName=""` **且强制 `InsecureSkipVerify=true`**（`:223-226`）= 关证书校验 |
| `max-udp-relay-packet-size` | B | ✅(默认1500) | `:50` | proxy 默认 **1252**（`:170-172`）；两边都 clamp 到 datagram frame ≤1400 后反算（`:191-194`） |
| `max-datagram-frame-size` | B | **❌ YAML 不可达** | `:64` | ⚠️ 只存在于 `listener/config/tuic.go:24`，`listener/inbound/tuic.go:12-29` **没有**这个字段，listener 配不了 |
| `heartbeat-interval` | B | ❌ | `:43` | int **毫秒**，≤0 默认 10000（`:161-163`） |
| `request-timeout` | C | ❌ | `:46` | int **毫秒**，0 默认 8000（`:157-159`）；**仅 V4 用** |
| `fast-open` | B | ❌ | `:52` | |
| `cwnd` / `bbr-profile` | B | ✅ | `:54-55` | cwnd 默认 32（`:178-180`） |
| `recv-window-conn` / `recv-window` | C | ❌ | `:61-62` | 默认 15728640 / 67108864（`transport/tuic/common/congestion.go:12-13`） |
| `disable-mtu-discovery` | C | ❌ | `:63` | |
| `max-open-streams` | C | ❌ | `:53` | 0 默认 100，客户端再 ×0.9（`:260-265`） |
| `ip` | C | ❌ | `:42` | 替换实际拨号地址但不改 SNI（`:220-222`） |
| `udp-over-stream` / `-version` | **D/C** | ❌ | `:68-69` | ⚠️ sing-box 私有扩展，开启后与原版 tuic **不兼容**（`docs/config.yaml:1595-1596`） |
| `ech-opts` | A | ✅(ech-key) | `:66` | |
| `skip-cert-verify`/`name-cert-verify`/`fingerprint`/`certificate`/`private-key` | A/B | ✅(certificate 必填) | `:56-60` | TUIC 快照 `:250,375` 等硬编码 skip-cert-verify: true |
| `client-fingerprint` / `udp` / `up` / `down` / `ca` / `zero-rtt-handshake` | **不存在** | — | — | UDP 硬编码 true（`:247`） |

#### listener 侧（`listener/inbound/tuic.go:12-29`）

| 字段 | 档 | 源码位置 | 说明 |
|---|---|---|---|
| `users` (**map**, uuid→password) | S | `:15` | `map[string]string` → `map[[16]byte]string`（`listener/tuic/server.go:168-174`） |
| `certificate` / `private-key` | S | `:16-17` | 无 omitempty，事实必填 |
| `congestion-controller` | A | `:21` | ⚠️ **listener 默认 `"bbr"`（`listener/parse.go:130`）**，与 proxy 侧文档所称 cubic 不对称 |
| `max-idle-time` | B | `:22` | int **毫秒**，默认 15000（`listener/parse.go:126`）；TUIC 快照 `:232` 已写 |
| `authentication-timeout` | B | `:23` | int **毫秒**，默认 1000（`listener/parse.go:127`）；TUIC 快照 `:233` 已写 |
| `alpn` | B | `:24` | 默认 `["h3"]`（`listener/parse.go:128`） |
| `max-udp-relay-packet-size` | B | `:25` | ⚠️ listener 默认 **1500**（`listener/parse.go:129`），proxy 是 1252 |
| `cwnd` / `bbr-profile` | B | `:26-27` | |
| `mux-option` | A | `:28` | |
| `token` (**[]string**) | C | `:14` | tuicV4 多值 |
| `client-auth-*` / `ech-key` | B | `:18-20` | |
| `sni`/`skip-cert-verify`/`uuid`/`password`/`reduce-rtt`/`udp` | 不存在 | — | |

固定不可配：`Allow0RTT=true`、`DisablePathManager=true`（`listener/tuic/server.go:102-103`）；`MaxIncomingStreams/UniStreams=(1<<32)-1`（`:27,99-100`）。

---

### 1.6 ANYTLS

#### proxy 侧（`adapter/outbound/anytls.go:27-51`）

| 字段 | 档 | 源码位置 | 说明 |
|---|---|---|---|
| `name`/`server` | S | `:29-30` | |
| `port` | S | `:31` | **无 omitempty** |
| `password` | S | `:32` | **无 omitempty**；`sha256` 后发出（`transport/anytls/client.go:42`） |
| `sni` | S* | `:34` | 空回落 `server`（`:167-169`）；⚠️ 同时被 shadow-tls/restls/jls 当 SNI（`:128,132,136`） |
| `alpn` | B | `:33` | **无默认值**（与 hy2/tuic 的 `["h3"]` 不同）；AnyTLS 快照 `:287-288` 等硬编码 `[h2, http/1.1]` |
| `udp` | A | `:45` | 三协议中**只有 anytls 出站有这个开关** |
| `client-fingerprint` | **A** | `:39` | ⚠️ **hy2/tuic 没有此字段，只有 anytls 有** |
| `skip-cert-verify` | A | `:40` | AnyTLS 快照 `:285,423,485,554` 硬编码 true |
| `idle-session-check-interval` / `idle-session-timeout` | A | `:47-48` | ⚠️ **≤5s 被静默强制抬为 30s**（`transport/anytls/session/client.go:52-57`）；AnyTLS 快照 `:283-284` 硬编码 30 |
| `min-idle-session` | B | `:49` | 默认 0 |
| `disable-reuse` | B | `:50` | 关闭空闲复用 |
| `client-metadata` | C | `:46` | 文档标注 v1.19.30 起默认不再发送（`docs/config.yaml:1700`） |
| `ech-opts` | A | `:35` | |
| `shadow-tls-opts` / `restls-opts` / `jls-opts` | B/C | ✅(对侧 `shadow-tls`/`res-tls`/`jls-config`) | `:36-38`；**三者与 certificate 互斥**（`:140-152`） |
| `name-cert-verify` / `fingerprint` | B | `:41-42` | |
| `certificate` / `private-key` | B | `:43-44` | mTLS |
| `padding-scheme` | **不存在** | ✅(listener 独有) | 见 §2.1.3 |
| `udp-relay-mode` / `obfs*` / `users` | 不存在 | — | UDP 恒走 uot over TCP（`:61-75`，`SupportUOT()` 恒 true `:78-80`） |

#### listener 侧（`listener/inbound/anytls.go:12-25`）

| 字段 | 档 | 源码位置 | 说明 |
|---|---|---|---|
| `users` (**map**) | S | `listener/inbound/anytls.go:14` | `map[string]string`；⚠️ 内部反转成 `map[[32]byte]string`，key=`sha256(password)`、**value=username**（`listener/anytls/server.go:37,123-125`） |
| `certificate` / `private-key` | S | `:15-16` | 同时非空才建 loader（`server.go:53-61`）；⚠️ **`ech-key` 的加载被嵌在这个 if 内**（`:62-67`），只填 ech-key 不填证书则 ECH 不生效 |
| `padding-scheme` | **A** | `:24` | **only listener**，见 §2.1.3 |
| `client-auth-type` / `-cert` | B | `:17-18` | AnyTLS.sh 已实现 |
| `ech-key` | B | `:19` | 同上陷阱 |
| `shadow-tls` / `res-tls` / `jls-config` | B/C | `:20-22` | ⚠️ 与 certificate 互斥（`server.go:85-100`） |
| `allow-insecure` | **D** | `:23` | 无 TLS 承载且非 true → 启动报错（`server.go:161-163`）；true 则明文监听 |
| `mux-option` | **不存在** | — | ⚠️ `listener/anytls/server.go:136-140` 调 `sing.NewListenerHandler` 时**未传** MuxOption |
| `sni` / `alpn` / `udp` / `skip-cert-verify` / `fingerprint` / `client-fingerprint` / `idle-session-*` | 不存在 | — | |

---

### 1.7 SHADOWSOCKS

#### proxy 侧（`adapter/outbound/shadowsocks.go:43-56`）

| 字段 | 档 | listener | 源码位置 | 说明 |
|---|---|---|---|---|
| `name`/`server`/`port` | S | ✅ | `:45-47` | |
| `password` | S | ✅ | `:48` | 无 omitempty |
| **`cipher`** | **S** | ✅ | `:49` | 无 omitempty。→ `shadowsocks.CreateMethod`（`:303`），失败报 `ss %s cipher: %s initialize error`（`:308`） |
| `udp` | A | ✅ | `:50` | |
| `client-fingerprint` | A | ❌ | `:55` | |
| **`plugin`** | **A** | ❌(**用 `simple-obfs`) | `:51` | ⚠️ listener 侧**没有** `plugin`/`plugin-opts`，改用扁平化的 `simple-obfs`。见 §2.2.2 |
| **`plugin-opts`** | **A** | ❌ | `:52` | `map[string]any`，按 plugin 名二次解码（tag `obfs`） |
| `udp-over-tcp` / `udp-over-tcp-version` | B/C | ❌ | `:53-54` | |
| `sni`/`tls`/`certificate`/`private-key`/`skip-cert-verify`/`ech-opts` | — | — | — | ⚠️ **ss proxy 顶层完全没有 TLS 字段**；要 TLS 只能经 `plugin: shadow-tls` / `restls` / `v2ray-plugin.tls` |

#### listener 侧（`listener/inbound/shadowsocks.go:12-23`）

| 字段 | 档 | 源码位置 | 说明 |
|---|---|---|---|
| `password` | S | `:14` | 无 omitempty |
| `cipher` | S | `:15` | 无 omitempty |
| `udp` | A | `:16` | |
| `mux-option` | A | `:17` | |
| `simple-obfs` | **A** | `:22` | `SimpleObfs{enable(26), mode(27)}`，⚠️ **不是** `plugin: obfs` |
| `shadow-tls` / `res-tls` / `jls-config` | B/C | `:18-20` | |
| `kcp-tun` | C | `:21` | `KcpTun`（`listener/inbound/kcptun.go:8-27`），⚠️ 与 proxy 的 `plugin: kcptun` 是两套 |
| `users` | 不存在 | — | ss 用顶层单密码 |

> ✅ 与用户已知的一致：**ss listener 用 `password` 顶层单值，没有 `users`**。

---

### 1.8 SNELL

#### proxy 侧（`adapter/outbound/snell.go:32-43`）

| 字段 | 档 | listener | 源码位置 | 说明 |
|---|---|---|---|---|
| `name`/`server`/`port` | S | ✅ | `:34-36` | |
| **`psk`** | **S** | ✅ | `:37` | 无 omitempty |
| `version` | S | ✅ | `:39` | 建议值 1/2/3/4；all.sh:571,580 写 `"3"` |
| `udp` | A | ✅ | `:38` | |
| `reuse` | B | ❌ | `:40` | 连接复用 |
| `client-fingerprint` | A | ❌ | `:42` | |
| **`obfs-opts`** | **B** | ✅ | `:41` / `listener/inbound/snell.go:18` | ⚠️ **两侧同名**，但 proxy 是 `map[string]any`，listener 是强类型 `SnellObfsOption`（`:28-31`） |

`obfs-opts` 取值（proxy 侧 `adapter/outbound/snell.go:47-56`）：
- `mode: tls` → `obfs.NewTLSObfs(c, host)`（`:48-49`）
- `mode: http` → `obfs.NewHTTPObfs(c, host, port)`（`:50-52`）
- `mode: shadow-tls` → 走 `shadowtls.NewShadowTLS`（`:53-56`）
- ⚠️ 其它 mode **无 default 分支 → 静默不混淆**

listener 侧（`listener/inbound/snell.go:28-31`）：`mode`(29) / `host`(30)，非法值报 `snell inbound obfs mode error: %s`（`listener/snell/server.go:51`）。
listener 另支持 `shadow-tls` / `res-tls` / `jls-config`（`:19-21`），**proxy 侧只支持 obfs 的 tls/http 与 shadow-tls，无 restls/jls**（`:47-56` 只列出三种）。

---

## 2. 按主题深挖

### 2.1 Padding / 填充类 —— 「加密」相关，用户点名

Mihomo v1.19.32 一共只有 **4 套** padding 机制，分属 3 个协议。**没有「通用的加密填充」字段**。

#### 2.1.1 VMess `global-padding` + `authenticated-length`

| 项 | 内容 |
|---|---|
| 所在 struct | `outbound.VmessOption`，`adapter/outbound/vmess.go:86` / `:87` |
| yaml tag | `global-padding`（bool）、`authenticated-length`（bool） |
| 侧 | **仅 proxy**。全仓 grep 这两个 tag 只命中 `adapter/outbound/vmess.go`；listener 侧 `VmessOption`（`listener/inbound/vmess.go:12-30`）**没有**这两个字段 |
| 生效点 | `adapter/outbound/vmess.go:478-483`：`GlobalPadding` → `vmess.ClientWithGlobalPadding()`；`AuthenticatedLength` → `vmess.ClientWithAuthenticatedLength()`。两者都是**独立开关，可同时开** |
| 作用 | `global-padding` 对**整个负载**做 padding；`authenticated-length` 把「长度」字段纳入 AEAD 认证（防长度侧信道） |
| 默认值 | **均为 false**（Go 零值，代码里没有任何默认注入） |
| 类型 | 纯 bool，**没有子字段、没有长度参数**（与 xhttp / anytls 的自由格式完全不同） |
| 兼容性 | 实现在 `github.com/metacubex/sing-vmess`（`adapter/outbound/vmess.go:26`），**必须服务端也支持**才能握手成功，否则断连 |

> ✅ 修正用户假设：这两个**不是** vmess 独有 —— 它们只在 vmess 上，但**仅 proxy 侧**；`x-padding-*` 才在 xhttp 上且两侧都有。

#### 2.1.2 xhttp `x-padding-*` 系列（7 个字段）

**proxy 侧** `outbound.XHTTPOptions`，`adapter/outbound/vless.go:99-104`：

| 字段 | 类型 | 行号 | 默认值 | 说明 |
|---|---|---|---|---|
| `x-padding-bytes` | string | `:99` | **`"100-1000"`**（`transport/xhttp/xpadding.go:180-186`） | 格式 `N` 或 `N-M`；padding 长度区间 |
| `x-padding-obfs-mode` | bool | `:100` | false | true 时 padding 变成可被 `x-padding-key` 解码的混淆态；false 时固定 queryInHeader/Referer/x_padding 三通道（`transport/xhttp/config.go:510-517`） |
| `x-padding-key` | string | `:101` | — | **仅 obfs-mode 生效**（`config.go:503-509`） |
| `x-padding-header` | string | `:102` | — | 同上 |
| `x-padding-placement` | string | `:103` | — | 枚举 `queryInHeader`/`cookie`/`header`/`query`/`path`/`body`/`auto`（`transport/xhttp/config.go:21-29`） |
| `x-padding-method` | string | `:104` | — | 枚举 `repeat-x` / `tokenish`（`transport/xhttp/xpadding.go:14-18`） |

**listener 侧** `XHTTPConfig`，`listener/inbound/vless.go:42-47` —— **7 个字段全部同名同义**，两侧对称。

> ✅ 修正用户假设：xhttp 的 padding **两侧都有**，就在 `xhttp-opts`（proxy）/ `xhttp-config`（listener）里，用户没写错位置。

listener `xhttp-config` 另有 3 个 **server-only** 字段（proxy 侧完全没有）：
`no-sse-header`（`listener/inbound/vless.go:56`，`transport/xhttp/config.go:53` 注释标 "server only"）/ `sc-stream-up-server-secs`（`:57`，默认 `"20-80"` `config.go:196-202`）/ `sc-max-buffered-posts`（`:58`，默认 `"30"` `config.go:204-213`）。

#### 2.1.3 ANYTLS `padding-scheme` —— **只有 listener 侧**

| 项 | 内容 |
|---|---|
| 所在 struct | `inbound.AnyTLSOption`，`listener/inbound/anytls.go:24`（中间载体 `listener/config/anytls.go:20`） |
| 侧 | **listener-only**。proxy 侧 `AnyTLSOption`（`adapter/outbound/anytls.go:27-51`）**没有该字段**；客户端无条件用内置默认（`transport/anytls/client.go:49-50`） |
| 类型 | **不是关键字枚举，是自由格式的 key=value 文本 scheme** |
| 消费点 | `listener/anytls/server.go:127-133`；解析失败报 `incorrect padding scheme format` |
| 唯一硬要求 | 必须含可 `strconv.Atoi` 的 `stop=`（`transport/anytls/padding/padding.go:51-55`） |
| 键 | 十进制报文类型序号 `0`..`6`（`padding.go:61`），外加保留键 `stop`（`:30,51-52`） |
| 值 | 逗号分隔；每项是 `min-max` 整数区间，或字面量 `c`（`padding.go:62-88`） |
| 边界 | `<=0` 的项**静默丢弃**（`:77-79`）；`min>max` 自动交换（`:74-76`）；**无上限校验**，但最终按 uint16 编码（上限 65535）；随机取值是 `[min, max-1]` 左闭右开（`:83-84`） |
| 运行时同步 | 服务端通过 `cmdSettings`/`cmdUpdatePaddingScheme` 帧（`transport/anytls/session/frame.go:14` 常量 6）把 scheme 下发给客户端（`session/session.go:274-283,315-326`） |

内置默认方案（`transport/anytls/padding/padding.go:17-25`）：
```
stop=8
0=30-30
1=100-400
2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
3=9-9,500-1000
4=500-1000
5=500-1000
6=500-1000
7=500-1000
```

> 📌 **参考实现已实现同款菜单**：`参考实现/src/conf/anytls.sh:146-179` 的 `ask_anytls_padding()` 提供「内核默认 / 显式写入默认 / 自定义」三档，可直接移植文案与默认值。
> ⚠️ **格式差异**：sing-box 的 `padding_scheme` 是 **JSON 字符串数组**（`anytls.sh:212-220` 用 `jq -R . | jq -sc .`），mihomo 的 `padding-scheme` 是**单个 YAML 多行字符串**，Bash 里要用块标量 `|` 输出，不能照抄 jq 那段。

#### 2.1.4 还有别的吗？

| 机制 | 侧 | 位置 | 说明 |
|---|---|---|---|
| `smux.padding` | proxy | `adapter/outbound/singmux.go:29` | 多路复用帧填充，**默认 false**；与抗识别无关，纯粹打散流量形态 |
| `mux-option.padding` | listener | `listener/inbound/mux.go:6` | 与上一条配对 |
| smux `brutal-opts` | proxy | `adapter/outbound/singmux.go:32` | **不是 padding，是带宽声明**（BBR 拥塞控制），见 §2.4 |

✅ 结论：用户点名的「加密/填充」在内核里就是以上三套，**没有通用 `padding` 字段**。

---

### 2.2 混淆 / 伪装类

#### 2.2.1 hysteria2 `obfs` / `obfs-password`

| 项 | 内容 |
|---|---|
| proxy | `adapter/outbound/hysteria2.go:49-52`：`obfs`(49) / `obfs-password`(50) / `obfs-min-packet-size`(51) / `obfs-max-packet-size`(52) |
| listener | `listener/inbound/hysteria2.go:15-18`：**完全对称** |
| 允许值 | `salamander` / `gecko`（`adapter/outbound/hysteria2.go:154,156`；`listener/sing_hysteria2/server.go:110,112`）。常量 `hysteria2.ObfsTypeSalamander/Gecko` 来自外部依赖 `github.com/metacubex/sing-quic`（`go.mod:39`），仓库无 vendor，**字符串字面量未找到证据**，文档佐证 `docs/config.yaml:1244,2716` |
| 有 type 无 password | **硬错误** `missing obfs password`（`:150-152` / `server.go:106-108`） |
| **有 password 无 type** | ⚠️ **静默忽略**——守卫是 `if len(option.Obfs) > 0`（`:149`），`obfs-password` 单独出现两个密码变量都保持空 |
| 未知 type | 硬错误 `unknown obfs type: %s`（`:161` / `server.go:117`） |
| min/max-packet-size | **仅 gecko 分支读取**（`:158-159`）；配 salamander 静默无效 |

#### 2.2.2 shadowsocks `plugin` —— 7 种，且两侧机制完全不同

**proxy 侧**用 `plugin` + `plugin-opts`（`adapter/outbound/shadowsocks.go:51-52`），分发链 `:321-470`：

| `plugin` 值 | 行号 | `plugin-opts` 字段（tag `obfs`） | 默认值 / 校验 |
|---|---|---|---|
| `obfs` | `:321-332` | `mode`(59)、`host`(60) | host 默认 **`bing.com`**；mode **必须** `tls` 或 `http`，否则硬错误（`:327-329`） |
| `v2ray-plugin` | `:333-368` | `mode`(64,**无 omitempty**)、`host`(65)、`path`(66)、`tls`(67)、`ech-opts`(68)、`fingerprint`(69)、`certificate`(70)、`private-key`(71)、`headers`(72)、`skip-cert-verify`(73)、`name-cert-verify`(74)、`mux`(75)、`v2ray-http-upgrade`(76)、`v2ray-http-upgrade-fast-open`(77) | host 默认 `bing.com`、**mux 默认 `true`**（`:334`）；mode **必须** `websocket`（`:338-340`） |
| `gost-plugin` | `:369-397` | `mode`(81,**无 omitempty**)、`host`(82)、`path`(83)、`tls`(84)、`ech-opts`(85)、`fingerprint`(86)、`certificate`(87)、`private-key`(88)、`headers`(89)、`skip-cert-verify`(90)、`name-cert-verify`(91)、`mux`(92) | 同上默认值；mode 必须 `websocket`（`:387-389`） |
| `shadow-tls` | `:396-421` | `password`(96)、`host`(97,**无 omitempty**)、`fingerprint`(98)、`certificate`(99)、`private-key`(100)、`skip-cert-verify`(101)、`name-cert-verify`(102)、`version`(103)、`alpn`(104) | ⚠️ **version 默认 2**（`:398-400`）；alpn 未给时用 `shadowtls.DefaultALPN`（`:417-419`） |
| `restls` | `:422-441` | `password`(107,**无 omitempty**)、`host`(108,**无 omitempty**)、`version-hint`(109,**无 omitempty**)、`restls-script`(110)、`fingerprint`(111)、`skip-cert-verify`(112)、`name-cert-verify`(113)、`force-tls12`(114) | |
| `jls` | `:442-457` | `host`(117,**无 omitempty**)、`username`(118,**无 omitempty**)、`password`(119,**无 omitempty**)、`alpn`(120) | |
| `kcptun` | `:458-470` | `key`(126)、`crypt`(127)、`mode`(128)、`conn`(129)、`autoexpire`(130)、`scavengettl`(131)、`mtu`(132)、`ratelimit`(133)、`sndwnd`(134)、`rcvwnd`(135)、`datashard`(136)、`parityshard`(137)、`dscp`(138)、`nocomp`(139)、`acknodelay`(140)、`nodelay`(141)、`interval`(142) | ⚠️ **名字全部是历史遗留的无横线拼写**（`scavengettl` 不是 `scavenge-ttl`） |

> ⚠️ **plugin 名是精确匹配的**（`option.Plugin == "obfs"` 等），拼错**不报错**，只是都不进分支 → 静默变成裸 SS。**`plugin-opts` 的 tag 是 `obfs` 不是 `proxy`**，写在 `plugin-opts:` 下的键直接映射到这些 Go 字段名。

**listener 侧**完全另一套（`listener/inbound/shadowsocks.go:12-23`）：
- `simple-obfs`（`:22`）：`enable`(26) / `mode`(27) —— **不是** `plugin: obfs`
- `shadow-tls`(18) / `res-tls`(19) / `jls-config`(20)
- `kcp-tun`(21)：`enable`(9) / `key`(10) / `crypt`(11) / `mode`(12) / `conn`(13) / `autoexpire`(14) / `scavengettl`(15) / `mtu`(16) / `ratelimit`(17) / `sndwnd`(18) / `rcvwnd`(19) / `datashard`(20) / `parityshard`(21) / `dscp`(22) / `nocomp`(23) / `acknodelay`(24) / `nodelay`(25) / `interval`(26)（`listener/inbound/kcptun.go:8-27`）

> 🚨 **最易踩的坑**：ss 的 `obfs`/`v2ray-plugin`/`gost-plugin` **listener 侧只支持 `simple-obfs` 一种**；`shadow-tls`/`restls`/`jls`/`kcptun` listener 侧是独立的顶层键，不是 `plugin`。

#### 2.2.3 snell `obfs-opts`

见 §1.8。proxy 支持 `tls`/`http`/`shadow-tls` 三种 mode（`adapter/outbound/snell.go:47-56`），listener 只支持前两种 + 独立的 `shadow-tls`/`res-tls`/`jls-config`（`listener/inbound/snell.go:19-21`）。

#### 2.2.4 `shadow-tls` / `restls` / `jls` 三件套 —— **键名完全不对称**

| 语义 | proxy | listener |
|---|---|---|
| shadow-tls | `shadow-tls-opts`（`adapter/outbound/shadowtls.go:5`） | `shadow-tls`（`listener/inbound/shadowtls.go:8`） |
| **restls** | `restls-opts`（`adapter/outbound/restls.go:5`） | **`res-tls`**（`listener/inbound/restls.go:7`）—— **连词都变了** |
| jls | `jls-opts`（`adapter/outbound/jls.go:5`） | `jls-config`（`listener/inbound/jls.go:8`） |
| reality | `reality-opts`（`adapter/outbound/reality.go:13`） | `reality-config`（`listener/inbound/reality.go:5`） |

proxy 三件套子字段：
- `ShadowTLSOptions`：`password`(6) / `version`(7，⚠️ **0 默认 2** `transport/shadowtls/client.go:54-57`；**仅 1..3 合法** `:204-209`)
- `RestlsOptions`：`password`(6) / `version-hint`(7) / `restls-script`(8)；**三者皆空即禁用**（`adapter/outbound/restls.go:12-14`）
- `JLSOptions`：`username`(6) / `password`(7) —— ⚠️ **两个 tag 都无 omitempty**，空则 `jls: username is required`（`transport/jls/jls.go:55-60`）

listener 三件套子字段：
- `ShadowTLS`：`enable`(9) / `version`(10，⚠️ **无默认值**，0 直接因 `checkVersion` 报错 `transport/shadowtls/server.go:58-60`) / `password`(11) / `users`(12，**v3 必填** `:61-64`) / `handshake`(13，**`dest` 无 omitempty** `:25`) / `handshake-for-server-name`(14) / `strict-mode`(15，仅 v3) / `wildcard-sni`(16，枚举 `authed`/`all`，**其它值→off** `listener/shadowtls/listener.go:41-48`)
- `ResTLS`：`enable`(8) / `dest`(9) / `password`(10) / `restls-script`(11) / `min-record-len`(12) / `rate-limit`(13) / `proxy`(14)
- `JLSConfig`：`enable`(9) / `users`(10，**≥1** `transport/jls/jls.go:132-142`) / `sni`(11，⚠️ **默认 = dest 的 host** `:128-130`) / `dest`(12，**必填且须 host:port** `:122-127`) / `alpn`(13，nil→`DefaultALPN` `:145-147`) / `proxy`(14) / `rate-limit`(15)

⚠️ `res-tls` 的 builder **error 被丢弃**（`listener/sing_vless/server.go:158-160`、`listener/trojan/server.go:154-156`）—— 配错了不报错。

---

### 2.3 指纹 / TLS 类

#### 2.3.1 `client-fingerprint` 全量可选值

枚举表在 `component/tls/utls.go:78-101`（`init()` 还在 `:103-111` 动态注册 `randomized`）：

| 值 | 常量 | 行号 | 备注 |
|---|---|---|---|
| `chrome` | `HelloChrome_Auto` | `:79` | ✅ **推荐**，项目当前全部硬编码这个 |
| `firefox` | `HelloFirefox_Auto` | `:80` | |
| `safari` | `HelloSafari_Auto` | `:81` | |
| `ios` | `HelloIOS_Auto` | `:82` | |
| `android` | `HelloAndroid_11_OkHttp` | `:83` | |
| `edge` | `HelloEdge_Auto` | `:84` | |
| `360` | `Hello360_Auto` | `:85` | |
| `qq` | `HelloQQ_Auto` | `:86` | |
| `random` | 走加权随机 | `:47-51`, `:62-76` | 权重 chrome 6 / safari 3 / ios 2 / firefox 1（`:64-67`） |
| `chrome120` | `HelloChrome_120` | `:90` | 注释标 "classical fingerprints without X25519MLKEM768"（`:89`） |
| `firefox120` | `HelloFirefox_120` | `:91` | 同上 |
| `safari16` | `HelloSafari_16_0` | `:92` | 同上 |
| `chrome_psk` | `HelloChrome_100_PSK` | `:95` | ⚠️ 注释标 **deprecated**（`:94`） |
| `chrome_psk_shuffle` | `HelloChrome_106_Shuffle` | `:96` | ⚠️ deprecated |
| `chrome_padding_psk_shuffle` | `HelloChrome_114_Padding_PSK_Shuf` | `:97` | ⚠️ deprecated |
| `chrome_pq` | `HelloChrome_115_PQ` | `:98` | ⚠️ deprecated |
| `chrome_pq_psk` | `HelloChrome_115_PQ_PSK` | `:99` | ⚠️ deprecated |
| `randomized` | `HelloRandomized` | `:100`, `:110` | 每次启动重新播种（`:108`），**跨重启指纹会变** |
| `none` / 空 | — | `:43-45` | 显式关闭 uTLS，用原生 Go TLS |

**未知值行为**（`:56-59`）：只 `log.Warnln("wrong clientFingerprint:%s")` 并返回 `false` → **静默降级为原生 TLS，没有任何错误**。

#### 2.3.2 `fingerprint` 与 `client-fingerprint` 的区别

| | `client-fingerprint` | `fingerprint` |
|---|---|---|
| 作用 | 伪装 **TLS ClientHello**（JA3/JA4 指纹），模仿浏览器 | **证书 SHA256 校验**（SSL pinning） |
| 实现 | uTLS `UClient()`（`component/tls/utls.go:30-31`） | 写入 `tls.Config` 的自定义 `VerifyPeerCertificate` |
| 归属 | proxy 侧，per-proxy | proxy 侧，per-proxy |
| 典型用法 | `client-fingerprint: chrome` | hysteria2 快照 `:452` 的 `fingerprint: $CERT_PIN`（自签证书场景，替代 `skip-cert-verify`） |

> ✅ 项目里 hysteria2 的做法是对的（hysteria2 快照 `:449-453`：证书可信 → `skip-cert-verify: false`；否则 → `fingerprint: $CERT_PIN`）。**VLESS / Trojan / AnyTLS / TUIC 都还是硬编码 `skip-cert-verify: true`，应统一改成这套分支。**

计算方法（参考实现已有实现，`参考实现/src/conf/anytls.sh:182-185`）：
```bash
openssl x509 -in "$1" -outform DER 2>/dev/null | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
```

#### 2.3.3 `ech-opts` / `ech-key`

proxy `ECHOptions`（`adapter/outbound/ech.go:12-17`）：`enable`(13) / `config`(14) / `query-server-name`(16)
- `enable: false` → `Parse()` 直接返回 nil,nil（`:20-22`）
- ⚠️ **一旦设了 `config`，`query-server-name` 被忽略**（`:24-39` 的 if/else）
- `config` 解码失败 → `base64 decode ech config string failed`（`:26-27`）
- listener 对侧是 `ech-key`（`listener/inbound/vless.go:23` / `trojan.go:21` / `hysteria2.go:23` / `tuic.go:20` / `anytls.go:19`）
- ⚠️ **anytls 的 `ech-key` 加载被嵌在 `if certificate && private-key` 内部**（`listener/anytls/server.go:53-67`），只填 ech-key 不填证书 → ECH 不生效

#### 2.3.4 `skip-cert-verify` / `name-cert-verify`

- `skip-cert-verify`（bool）：关证书校验。**D 档语义危险**，但项目现在 4 处硬编码 `true`。
- `name-cert-verify`（string）：**只改证书的 DNSName 校验目标，不改 SNI**（以 hysteria2 为例，`adapter/outbound/hysteria2.go:177`）。实现在 `component/ca/name_cert_verify.go`。**比 skip-cert-verify 安全的替代，A 档应默认推荐**。
- ⚠️ 项目 `src/lib/validate.py` 的 `TLS_PROXY` 集合（`:182-183`）**只允许** `tls`/`alpn`/`skip-cert-verify`/`name-cert-verify`/`fingerprint`/`certificate`/`private-key`/`ech-opts` —— **没有 `ca` / `ca-fingerprint`**，与内核一致（内核这几个协议也都没有 `ca` 字段，见 §1.4 的「不存在项」）。

---

### 2.4 多路复用：三套机制，别搞混

| | `smux` | `mux-option` | xhttp `reuse-settings` |
|---|---|---|---|
| 侧 | **仅 proxy** | **仅 listener** | **仅 proxy** |
| 定义 | `outbound.SingMuxOption`，`adapter/outbound/singmux.go:23-33` | `inbound.MuxOption`，`listener/inbound/mux.go:5-14` | `outbound.XHTTPReuseSettings`，`adapter/outbound/vless.go:121-128` |
| yaml 入口 | `adapter/parser.go:234` 读 `mapping["smux"]`，`:239` `Enabled` 为 true 才包装 | 各协议内嵌，如 `listener/inbound/vless.go:29` | `xhttp-opts.reuse-settings` |
| 字段 | `enabled`(24) `protocol`(25) `max-connections`(26) `min-streams`(27) `max-streams`(28) `padding`(29) `statistic`(30) `only-tcp`(31) `brutal-opts`(32) | `padding`(6) `brutal`(7){`enabled`(11) `up`(12) `down`(13)} | `max-concurrency`(122) `max-connections`(123) `c-max-reuse-times`(124) `h-max-request-times`(125) `h-max-reusable-secs`(126) `h-keep-alive-period`(127，**int 秒**) |
| `protocol` 可选值 | ⚠️ **权威列表未找到证据** —— 校验在外部库 `github.com/metacubex/sing-mux v0.3.12`（`go.mod:38`），仓库无 vendor、本机无 module cache。仓库内唯一线索是测试集合 `{"h2mux","smux","yamux"}`（`listener/inbound/mux_test.go:12`），该文件注释说 `smux`/`h2mux` "has some confused bugs" 只测 `yamux`（`:13`）。mihomo 侧**只做透传**（`adapter/outbound/singmux.go:102`） | — | — |
| 默认 | `enabled` 不开则**整块被丢弃**（`adapter/parser.go:240`） | `padding` 默认 false；**服务端无需 enable**（按 FQDN 自动分发 `listener/sing/sing.go:94-112`） | 全 `"0"`（`transport/xhttp/config.go:361-400`） |
| 适用协议 | **所有 28 种 proxy 类型**（`adapter/parser.go:234` 在类型 switch 之后，是通用后处理） | vless(`listener/inbound/vless.go:29`) / vmess(`:29`) / trojan(`:27`) / hysteria2(`:33`) / tuic(`:28`) / shadowsocks(`:17`) / shadowquic / sudoku —— **anytls 无** | vless（proxy 侧 `network: xhttp`） |
| anytls | ❌ | ❌ **无**（`listener/anytls/server.go:136-140` 未传 MuxOption） | ❌ |

**关键区别**：
- `smux` 是**通用代理层复用**，包在任意 outbound 外面，所有协议都能用。
- `mux-option` 是**服务端侧 sing handler 提供的复用**，且**只有 `padding` + `brutal` 两个维度**——**服务端不能配 `protocol`/`max-connections` 等**。⚠️ 这就是「proxy 配了三档 smux，服务端 `mux-option` 却对不上」的根本原因。
- `reuse-settings`（aka XMUX）是 **xhttp 自己的连接复用**，不是 sing-mux，和 `smux` **完全独立**。

`brutal-opts`（proxy，`adapter/outbound/singmux.go:35-39`）：`enabled`(36) / `up`(37) / `down`(38)，经 `utils.StringToBps` 转字节率（`:110-111`）。源码注释 `:95-96` 留了 TODO：*"TCP Brutal is only supported on Linux-based systems"*。

---

### 2.5 传输层独有选配

#### ws（`WSOptions`，`adapter/outbound/vmess.go:165-172`）

| 字段 | 行号 | 说明 |
|---|---|---|
| `path` | `:166` | 核心 |
| `headers` | `:167` | map[string]string |
| `max-early-data` | `:168` | ⚠️ **VLESS/TROJAN 透传但两协议自身不使用早数据**；VMESS 用 |
| `early-data-header-name` | `:169` | 同上 |
| `v2ray-http-upgrade` | `:170` | 把 WS 首包升级成 HTTP，消掉 1-RTT 往返 |
| `v2ray-http-upgrade-fast-open` | `:171` | 需服务端也支持，否则失效 |

⚠️ **VLESS / TROJAN 的 ws 分支会忽略 ECH 和 REALITY**（`adapter/outbound/vless.go:204-214` 仅处理 ShadowTLS/Restls/JLS；`trojan.go:111-124` 同）。CDN 场景很常见，但这两个字段不生效。

#### grpc（`GrpcOptions`，`adapter/outbound/vmess.go:156-163`）

`grpc-service-name`(157) / `grpc-user-agent`(158，**仅非空才设置 UA** `transport/gun/gun.go:342-343`) / `ping-interval`(159，**单位秒，0 = 不做健康检查** `gun.go:310`) / `max-connections`(160) / `min-streams`(161) / `max-streams`(162)。
⚠️ 四项全 0 时自动 `maxConnections = 1`（`transport/gun/gun.go:398-401`）。

#### h2（`HTTP2Options`，`adapter/outbound/vmess.go:151-154`）

`host`(152，**[]string**) / `path`(153)。
⚠️ **`host` 有危险默认值 `["www.example.com"]`**（`adapter/outbound/vless.go:561-564`）—— 不配就会把 h2 打到 example.com 的 Host。

`http-opts`（`HTTPOptions`，`adapter/outbound/vmess.go:145-149`）：`method`(146) / `path`(147，**[]string**) / `headers`(148，**map[string][]string**，与 ws 的 map[string]string 不同)。

#### xhttp —— 哪些算「选配」

proxy `XHTTPOptions` 共 26 个字段（`adapter/outbound/vless.go:93-119`）+ `XHTTPDownloadSettings`（`:130-153`，21 个全指针）。分类：

| 类别 | 字段 | 行号 |
|---|---|---|
| **核心（不可省）** | `path` / `mode` | `:94`, `:96` |
| **A 强烈建议** | `x-padding-bytes` + `x-padding-obfs-mode` + `x-padding-key` + `x-padding-header` + `x-padding-placement` + `x-padding-method`（6 个，padding 全家） | `:99-104` |
| **A 强烈建议** | `session-table`（抗探测：让 session id 落在可枚举空间内） | `:108` |
| **B 按需** | `host` / `headers` / `no-grpc-header` / `uplink-http-method` / `uplink-chunk-size` | `:95`,`:97`,`:98`,`:105`,`:114` |
| **B 按需** | `session-placement` / `session-key` / `session-length` | `:106-107`,`:109` |
| **B 按需** | `seq-placement` / `seq-key` | `:110-111` |
| **B 按需** | `uplink-data-placement` / `uplink-data-key` | `:112-113` |
| **B 按需** | `reuse-settings`（XMUX，6 子字段） | `:117` |
| **C 实验** | `download-settings`（拆分上下行，21 子字段） | `:118` |
| **C 实验** | `sc-max-each-post-bytes` / `sc-min-posts-interval-ms` | `:115-116` |

xhttp `mode` 枚举（**proxy 与 listener 不同**）：
- proxy：空→`auto`，最终只允许 `stream-one` / `stream-up` / `packet-up`，否则 `xhttp mode %s is not implemented yet`（`transport/xhttp/client.go:245-251`）。EffectiveMode：有 REALITY + download-settings → `stream-up`；有 REALITY 无 download → `stream-one`；否则 `packet-up`（`transport/xhttp/config.go:77-89`）
- listener：允许 `auto` / `stream-up` / `stream-one` / `packet-up`，否则 `unsupported xhttp mode`（`listener/sing_vless/server.go:200-206`）
- ⚠️ **`mode: stream-one` 与 `download-settings` 互斥**（`adapter/outbound/vless.go:721-723`）
- ⚠️ **xhttp 的 HTTP/3 分支不支持任何 security mode**（`adapter/outbound/vless.go:696-698,887-889`）

`x-padding-bytes` 默认 `"100-1000"`（`transport/xhttp/xpadding.go:180-186`）；`uplink-chunk-size` 默认 `"0"`，0 时 cookie→2-3KiB、header→3-4KiB、其它→`sc-max-each-post-bytes`（`transport/xhttp/config.go:237-264`），显式设置时 min 被强制抬到 ≥64（`:257-262`）。

### 2.6 对「任务描述里几个假设」的显式修正

| 常见假设 | 实际情况 | 证据 |
|---|---|---|
| smux 定义在 `adapter/outbound/base.go` | ❌ `base.go:193-207` 的 `BasicOption` **没有** smux；smux 在 `adapter/outbound/singmux.go:23-33`，接线在 `adapter/parser.go:234-246` | — |
| singmux 有 `multiplex` / `multiplex-brutal` / `disabled` 枚举 | ❌ **未找到证据**。本版本 `smux` 块里唯一的枚举是 `protocol`（透传）。`adapter/outbound/sudoku.go:45` 的 `multiplex` 和 `adapter/outbound/mieru.go:40` 的 `multiplexing` 与 sing-mux 无关 | — |
| `mux-option` 是形如 `cwnd-multiplier=...` 的字符串 | ❌ **未找到证据**。它是**嵌套 map**，且只有 `padding` + `brutal{enabled,up,down}` 两个维度 | `listener/inbound/mux.go:5-14` |
| 有 `ech-enable` / `ech-server-key` / `ech-config`(listener) | ❌ 全部**未找到证据**。proxy 用 `ech-opts.{enable,config,query-server-name}`，listener 统一用 `ech-key` | `adapter/outbound/ech.go:12-17`；13 处 `listener/inbound/*.go` |
| 有 `ca` / `ca-str` / `ca-fingerprint` | ❌ **未找到证据**（Clash Premium 时代遗留）。当前顶层 CA 键是 `tls.custom-certifactes`（官方拼写错误，少 `i`） | `config/config.go:400` |
| 有 `certificate-public-key` | ❌ **未找到证据** | — |
| reality-opts 有 `spider-x` | ❌ **未找到证据**。proxy 侧只有 3 个字段：`public-key` / `short-id` / `support-x25519mlkem768` | `adapter/outbound/reality.go:13-18` |
| ss plugin 支持 `obfs-local` | ❌ **未找到证据**（全仓零匹配）。只认 `obfs` | `adapter/outbound/shadowsocks.go:321` |
| ss/snell 的 `shadowquic`/`sudoku` 是 plugin | ❌ 是**独立顶层 type** | `adapter/parser.go:114,177`；`listener/parse.go:137,164` |
| xhttp padding 有字符串长度规格 | ✅ 成立，但那是 `x-padding-bytes`（xhttp），**不是** vmess | `transport/xhttp/config.go:327-359` |

---

## 3. 字段冲突与陷阱表

### 3.1 「放错侧就静默失效」全清单

| 写错的组合 | 结果 | 依据 |
|---|---|---|
| **vless / vmess 上写 `sni`** | 🚨 **静默失效**。二者只有 `servername` | `adapter/outbound/vless.go:89`、`adapter/outbound/vmess.go:70`；`sni` 只在 trojan `adapter/outbound/trojan.go:52` / hysteria2 `:53` / tuic `:65` / anytls `:34` |
| **trojan 上写 `servername`** | 静默失效。trojan 用 `sni`，且空时自动回落 `server` | `adapter/outbound/trojan.go:52,286-288` |
| **trojan 上写 `tls: true`** | 静默失效。**trojan 根本没有 `tls` 字段**，永远走 TLS | `adapter/outbound/trojan.go:45-69` 全文 |
| **listener 上写 `network: ws`** | 静默失效，**退化成裸 TCP**。listener vless/vmess/trojan 均无 `network` 字段，靠 `ws-path`/`grpc-service-name`/`xhttp-config` 非空判定 | `listener/inbound/vless.go:12-30`；`listener/sing_vless/server.go:167,181,207` |
| **proxy 上写 `mux-option`** | 静默失效。proxy 侧只有通用 `smux:` | `adapter/parser.go:234` |
| **proxy 上写 `smux` 但漏 `enabled: true`** | 静默失效，整块被丢弃 | `adapter/parser.go:240` |
| **listener 上写 `smux`** | 静默失效 | 同上 |
| **proxy 上写 `reality-config` / listener 上写 `reality-opts`** | 静默失效 | `adapter/outbound/reality.go:13` vs `listener/inbound/reality.go:5` |
| **restls 系列** | proxy `restls-opts` ↔ listener **`res-tls`**；jls `jls-opts` ↔ `jls-config`；shadow-tls `shadow-tls-opts` ↔ `shadow-tls` | 见 §2.2.4 |
| **trojan ss 系列** | proxy `ss-opts`（复数）↔ listener `ss-option`（**单数**） | `adapter/outbound/trojan.go:67` vs `listener/inbound/trojan.go:28` |
| **客户端 `xhttp-opts` 写服务端字段** | `no-sse-header` / `sc-stream-up-server-secs` / `sc-max-buffered-posts` 静默丢弃 | 不在 `adapter/outbound/vless.go:93-119`；`transport/xhttp/config.go:53-55` 标 "server only" |
| **服务端 `xhttp-config` 写客户端字段** | `reuse-settings` / `session-table` / `session-length` / `headers` / `no-grpc-header` / `sc-min-posts-interval-ms` / `download-settings` 静默丢弃 | 不在 `listener/inbound/vless.go:38-60` |
| **`ech-opts.config` 配了但 `enable: false`** | 静默失效 | `adapter/outbound/ech.go:20-22` |
| **`ech-opts` 同时写 `config` 和 `query-server-name`** | `query-server-name` 静默失效 | `adapter/outbound/ech.go:24-31` |
| **anytls 只填 `ech-key` 不填证书** | ECH 静默不生效（加载被嵌在 `if cert && key` 内） | `listener/anytls/server.go:53-67` |
| **ss listener 写 `plugin`/`plugin-opts`** | 静默失效。listener 用 `simple-obfs` / `shadow-tls` / `res-tls` / `jls-config` / `kcp-tun` | `listener/inbound/shadowsocks.go:12-23` |
| **hy2 只填 `obfs-password` 不填 `obfs`** | 静默忽略，不报错 | 守卫是 `if len(option.Obfs) > 0`，`adapter/outbound/hysteria2.go:149` |
| **hy2 配 salamander 又配 `obfs-min/max-packet-size`** | 静默无效（只 gecko 分支读） | `adapter/outbound/hysteria2.go:158-159` |
| **tuic listener 写 `max-datagram-frame-size`** | 静默失效（只在 `listener/config/tuic.go:24`，不在 `listener/inbound/tuic.go`） | — |
| **`reality-opts` 只写 `short-id` 不写 `public-key`** | 静默失效，整块 REALITY 不启用 | `adapter/outbound/reality.go:21,45-46` |
| **vless 写 `ws-headers:`** | 静默失效。**死字段**，全仓无读取点 | `adapter/outbound/vless.go:83` |
| **snell 写 `plugin-opts`** | 静默失效。snell 用 `obfs-opts`，且无 `plugin` 字段 | `adapter/outbound/snell.go:41` |
| **ss proxy 写 `method:`** | 静默失效，只有 `cipher:` | `adapter/outbound/shadowsocks.go:48-49` |

### 3.2 `users` 形态：list vs map

| 协议 | listener 字段类型 | 证据 |
|---|---|---|
| vless | `[]VlessUser` **list** | `listener/inbound/vless.go:14`（`:32-36`） |
| vmess | `[]VmessUser` **list** | `listener/inbound/vmess.go:14`（`:32-36`） |
| trojan | `[]TrojanUser` **list** | `listener/inbound/trojan.go:14`（`:31-34`） |
| hysteria2 | `map[string]string` **map** | `listener/inbound/hysteria2.go:14` |
| tuic | `map[string]string` **map** | `listener/inbound/tuic.go:15` |
| anytls | `map[string]string` **map** | `listener/inbound/anytls.go:14` |
| shadowsocks | **无 `users`**，只有顶层 `password`+`cipher` 单值 | `listener/inbound/shadowsocks.go:12-23` |
| snell | **无 `users`**，只有顶层 `psk` | `listener/inbound/snell.go:13-22` |

> ✅ 核实用户已知的两条：**①** listener 端 vless/vmess/trojan **没有 `network` 字段** ✅（§3.1 第 3 行）；**②** listener 端 `users` **vless/vmess/trojan 是 list，hysteria2/tuic/anytls 是 map** ✅。补充第 3 条：**shadowsocks 和 snell 根本没有 `users`**。

### 3.3 `mihomo -t` 的严格性是「反的」

| 方向 | 行为 | 证据 |
|---|---|---|
| YAML 里**多写**了内核不认识的键 | ✅ **静默忽略，`-t` 通过，运行时也静默** | `common/structure/structure.go:566-581`（`dataValKeysUnused` 只喂 `remain` tag，喂完置 nil）；`:583` 的错误判定用的是 `targetValKeysUnused` 而非它；`ErrorUnused` 选项从未被置位 |
| YAML 里**少写**了 tag 不带 `,omitempty` 的字段 | ❌ **报错** `'xxx' has unset fields: a, b`（字母序） | `common/structure/structure.go:532-534`（`if !omitempty` 才记入）+ `:583-592`（排序+报错） |
| 顶层 YAML 解析 | 同样宽松，`yaml.Unmarshal` 无 `KnownFields(true)` | `common/yaml/yaml.go:8-10` |

**无 omitempty 的 tag = 事实必填**（这就是 §0 里 vmess `alterId`/`cipher` 必须写的原因）。完整清单见各协议 S 档。

**项目已有的对策**：`src/lib/validate.py` 用一份手写白名单做前置校验（`PROXY` 集合 `:184-227`、`LISTENER` 集合 `:129-177`、`TRANSPORT_OPTS` `:230-244`），在 `client.sh:139-141` 的 `cfg_check_strict` 里调用，失败就整体回滚（`client.sh:149-154`）。✅ 这个机制是对的，**本 spec 的字段全集可以直接用来补全它的白名单**。

> ⚠️ 但要注意：`validate.py:241-244` 的 `xhttp-config` 允许键集合**远少于**内核实际支持的 21 个（缺 `sc-max-buffered-posts`、`x-padding-method` 等），照本文 §2.5 补齐即可。

### 3.4 惰性校验：`mihomo -t` 抓不到，必须真连

| 类别 | 例子 | 证据 |
|---|---|---|
| **启动期报错**（`-t` 能抓） | REALITY public-key/short-id 格式 | `adapter/outbound/reality.go:28,37,41` |
| | 安全模式互斥 | `adapter/outbound/vless.go:549-551` |
| | `flow` 非法 | `adapter/outbound/vless.go:464-472` |
| | `xhttp mode` 非法 | `transport/xhttp/client.go:246-251` |
| | `ech-opts.config` base64 失败 | `adapter/outbound/ech.go:27` |
| | listener 侧 xhttp mode 非法 | `listener/sing_vless/server.go:200-206` |
| **运行期才报错**（`-t` 抓不到） | 🚨 **REALITY 没配 `client-fingerprint`** → 首次 TLS 握手才 `REALITY is based on uTLS, please set a client-fingerprint` | `transport/vmess/tls.go:130-132` |
| | 🚨 **`fingerprint` 写成浏览器名** → 首次连接才 `fingerprint is used for TLS certificate pinning...` | `component/ca/fingerprint.go:16-17`（经 `ca.GetTLSConfig` `component/ca/config.go:101-105`，在 `streamTLSConn` `adapter/outbound/vless.go:334`） |
| | `certificate`/`private-key` 路径或格式错 | `component/ca/keypair.go:53` |
| | WS 握手非 101 | `transport/vmess/websocket.go:465-468` |
| | gun ALPN 不匹配 | `transport/gun/gun.go:286` |
| **永不报错**（只 WARN 或静默） | `client-fingerprint` 写未知值 → `log.Warnln` + 降级为原生 TLS | `component/tls/utls.go:56-59` |
| | `network` 写未知值 → `default:` 当裸 TCP | `adapter/outbound/vless.go:258-262` |
| | `brutal`/`up`/`down` 单位不匹配正则 → 静默 0 | `common/utils/mbps.go:21-24` |
| | `udp-relay-mode` 写错 → 静默 native | `adapter/outbound/tuic.go:165-168` |
| | `congestion-controller` 写未知值 → 无 default 分支，保留内核默认 | `transport/tuic/common/congestion.go:20-53` |
| | ss `plugin` 写未知值 → if-else 链无 default，裸 SS | `adapter/outbound/shadowsocks.go:321-470,489` |
| | `padding-scheme` 里 `<=0` 的项 → 静默丢弃 | `transport/anytls/padding/padding.go:77-79` |

### 3.5 默认值陷阱（同一字段两侧不一致）

| 字段 | proxy 默认 | listener 默认 | 证据 |
|---|---|---|---|
| shadowsocks `udp` | **false** | **true** | `adapter/outbound/shadowsocks.go:50` vs `listener/parse.go:76` |
| snell `udp` | **false** | **true** | `adapter/outbound/snell.go:38` vs `listener/parse.go:83` |
| snell `version` | **1**（5→4，只收 1-4） | **4**（收 1-5） | `adapter/outbound/snell.go:244-261`、`transport/snell/snell.go:23` vs `listener/inbound/snell.go:45-50` |
| tuic `congestion-controller` | 空（=内核默认） | **`bbr`** | `listener/parse.go:130` |
| tuic `max-udp-relay-packet-size` | **1252** | **1500** | `adapter/outbound/tuic.go:170-172` vs `listener/parse.go:129` |
| hysteria2 listener `alpn` | — | `["h3"]` | `listener/sing_hysteria2/server.go:96-100` |
| shadow-tls `version` | 0 → **自动 2** | 0 → **直接报错** | `transport/shadowtls/client.go:54-57` vs `transport/shadowtls/server.go:58-60` |
| trojan `alpn` | TCP `["h2","http/1.1"]`；显式 `[]` → **空** | — | `adapter/outbound/trojan.go:106-109,153-156`（判空用 `!= nil`，源码注释 `:107`） |
| h2 `host` | 空 → **注入 `["www.example.com"]`** | — | `adapter/outbound/vless.go:561-564`、`adapter/outbound/vmess.go:573-576` |
| anytls `idle-session-*` | ≤5s → **强制 30s** | — | `transport/anytls/session/client.go:52-57` |
| hysteria2 `max-idle-time`（listener） | — | ⚠️ **死字段**，配了不生效 | `listener/inbound/hysteria2.go:24` |
| ss cipher 不支持时（listener） | — | ⚠️ **不是报错，是回退**到内嵌实现 | `listener/sing_shadowsocks/server.go:77-80` |

### 3.6 单位 / 格式陷阱

| 字段 | 单位 | 陷阱 | 证据 |
|---|---|---|---|
| `up` / `down` / `brutal.up` / `brutal.down` | 正则 `^(\d+)\s*([KMGT]?)([Bb])ps$` | **纯数字 = Mbps**；`K/M/G/T` 必须大写；**小写 `b` = bit(÷8)，大写 `B` = byte**；不匹配 → **静默 0** | `common/utils/mbps.go:9,16-19,26-44` |
| hy2 `hop-interval` | **秒**（string） | 只能单区间 `"15-30"`，写 `"15,30"` → `invalid range` | `adapter/outbound/hysteria2.go:248,261-262` |
| hy2 `handshake-timeout` | 秒（int） | — | `adapter/outbound/hysteria2.go:234` |
| hy2 `udp-mtu` | — | 默认 **1197** | `adapter/outbound/hysteria2.go:195-199` |
| tuic `heartbeat-interval` / `request-timeout` / `max-idle-time` / `authentication-timeout` | **毫秒** | — | `adapter/outbound/tuic.go:206`；`listener/tuic/server.go:98,156` |
| grpc `ping-interval` | **秒** | 0 = 不做健康检查 | `transport/gun/gun.go:310-311` |
| **`reality-config.max-time-difference`** | ⚠️ **微秒** | 与直觉的秒差 **10⁶ 倍** | `listener/reality/reality.go:57` |
| xhttp `h-keep-alive-period` | **秒（int）** | 同组另外 5 个是区间字符串 | `adapter/outbound/vless.go:127,638` |
| xhttp `sc-stream-up-server-secs` / `sc-max-buffered-posts` / `sc-max-each-post-bytes` / `sc-min-posts-interval-ms` | 字符串区间 `"N"` 或 `"min-max"` | 必须 > 0 | `transport/xhttp/config.go:196-235,327-359` |
| `reality-opts.short-id` | hex | **奇数长度会失败**；≤ 8 字节 | `adapter/outbound/reality.go:35-42`；`component/tls/reality.go:29` |
| kcptun `key` | — | 默认硬编码 `"it's a secrect"`（源码拼写） | `transport/kcptun/common.go:49-51` |

### 3.7 互斥 / 冲突

| 组合 | 结果 | 证据 |
|---|---|---|
| vless/vmess：`shadow-tls-opts` + `restls-opts` + `jls-opts` + `reality-opts` 多于一个 | **报错** `security modes are mutually exclusive` | `adapter/outbound/vless.go:536-551`；vmess `:556-564` |
| anytls listener：`certificate` 与 `shadow-tls`/`res-tls`/`jls-config` 多于一项 | **报错** `security modes are mutually exclusive` | `listener/anytls/server.go:85-100` |
| anytls listener：`shadow-tls`/`res-tls`/`jls-config` 三者多于一项 | **报错** | 同上 |
| ss listener：`shadow-tls`/`res-tls`/`jls-config` 多于一项 | **报错**；⚠️ **`simple-obfs` 不参与互斥** | `listener/sing_shadowsocks/server.go:83-95` |
| xhttp `mode: stream-one` + `download-settings` | **报错** | `adapter/outbound/vless.go:721-723` |
| xhttp HTTP/3 + 任意 security mode | **报错** `xhttp HTTP/3 does not support %s` | `adapter/outbound/vless.go:696-698,887-889` |
| vless `packet-addr` + `xudp` | 后者强制关前者 | `adapter/outbound/vless.go:474-485`；`adapter/outbound/vmess.go:496-498` |
| vless `flow: xtls-rprx-vision` + UDP | listener 侧**不支持 UDP** | `listener/sing_vless/service.go:137-139` |
| vless 安全模式 + `tls: false` | **报错** `%s requires TLS` | `adapter/outbound/vless.go:556-558` |
| 任意 `fingerprint` / `name-cert-verify` + `skip-cert-verify: false` | ⚠️ 前两者**强制 `InsecureSkipVerify=true`**，`skip-cert-verify` 被静默覆盖 | `component/ca/config.go:116,122` |
| hy2 `obfs` 有值 + `obfs-password` 空 | **报错** `missing obfs password` | `adapter/outbound/hysteria2.go:150-152` |
| vless `flow` 长度 ≥16 | ⚠️ **静默截断**到 16 字符 | `adapter/outbound/vless.go:464-465` |


---

## 4. 给实现者的落地建议

### 4.0 两个仍待修的 Bug（不是选配，是缺陷）

> ⚠️ **基线快照说明**：本文 §0 的基线取自 2026 年对 `src/conf/*.sh` 的一次原子快照。撰写期间这些脚本被并发修改过（`git status` 显示 `VLESS.sh` 等 11 个文件为 ` M`）。下表已按**最新快照**复核。若行号对不上，请以 `grep -n` 现场复核。

| # | 位置（最新快照） | 问题 | 修法 |
|---|---|---|---|
| ~~B1~~ | ~~`VLESS.sh` vless proxy 的 `sni:`~~ | ✅ **已被并发修改修复**：6 处客户端块已全部改为 `servername: $CLIENT_SNI`（快照行 `764, 788, 953, 976, 1085, 1108`）。内核证据仍有效：vless 只有 `servername`（`adapter/outbound/vless.go:89`），`sni` 会被静默丢弃（`common/structure/structure.go:566-581`） | — |
| **B2** | `src/conf/Trojan.sh:530, 545, 695, 711, 778, 794`（**全部在 `proxies:` 块内**，已逐处确认上下文） | trojan proxy 写 `tls: true`，但 **trojan 根本没有 `tls` 字段**（`adapter/outbound/trojan.go:45-69` 全文无 `proxy:"tls"`；只有 vless 有，`adapter/outbound/vless.go:65`）→ 静默丢弃 | 删掉这 6 行（trojan 永远走 TLS） |
| **B3** | `VLESS.sh:769, 793, 958, 981, 1090, 1113`；`Trojan.sh:548, 714, 797`；`AnyTLS.sh:302, 440, 502, 554`；`TUIC.sh:260, 385, 436` —— 共 **18 处**硬编码 `skip-cert-verify: true` | 生产环境无差别关闭证书校验 | 统一改成 hysteria2 已有的分支（`hysteria2.sh:459-463`）：证书可信 → `skip-cert-verify: false`；否则 → `fingerprint: $CERT_PIN`（`openssl x509 -outform DER \| openssl dgst -sha256 -hex`，参考实现 `参考实现/src/conf/anytls.sh:182-185`） |

外加：`src/lib/validate.py` 的 `xhttp-config` 白名单（`:241-244`）按 §2.5 补齐到 21 个键。

### 4.1 每个协议建议新增的选配（按优先级）

#### VLESS — Top 3

**① `client-fingerprint` 选配**（A；现在硬编码 `chrome`）
取值：`chrome` / `firefox` / `safari` / `ios` / `android` / `edge` / `random`（全表 §2.3.1；**不要**暴露 deprecated 的 5 个）。
```yaml
proxies:
  - name: vless-1
    client-fingerprint: firefox      # 用户选
```
listener 侧无需改动（服务端没有这个概念）。

**② xhttp `x-padding-*` 抗探测档位**（A；快照 `VLESS.sh:770-772` 等现在只写了 mode+path）
内核默认已有 `x-padding-bytes: "100-1000"`（`transport/xhttp/xpadding.go:180-186`）。建议给三档：
```yaml
    xhttp-opts:
      mode: stream-one
      path: /xhttp
      # 档 2「标准」：只调 bytes 区间
      x-padding-bytes: "100-1000"
      # 档 3「强化」：开 obfs mode，padding 变成可解码的混淆流量
      x-padding-obfs-mode: true
      x-padding-key: <随机 8-16 字节 base64url>
      x-padding-header: X-Pad
      x-padding-placement: query        # queryInHeader/cookie/header/query/path/body/auto
      x-padding-method: tokenish        # repeat-x / tokenish
```
**listener 侧必须同步**（这 7 个字段两侧同名，`listener/inbound/vless.go:42-47`）：
```yaml
    xhttp-config:
      mode: stream-one
      path: /xhttp
      x-padding-obfs-mode: true
      x-padding-key: <同一个 key>
      x-padding-header: X-Pad
      x-padding-placement: query
      x-padding-method: tokenish
```
> ⚠️ 强约束：`x-padding-key` / `x-padding-header` **仅在 `x-padding-obfs-mode: true` 时生效**（`transport/xhttp/config.go:503-509`），且两侧必须一致，否则客户端 padding 服务端解不开。

**③ mTLS + ECH 组合已有，建议补 `mux-option`**（A）
现在 proxy 有 smux 三档（快照 `VLESS.sh:341-352`，档位表在 `smux_profile()` `:241-248`），但**服务端没有任何对应配置**，导致 smux 档位实际上是对着空气调的。补：
```yaml
listeners:
  - name: vless-1
    type: vless
    # ...
    mux-option:
      padding: true                    # 对齐客户端 smux.padding
      brutal:
        enabled: false                 # 开了就把吞吐硬顶到 up/down
        up: "200 Mbps"
        down: "200 Mbps"
```

#### Reality — Top 2（协议本身已经很窄）

**① `client-fingerprint` 选配**（A，**硬约束**：REALITY 缺它会在首次握手报错 `REALITY is based on uTLS, please set a client-fingerprint`，`transport/vmess/tls.go:130-132`）
**② `xudp` / `packet-addr` 二选一**（A）—— 现在 Reality 快照 `:285,391` 用的是 legacy `packet-encoding: xudp`（`adapter/outbound/vless.go:70` 只认 `packetaddr`/`packet`，写 `xudp` 落 default 分支），**改成直白的 `xudp: true` 语义更清楚**（且 xudp 本来就默认开，`:478-481`）。

#### Trojan — Top 3

**① `client-fingerprint` 选配**（A，硬编码 `chrome`，快照 `Trojan.sh:527,546,692,712,775,795`）
**② `alpn` 选配**（A）—— ⚠️ 默认是 `["h2","http/1.1"]`（`adapter/outbound/trojan.go:153-156`），且**显式写 `alpn: []` 会得到空 ALPN 而非默认**（`:107` 源码注释）。建议只在用户明确要改时才写这个键。
**③ ws `v2ray-http-upgrade`**（A/B）—— 消掉 WS 首包的 1-RTT 往返，CDN 场景收益明显。
```yaml
proxies:
  - name: trojan-1
    type: trojan
    network: ws
    sni: example.com
    client-fingerprint: chrome
    ws-opts:
      path: /tr
      headers:
        Host: example.com
      v2ray-http-upgrade: true
      v2ray-http-upgrade-fast-open: true   # 必须配合 upgrade，单独写无效
```
listener 侧对应只有 `ws-path: /tr`（`listener/inbound/trojan.go:15`），**没有 upgrade 选项**。

#### VMess — Top 3

**① `global-padding` + `authenticated-length`**（A，**proxy-only，§2.1.1**）
⚠️ 必须警告用户：**这两个是客户端行为，服务端不需要配也无法配**（`listener/inbound/vmess.go:12-30` 无对应字段），且需要对端也支持。
```yaml
proxies:
  - name: vmess-1
    type: vmess
    uuid: ...
    alterId: 0            # ⚠️ S 档必填，无 omitempty（adapter/outbound/vmess.go:59）
    cipher: auto          # ⚠️ S 档必填（:60）
    network: ws
    tls: false
    global-padding: true
    authenticated-length: true
    ws-opts:
      path: /vm
```
> ⚠️ **对端警告**：如果对端不是 mihomo，开这两个可能直接握手失败（实现在外部库 `sing-vmess`，本机未找到证据）。

**② `alterId` 归零**（S）—— 现在 `all.sh:430,440` 写 `alterId: 0`，这是**正确的**（mihomo 内无废弃标记也无拒绝逻辑，`adapter/outbound/vmess.go:59` 纯透传），但必须在文档里说清「0 是唯一安全值」。

**③ `client-fingerprint`**（A）+ `ws-opts` 的 `v2ray-http-upgrade`（B）—— 同 Trojan。

#### Hysteria2 — Top 3（**收益最高**）

**① `obfs` 混淆**（A）—— 目前项目**完全没做**，而这是 hy2 最核心的抗探测手段。两侧完全对称：
```yaml
# 服务端 conf/config.d/
listeners:
  - name: hysteria2-1
    type: hysteria2
    listen: "0.0.0.0"
    port: 443
    users:
      user1: <password>
    obfs: salamander          # 或 gecko
    obfs-password: <随机>
    certificate: ...
    private-key: ...

# 客户端 out/
proxies:
  - name: hysteria2-1
    type: hysteria2
    server: example.com
    port: 443
    password: <同一个>
    sni: example.com
    obfs: salamander          # ⚠️ 与服务端逐字一致
    obfs-password: <同一个>
    up: "60"
    down: "200"
```
菜单建议直接给 **关 / salamander / gecko** 三选一。⚠️ **不要**单独暴露 `obfs-password`（不配 `obfs` 时静默忽略，`adapter/outbound/hysteria2.go:149`）；`obfs-min/max-packet-size` 只在 gecko 下有意义（`:158-159`）。

**② 原生 `ports` + `hop-interval` 端口跳跃**（A）—— 现在走 iptables DNAT（`hysteria2.sh:484-519`），**内核原生更优**（无需动防火墙、重启不失效）：
```yaml
proxies:
  - name: hysteria2-1
    type: hysteria2
    server: example.com
    port: 443
    ports: "30000-31000"       # 也支持 "1000-2000,3000"（≤28 段，common/utils/ranges.go:26-28）
    hop-interval: "30"          # ⚠️ string，单位秒；只能是单区间 "15-30"
    password: ...
```
> ⚠️ `hop-interval` 是**字符串**不是数字；`0<值<5` 会被抬到 5s（`adapter/outbound/hysteria2.go:253-257`）。listener 侧**没有**这两个字段。

**③ `masquerade` / `up`-`down` 选配**（A/B）—— `masquerade` 现在硬编码 `https://bing.com`（快照 `hysteria2.sh:634`），建议给 2-3 个预置（`https://www.bing.com` / `https://www.cloudflare.com` / 关闭）。

#### TUIC — Top 3

**① `congestion-controller` 选配**（A）—— 现在硬编码 `bbr`（`TUIC.sh:241,258`）。可选 `cubic` / `bbr` / `new_reno` / `bbr_meta_v2`。⚠️ **listener 默认就是 `bbr`**（`listener/parse.go:130`），建议两侧都显式写出来保持一致。
```yaml
listeners:
  - name: tuic-1
    type: tuic
    users:
      <uuid>: <password>
    congestion-controller: bbr
    alpn: [h3]

proxies:
  - name: tuic-1
    type: tuic
    uuid: ...
    password: ...
    sni: example.com
    congestion-controller: bbr
    udp-relay-mode: native
```
**② `udp-relay-mode` 选配**（A）—— `native`（默认，走 UDP 报文）/ `quic`（走 QUIC DATAGRAM）。⚠️ **写错字静默落 native**（`adapter/outbound/tuic.go:165-168`），所以务必从枚举里选。
**③ `reduce-rtt`（0-RTT）开关**（A）—— 降首包延迟，**代价是失去前向保密**，建议默认关。
```yaml
    reduce-rtt: true
```
⚠️ `disable-sni` **不要暴露**——它会连带强制 `InsecureSkipVerify=true`（`adapter/outbound/tuic.go:223-226`）。

#### AnyTLS — Top 3

**① `padding-scheme` 抗主动探测**（A，**唯一 listener-only 的加密类选配**）—— 项目完全没做，而参考实现 参考实现 **已经实现了同款菜单**（`<SB-repo>/src/conf/anytls.sh:146-179` 的 `ask_anytls_padding()`），可直接移植文案。
```yaml
listeners:
  - name: anytls-1
    type: anytls
    users:
      <uuid>: <password>
    certificate: ...
    private-key: ...
    # 档 2「显式写入默认」—— 行为与不写一致，但配置里看得见
    padding-scheme: |
      stop=8
      0=30-30
      1=100-400
      2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
      3=9-9,500-1000
      4=500-1000
      5=500-1000
      6=500-1000
      7=500-1000
    # 档 3「自定义」—— 每行 k=v，k=stop + 报文序号 0..6，v=min-max 或 c
```
> ⚠️ **格式差异**：sing-box 的 `padding_scheme` 是 JSON **数组**（`anytls.sh:212-220` 用 `jq`），mihomo 的 `padding-scheme` 是**单个 YAML 多行字符串**，Bash 里必须用块标量 `|` 输出。
> ⚠️ 唯一硬要求是有可解析的 `stop=`（`transport/anytls/padding/padding.go:51-55`），否则 listener 启动报 `incorrect padding scheme format`（`listener/anytls/server.go:128-130`）。
> ⚠️ **客户端不需要也不能配这个字段**，它走服务端下发（`transport/anytls/session/frame.go:14` + `session/session.go:274-283`）。

**② `idle-session-*` 参数化**（A）—— 现在硬编码 30/30（`AnyTLS.sh:300-301`）。⚠️ **≤5s 会被静默抬到 30s**（`transport/anytls/session/client.go:52-57`），所以菜单里不该给 < 6s 的选项。
```yaml
proxies:
  - name: anytls-1
    type: anytls
    server: example.com
    port: 443
    password: ...
    sni: example.com
    client-fingerprint: chrome
    udp: true
    alpn: [h2, http/1.1]
    idle-session-check-interval: 30   # 秒，≥6
    idle-session-timeout: 30          # 秒，≥6
    min-idle-session: 0
    disable-reuse: false
```
**③ `client-fingerprint` 选配**（A）—— anytls 是三个 QUIC 协议里**唯一有** `client-fingerprint` 的（hy2/tuic 只有 `fingerprint`，§1.4/§1.5）。

#### Shadowsocks — Top 3

**① `plugin: obfs` + 服务端 `simple-obfs`**（A）—— ⚠️ **两侧键名完全不同**（§3.1），这是 SS 选配里最容易写错的一个。
```yaml
# 服务端 conf/config.d/（注意：不是 plugin！）
listeners:
  - name: ss-1
    type: shadowsocks
    listen: "0.0.0.0"
    port: 8388
    cipher: aes-128-gcm
    password: <password>
    udp: true
    simple-obfs:
      enable: true
      mode: tls          # tls / http，其他值报错（listener/sing_shadowsocks/server.go:122-131）

# 客户端 out/
proxies:
  - name: ss-1
    type: ss
    server: example.com
    port: 8388
    cipher: aes-128-gcm
    password: <同一个>
    plugin: obfs
    plugin-opts:
      mode: tls
      host: www.bing.com   # ⚠️ 不写默认 bing.com（adapter/outbound/shadowsocks.go:322）
```
**② `plugin: shadow-tls` + 服务端 `shadow-tls`**（B）—— 高抗识别，但要开第二个端口。
```yaml
# 服务端
    shadow-tls:
      enable: true
      version: 3            # ⚠️ listener 侧必须显式写，0 会因 checkVersion 报错
      users:
        - name: u1
          password: <pw>
      handshake:
        dest: www.microsoft.com:443    # ⚠️ 无 omitempty，必填
# 客户端
    plugin: shadow-tls
    plugin-opts:
      password: <pw>
      host: www.microsoft.com          # ⚠️ 无 omitempty
      version: 3                       # 不写默认 2，与 listener 不一致 → 会失败
```
**③ `udp-over-tcp`（B/C）**—— SS 的 UDP 在很多网络被限速，UOT 是常用解法。⚠️ **listener 侧没有这个字段**，对应能力要靠 `kcp-tun.enable`（`listener/sing_shadowsocks/server.go:134-137`）。

> ❌ **不要暴露**：`plugin: shadowquic` / `plugin: sudoku`（不是 SS plugin，是独立顶层 type，`adapter/parser.go:114,177`）；`plugin: obfs-local`（**未找到证据**，只认 `obfs`）。

#### Snell — Top 2（协议窄）

**① `obfs-opts`（B）** —— ⚠️ snell 用 `obfs-opts` 不是 `plugin-opts`，且**没有 `plugin` 字段**。proxy 支持 `""`/`http`/`tls`/`shadow-tls`/`restls`/`jls` 六种（`adapter/outbound/snell.go:180-242`）；listener **只支持 `""`/`http`/`tls`**（`listener/snell/server.go:48-52`），另外三个是 listener 的独立顶层键。
```yaml
# 服务端
listeners:
  - name: snell-1
    type: snell
    listen: "0.0.0.0"
    port: 12345
    psk: <psk>
    version: 3
    udp: true
    obfs-opts:
      mode: tls
      host: example.com
# 客户端
proxies:
  - name: snell-1
    type: snell
    server: example.com
    port: 12345
    psk: <psk>
    version: 3          # ⚠️ 只收 1-4，写 5 会被降为 4（adapter/outbound/snell.go:248-251）
    client-fingerprint: chrome
    obfs-opts:
      mode: tls
      host: example.com
```
**② `version` 对齐**（S）—— ⚠️ proxy 支持 1-4（默认 1）、listener 支持 1-5（默认 4），**两侧必须显式写成同一个值**，别依赖默认值。

### 4.2 跨协议通用选配（建议做成面板的「全局选配」区）

| 选配 | 影响 | 证据 |
|---|---|---|
| `client-fingerprint` | vless / vmess / trojan / anytls / ss / snell（**hy2、tuic 没有此字段**） | §1 各节 |
| 证书校验模式：`skip-cert-verify: false` / `name-cert-verify: <域名>` / `fingerprint: <sha256>` | 全部有 TLS 的协议 | §2.3.2、§2.3.4 |
| `smux` 档位（web/video/download） | **全部 28 种 proxy 类型**（`adapter/parser.go:234`） | §2.4 |
| `smux.padding` / `statistic` / `only-tcp` | 同上；项目现在一个都没暴露 | `adapter/outbound/singmux.go:29-31` |
| `ech-opts` | vless / vmess / trojan / hysteria2 / tuic / anytls | §2.3.3 |
| mTLS（`client-auth-type` + `client-auth-cert` / proxy 的 `certificate`+`private-key`） | 全部 | §1 各节；已实现 |

### 4.3 实现顺序建议

1. **先修 B2/B3**（两个静默失效 Bug）—— 成本极低：B2 删 6 行，B3 是 18 处证书校验策略统一。
2. **补 `client-fingerprint` 全局选配**（一处改动，6 个协议受益）。
3. **hysteria2 `obfs`** —— 单协议、收益最高、两侧对称、实现最简单。
4. **anytls `padding-scheme`** —— 有 参考实现 现成菜单可抄（注意 YAML 块标量 vs JSON 数组的差异）。
5. **xhttp `x-padding-*` 档位** —— VLESS 的抗探测核心，但要两端同步，值得加个「一键同步」。
6. **证书校验三分支**（替换所有硬编码 `skip-cert-verify: true`）。
7. `mux-option` 与 smux 档位对齐、TUIC `congestion-controller` 选配、shadowsocks `plugin` 菜单。

---

## 附：未找到证据清单

1. `github.com/metacubex/sing-mux v0.3.12`（`go.mod:38`）里 `protocol` 的权威可选值；`adapter/outbound/singmux.go:102` 只透传。
2. `github.com/metacubex/sing-vmess`（`go.mod:43`）里 `ClientWithGlobalPadding()` / `ClientWithAuthenticatedLength()` 的内部填充与长度策略；`vmess.NewClient` 的 cipher 白名单；`alterID != 0` 是否被拒。（仓库无 `vendor/`、本机 module cache 为空、无 `go` 命令、网络 404。）
3. `github.com/metacubex/sing-shadowsocks2` / `sing-shadowsocks` 的 Method 全量列表与 2022-blake3 的 key 长度校验（`shadowaead_2022.List` 内容）。间接证据见 `test/ss_test.go:20-59`。
4. `github.com/metacubex/sing-quic/hysteria2`（`go.mod:39`）里 `ObfsTypeSalamander` / `ObfsTypeGecko` 的**字符串字面量**（文档佐证 `docs/config.yaml:1244,2716`）。
5. shadow-tls `version` 的合法取值范围（`listener/shadowtls/listener.go:30,50` 只做 `>1` 分支，未枚举；`transport/shadowtls/client.go:204-209` 只知 1..3 有效）。
6. `mux-option` 的 `cwnd-multiplier` 形式、`singmux` 的 `multiplex`/`multiplex-brutal` 枚举 —— 均**不存在**。
7. `ech-enable` / `ech-server-key` / `ech-config`(listener) / `ca` / `ca-str` / `ca-fingerprint` / `certificate-public-key` / `spider-x` / `obfs-local` —— 在 v1.19.32 中**均不存在**（全部 grep 确认）。
