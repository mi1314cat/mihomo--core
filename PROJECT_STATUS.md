# mihomo--core 项目状态

> 定稿日期：2026-10-08
> 内核版本：Mihomo Meta **v1.19.32**
> 状态定义见文末。**只允许这四种标记**，没有第五种。

---

## 一句话结论

**功能上够用了。** 服务端 + 客户端两套面板可用，默认 14 个节点覆盖 REALITY / TLS
两层加密、四种传输、TCP + UDP 两个协议族，带 CDN 和一次性分享链接。
剩下的都是待优化项，不是待交付项。

排障和接手的材料在 [`docs/handover/`](docs/handover/README.md)，出问题先读那里。

---

## ✅ DONE

### 生成与部署

| 项 | 证据 |
|---|---|
| 全协议一键生成 | 生成 14 个节点，片段 / 产物一一对应 |
| 服务端口绑定核对 | 重生成后全部在监听 |
| 配置校验（内核认不认这个键） | `validate.py` 拦截"看起来生成了但永远连不上"的组合 |
| 端口冲突处理 | 区间用完自动回落随机空闲端口 |
| 证书签发 / 选择 / 续期 | 代码落到 `CERT_DIR`，写入前校验配对。**"有效期至某日"不是成果** —— 副本必须有机制跟着续期走，见下两行 |
| SAFE_PATHS 路径防护 | 已修（防护曾跑在选证书菜单之前，等于没写） |
| 批量挑证书按公钥真配对 | `find_cert` 原先按文件名配对、失败即用「第 0 张+第 0 把」位置兜底；实测在真实目录上 **0 命中**，即兜底每次都在走。已改为 SPKI 真比对 + 优先 CA 签发证书 |
| 配对校验不看证书在哪 | 原先「已在 conf/certs 内」会跳过全部校验，而批量路径的证书正是从那儿挑的。已前移 |
| `skip-cert-verify` 唯一真源 | 8 处 `${CERT_TRUSTED:+false}${CERT_TRUSTED:-true}` 在真证书下展开成 `falsetrue`，内核拒绝加载整个配置。已收敛到 `cert_client_skip_verify()` |
| 校验配置含证书落位 | 三道关（合并/字段/`mihomo -t`）都不看证书文件。已加第 4 道：文件在不在 + 私钥配不配 |
| 证书落位不撞名 | 域名限定 `cert-<域名>.crt` / `key-<域名>.key`（原先按 basename 落位，两个 LE 域名都写 `fullchain.pem`，证书+私钥一起被顶掉） |
| 续期后自动同步副本 | `src/lib/cert_sync.sh` + `mihomo-cert-sync.timer`（每天 03:30）。**面板里选中 LE 证书时自动接上，无需任何手工步骤**。**从 mihomo 配置反查**要维护哪些证书，域名读证书本体，不硬编码。<SERVER_ALIAS> 实测：漂移 → `--check` 报 `待刷新`(退出码 2) → 同步后副本与 LE 源逐字节一致，mihomo 未重启 |
| `skip-cert-verify` 条件化 | 已修 15 处写死 `true` 的模板 |
| 清理无对应节点的残留产物 | 菜单项可用 |

### CDN

| 项 | 证据 |
|---|---|
| Cloudflare 绑定 + nginx 回源 | WS 路径返回 101（隧道建立）、gRPC 路径返回 200 |
| nginx 配置改写 | `nginx_apply.py`，注意 nginx 跑在 Docker 里 |
| ECH | **已修复并验证可用**，7/7 CDN 节点通过 |
| CDN 节点名带 `CDN` 标识 | 已修 `m_node_tag` 丢第 5 个参数的问题 |

### 客户端

| 项 | 证据 |
|---|---|
| 基础配置 / 端口 / Web UI | 可用 |
| 订阅添加（分享链接 / 本地文件） | 可用 |
| **订阅可自定义组名** | 实测生效 |
| **自动更新默认改为手动** | 默认 `http` 而非 `http-auto` |
| **组名同步到组内节点名** | 实测两台服务器的节点名不再撞车 |
| 节点测速 | 面板可用 |
| DNS 管理菜单 | 可用 |
| 客户端 DNS 修复 | 去掉 `fallback-filter` / `#PROXY` / `respect-rules`，**实测是 ECH 能用的前提** |

### 分享

| 项 | 证据 |
|---|---|
| 一次性分享链接 | 生成后外部 `curl 200` |
| 用 N 次 / M 小时过期 | 参数化，自动生成不用手点 |
| 全协议生成完自动发一条 | 实测自动输出 |
| 分享服务自启 | 单元 inactive 时自动拉起 |

