# 架构与目录

## 整体

```
用户在面板里操作
      │
      ▼
  src/server.sh  (服务端面板)          src/client.sh  (客户端面板)
      │                                    │
      ├─► 生成配置片段                      ├─► 管理本地节点/订阅
      │   src/conf/*.sh                    ├─► 测速
      │   src/conf/all.sh (全协议一键)      ├─► DNS 管理
      │                                    └─► Web UI
      ├─► 校验  src/lib/validate.py
      ├─► CDN   src/lib/cdn.sh
      ├─► 证书  src/lib/cert.sh
      ├─► 分享  src/share/share.sh
      │
      ▼
  mihomo Meta 内核  ← mihomo -d <conf 目录>
      ▲
      │ nginx 回源 (可选, Docker 里)
      ▼
  Cloudflare (可选)
```

---

## 目录

```
src/
  server.sh          服务端面板主入口 (1401 行)
  client.sh          客户端面板主入口 (1900 行)
  core_install.sh    内核安装/更新

  lib/               公共库
    env.sh           环境探测、节点标签、绑定核对 (1654 行)
    cdn.sh           Cloudflare 绑定管理
    cert.sh          证书签发/续期/选择
    dns.sh           DNS 菜单与预设  ← 服务端和客户端共用
    validate.py      配置校验 (内核认不认这个键)
    merge.py         片段合并成完整配置
    portcheck.sh     端口占用检查
    fw.sh            防火墙
    lan_dispatch.sh  局域网分发
    core_mgmt.sh     内核版本管理
    dl_route.sh      下载走不走代理
    rules_bind.sh    规则集绑定
    simple_proxy.sh  简易 HTTP/SOCKS 节点
    ui.sh            UI 样式
    preset.sh        预设

  conf/              配置生成
    all.sh           全协议一键生成 (2431 行) ← 改协议档位看这里
    VLESS.sh  Trojan.sh  Reality.sh  TUIC.sh  AnyTLS.sh
    hysteria2.sh  XRevise.sh
    nginx_apply.py   nginx 配置改写

  share/
    share.sh         一次性分享链接

tools/               机械校验 (13 项门禁)
  check_all.sh       一键跑全部
  check_manifest.sh  清单漂移
  check_mirrors.sh   常量漂移
  check_wiring.sh    接线完整
  check_menu_ids.sh  菜单编号
  check_yaml_guard.sh yaml 取值守卫
  check_interfaces.sh 接口一致
  scrub.py           发布脱敏
  git-hooks/pre-push

docs/handover/       本目录
```

---

## 关键设计

### 配置是「片段 + 合并」, 不是一个大文件

每个节点生成一个独立片段, 放在 `conf/config.d/` 下,
由 `src/lib/merge.py` 合并成完整的 `conf/config.yaml`。

好处: 单个节点改坏了不影响其他节点, 删一个节点就是删一个文件。

```bash
conf/
  config.d/          每个节点一个 yaml (listeners)
  config.yaml        合并后的完整配置
  providers/         客户端: 每个订阅/本地节点一个 yaml
  certs/             证书
  cdn_bindings.tsv   CDN 绑定关系
out/                生成的客户端产物 *_client-*.yaml
```

---

### 两个校验体系, 分工不同

| | `validate.py` | `mihomo -t` |
|---|---|---|
| 查什么 | 内核**认不认**这个键 | 配置**语法**对不对 |
| 例子 | xhttp 写在 trojan 上 → 内核静默忽略 | 括号没配对 |
| 用途 | 拦「看起来生成了, 但永远连不上」的节点 | 拦语法错误 |

两者不能互相替代。`validate.py` 存在的理由是:**内核对不认识的键是静默忽略的**,
不专门查就发现不了。

---

### `lib/dns.sh` 服务端客户端共用

`DNS_MODE` 决定用哪套预设:
- `server` → `dns_preset_safe()`
- `client` → `dns_preset_client()`

客户端菜单通过把 `SRV_CONF` / `SRV_SERVICE` 指到客户端的路径来复用同一套菜单。

> ⚠ 改客户端 DNS 时**两个地方都要看**:
> `src/client.sh` 生成 `config.yaml` 的那段, 和 `dns_preset_client()`。
> 改漏一个, 用户从菜单 16 套用预设就会把旧值带回来。

---

## 环境变量开关

批量生成时可用:

| 变量 | 作用 |
|---|---|
| `M_TAG_PREFIX` | 节点名前缀, 默认 `m`。设为空则不带前缀 |
| `ALL_MKCP=1` | 额外生成 mKCP / Mekya 档位 |
| `ALL_VMESS=1` | 额外生成 VMess 的 4 个档位 |
| `ALL_PLAIN=1` | 额外生成 Shadowsocks / Snell |
| `ALL_CDN_GRPC=1` | 额外生成 CDN 的 gRPC 档位 |

> **mKCP 默认关闭是有原因的**, 别随手打开: 实测 mKCP 节点会让客户端内核**整个卡死**
> —— 端口还在听, 但不再出网, 连 sshd 都起不来。只能物理重启。
> mKCP 把 UDP 跑在 TCP 上再自己管重传/拥塞, 各版本行为不一致。

---

## 当前默认档位 (14 个)

| 类别 | 节点 |
|---|---|
| REALITY 直连 | mVLESS01/02/03 (tcp/grpc/xhttp), mTrojan01/02 |
| TLS 直连 | mTrojan03, mVLESS01-TLS-WS, mVLESS02-TLS-XHTTP |
| TLS 直连 (UDP) | mHysteria201, mTUIC01, mAnyTLS01 |
| CDN | mVLESS03-TLS-XHTTP-CDN, mVLESS04-CDN-WS, mVLESS05-CDN-gRPC → 已移出, mTrojan04-CDN-WS |

CDN 实际保留 3 个: XHTTP-CDN、VLESS-CDN-WS、Trojan-CDN-WS。

移出默认的原因见 [已知问题](known-issues.md)。