### 工程

| 项 | 证据 |
|---|---|
| 13 项机械门禁 | 全部通过 |
| 发布脱敏 | 干净 |
| 交互式菜单 | 主菜单 + 添加节点 10 项 |
| 交接文档 | `docs/handover/` 6 篇 1038 行 |

---

## 🟡 PARTIAL

### 默认档位（现状 14 个）

| 类别 | 数量 | 节点 |
|---|---|---|
| REALITY 直连 | 5 | mVLESS01/02/03 (tcp/grpc/xhttp)、mTrojan01/02 |
| TLS 直连 | 3 | mTrojan03、mVLESS01-TLS-WS、mVLESS02-TLS-XHTTP |
| TLS 直连（UDP） | 3 | mHysteria201、mTUIC01、mAnyTLS01 |
| CDN | 3 | mVLESS03-TLS-XHTTP-CDN、mVLESS04-CDN-WS、mTrojan04-CDN-WS |

**移出默认的**（生成器保留，`ALL_VMESS=1` / `ALL_PLAIN=1` / `ALL_CDN_GRPC=1` 开回来）：

| 移出项 | 原因 |
|---|---|
| VMess × 4 | 特征明显、探测成本低；两个 VMess-CDN 实测不通；性能不如 VLESS |
| Shadowsocks / Snell | **无加密**。已有 REALITY 和 TLS 时明文没有存在理由；Snell 协议早已停止维护 |
| CDN-gRPC × 2 | Trojan 直连也不通（内核侧）；VLESS 走 CDN 不通（CDN 侧），覆盖价值已被 WS / REALITY 满足 |

### 传输覆盖

| 组合 | 状态 |
|---|---|
| mKCP / Mekya | 能生成、能校验，**默认不生成**。实测会让客户端内核整个卡死（端口还在听但不出网，sshd 都起不来，只能物理重启） |
| h2 | 内核没有，不是漏写 |
| REALITY + ws | 实测 0/5，**不排** |
| xHTTP | 只有 VLESS 的 listener 支持 `xhttp-config`；写给 vmess/trojan 会被静默忽略 |

---

## 🔴 TODO

| 项 | 说明 |
|---|---|
| 切换产物 IP 版本 IPv6→IPv4 不生效 | `_ca_pick_family` 里 `oldip=$(m_addr4_real)` 算出来等于新值，结果什么都没改 |
| 回源域名重新探测的菜单项 | 证书/域名变更后只能删了重新生成 |
| 重命名节点组后前缀不同步 | 前缀在添加订阅那一刻定死，用菜单 7 改名后节点名还是旧前缀 |
| 现有订阅刷前缀 | 功能已实现，但存量订阅不会自动改名，要重新拉一次 |
| 生产环境未重新生成 | 生产机上的脚本还是旧版，产物里仍带旧 ECH 配置 |

---

## ⚠️ BLOCKED

| 项 | 说明 |
|---|---|
| Trojan + gRPC + TLS | **绕过 Cloudflare 直连源站同样不通**，与 CDN 无关。官方文档列了 grpc，所以不是"不支持"，是实现层面的问题。断点在客户端到 listener 之间 |
| VLESS + gRPC + CDN | 直连源站通，走 CDN 不通。反证：同批 VMess-gRPC 走 CDN 通，所以 Cloudflare 支持 gRPC；两条路径都到过 nginx 且返回 200，不是被边缘拦掉 |
| Cloudflare 面板侧排查 | 需人工登录 Security → Events 确认 Origin Rule / WAF 覆盖，脚本侧判断不了 |

---

## 状态定义

| 标记 | 含义 |
|---|---|
| ✅ DONE | 已实现，且**实测验证过**（不是"代码写了"，是"跑过了"） |
| 🟡 PARTIAL | 代码存在，但只完成一部分，或被有意移出默认 |
| 🔴 TODO | 确实没做 |
| ⚠️ BLOCKED | 因内核限制或外部环境等客观原因无法完成 |

---

## 接手时先读

1. [`docs/handover/README.md`](docs/handover/README.md) — 三条最重要的经验
2. [`docs/handover/troubleshooting.md`](docs/handover/troubleshooting.md) — 出问题从这里查
3. [`docs/handover/known-issues.md`](docs/handover/known-issues.md) — 已修复但根因静默的坑

> 这个项目绝大多数 bug 都是**静默失败**：面板正常、节点都在、就是连不上，
> 日志不指向任何东西。排障时先问"这一步到底有没有执行"，别假设它执行了。
