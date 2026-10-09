# mihomo--core 纯交互式端到端验证报告

- 执行方式：全程只用面板菜单驱动（`printf`/`script -qec` 喂 TTY），**未调用任何内部函数伪造成功**
- 被测版本：repo HEAD `b51e12c feat: unit 缺失时在「初始化基础配置」处提前提示`，`git status` 全程干净，**未改动任何代码**
- RN：`<SERVER_IP>:<SSH_PORT>`（Debian 13 / x86_64 / 1 核）
- CC：`192.168.1.178:22`（<CLIENT_OS> / aarch64 / 无公网出口）
- 备份：<SERVER_ALIAS> `/tmp/backup-rn.txt`（清空前 conf/out/share/unit/证书/nginx 全量清单），<CLIENT_ALIAS> `/tmp/backup-cc.txt`
- 清空产物留存（未硬删，便于回滚）：<SERVER_ALIAS> `/root/catmi/_wipe_rn_20261006-234441/`，<CLIENT_ALIAS> `/root/catmi/_wipe_cc_20261007-145354/`

> **部署同步说明（不是改代码）**：开测前 <SERVER_ALIAS> 的 `src/` 与 <CLIENT_ALIAS> 的 `src/` 都不是 HEAD。
> <SERVER_ALIAS> 的 `lib/server_extra.sh`、`lib/validate.py`、`client.sh` 是旧版（且 `server_extra.sh`
> 曾被上一个会话用 `cp /tmp/se.sh` 覆盖过）；<CLIENT_ALIAS> 整个 `src/` 都旧。已把 repo HEAD 的
> `src/` 部署到两端并用 md5 逐文件核对通过，否则测的不是 HEAD。

---

## 一、每一步结论

| 步骤 | 结论 |
|---|---|
| 第一步 清空两端 + 菜单重装 | **通过**（<SERVER_ALIAS>/<CLIENT_ALIAS> 均从零重装成功，服务 active），但发现 3 个问题 |
| 第二步 <SERVER_ALIAS> 逐协议手动生成 | **发现问题**：9 项里 7 项成功、VMess 完全失败、VLESS 生成即不可用 |
| 第三步 <SERVER_ALIAS> 全协议一键生成 | **通过**（22/22 成功、严格校验过、内核 `-t` 过、服务重载成功），但有 2 个统计/标注问题 |
| 第四步 <CLIENT_ALIAS> 拉取 + 测速 | **通过**（30 节点拉取成功，**实测 22/30 真实连通**，<CLIENT_ALIAS> 经代理访问外网 HTTP 200） |
| 第五步 汇总 | 共 14 条问题，见下 |

---

## 二、问题详细清单

### P1 —【高】「初始化基础配置」回答"取消"后，目录照样被创建

- **菜单**：服务端面板 → `3. 安装 / 内核管理` → `1. 初始化基础配置`
- **前置条件**：`/etc/systemd/system/mihomo.service` 不存在（全新机器）
- **操作**：进入该项，在「还要继续初始化吗? [y/N]:」输入 `n`
- **期望**：提示"已取消初始化"，且**不产生任何副作用**
- **实际**：屏幕打印 `[Info] 已取消初始化`，**但 `conf/` 与 `out/` 仍被完整创建**
- **有没有报错**：没有。恰恰相反，它明确说了"已取消"
- **证据**：
  ```
  请选择: [Warn] 还没安装系统服务 (mihomo.service 不存在)
  [Info] 「初始化基础配置」只生成配置文件, **不会**装 systemd 服务 —— 那一步在安装脚本里。
  [Info] 不装的话, 后面点「服务管理 → 启动」会报 Unit not found。
  [Info] 继续的话请运行:  bash /root/catmi/mihomo/src/core_install.sh
    还要继续初始化吗? [y/N]: [Info] 已取消初始化
  ```
  清空前 `rm -rf conf out`，跑完该项后：
  ```
  /root/catmi/mihomo/conf/certs/
  /root/catmi/mihomo/conf/config.d/.managed.json
  /root/catmi/mihomo/conf/config.yaml        (14 bytes = "listeners: []")
  /root/catmi/mihomo/out/
  ```
- **根因**：`src/lib/core_mgmt.sh:325`
  ```bash
  1) _core_warn_missing_unit "$root" "$svc"     # 返回 1 表示用户取消
     if [[ "$svc" == "mihomo" ]]; then
     bash "$root/src/server.sh" init \           # ← 与上一行之间没有 &&
  ```
  `_core_warn_missing_unit` 的返回值没被接住，`server.sh init`（内含 `ensure_dirs`）照跑。

---

### P2 —【高】「添加节点 → 2) VLESS」进的是**管理面板**，不是新增向导；且与「管理节点」是同一段代码

- **菜单**：服务端面板 → `1. 添加节点` → `2) VLESS`
- **期望**：直接进入"新增 VLESS 配置"向导，一路回车建出一个节点
- **实际**：进入「Mihomo VLESS 管理面板」，还要再选一次 `2. 新增配置` 才建节点
- **有没有报错**：无报错，但**一路回车会建不出任何节点**——30 个回车全被这个二级菜单吃掉，屏幕刷满 `无效选项: `，`conf/config.d/` 仍是空的
- **证据**：
  ```
     2) VLESS                    (WS / xHTTP / gRPC / H2 / TCP · 仅 TLS)
  请选择 [1-10, 0=返回]: ╔══════════════════════════════════════════════╗
  ║ Mihomo VLESS 管理面板                  ║
  ╚══════════════════════════════════════════════╝
     1. 查看配置
     2. 新增配置
     3. 删除配置
     4. 重建客户端文件
     5. 导出所有节点订阅（Clash/Mihomo）
     6. 查看 Nginx 转发配置
     0. 退出
  请选择:   无效选项:
  ```
- **影响范围**：`Reality.sh / VLESS.sh / Trojan.sh / hysteria2.sh / TUIC.sh / AnyTLS.sh` 六个脚本末尾都是 `main_menu`（管理菜单）。所以主菜单的 **`1. 添加节点` 和 `2. 管理节点` 对这 6 个协议是同一个菜单**（`src/server.sh:227-231` 与 `352-356` 除标题外逐字相同），只是 `8/9` 两项（VMess/SS/Snell）走 `all.sh --only`，行为不同。
- **根因**：`src/server.sh:230` 直接 `bash "$script"`，脚本末尾是 `main_menu` 而不是新增流程。

---

### P3 —【高】VMess 菜单项**完全不可用**，一个节点都生成不出来

- **菜单**：服务端面板 → `1. 添加节点` → `7) VMess (TCP+Reality / gRPC+Reality / WS 三种一起生成)`
- **期望**：生成 3 个 VMess 节点
- **实际**：直接报错退出，`config.d/` 无任何新增
- **有没有报错**：有，但指向内部标识符，用户无从下手
- **证据**：
  ```
  请选择 [1-10, 0=返回]: [Info] 生成 VMess (走 all.sh --only vmess-reality,vmess-grpc,vmess)
  ║  一键生成全协议节点                              ║
    将要问的: 证书 → 对外地址 → 端口区间
  [Error] 无法识别的协议标识: vmess
  [Error] 可用: reality reality-grpc reality-xhttp vmess-mkcp vmess-mekya cdn-v-ws cdn-v-grpc
         cdn-m-ws cdn-m-grpc cdn-t-ws cdn-t-grpc trojan trojan-grpc vmess-reality vmess-grpc
         trojan-tls vless-ws xhttp-tls xhttp-cdn hysteria2 tuicv5 anytls ss snell
  ```
- **根因**：`src/server.sh:164`
  ```bash
  BATCH_PROTO_ONLY=("vmess-reality,vmess-grpc,vmess" "ss" "snell")
  ```
  第三个标识 `vmess` 不在 `src/conf/all.sh:566` 的 `ALL_GEN_IDS` 里（合法的第三个是 `cdn-m-ws`）。`check_only_tokens` 校验后直接 `return 1`，整批中止。
- **对照**：`ss` 和 `snell` 两个菜单项正常，各生成 1 个节点。

---

### P4 —【高】VLESS 节点的分享链接 / 客户端配置端口**硬编码 443**，与实际监听端口不符 → 节点生成即不可用

- **菜单**：服务端面板 → `1. 添加节点` → `2) VLESS` → `2. 新增配置`（一路回车）
- **期望**：摘要、分享链接、客户端配置三处的端口一致，且节点可连
- **实际**：
  - 向导摘要：`端口: 31857`，`[OK] VLESS 配置生成成功`
  - `conf/config.d/vless-01.yaml`：`port: 31857`
  - `out/vless_share-01.txt`：`vless://f3393c96-...@<SERVER_DOMAIN>:443?...type=tcp#mVLESS01-TLS`
  - `out/vless_client-01.yaml`：`port: 443`
- **有没有报错**：无。同一屏里两个端口互相矛盾，没有任何提示
- **实测后果**：<CLIENT_ALIAS> 拉取后测速，该节点 **失败**
  ```
       失败  Vless         mVLESS01-TLS
  可用 22/30
  ```
- **根因**：`src/conf/VLESS.sh:371-374` 与 `:431` 对所有传输都写死 `:443`：
  ```bash
  tcp) SHARE_LINK="vless://$UUID@$CLIENT_HOST:443?...&type=tcp$ech#$tag" ;;
  ...
      port: 443
  ```
  它隐含假设"nginx 在 443 四层透传到随机端口"。但向导紧接着问
  `这台机器上的 Nginx 要不要直接配好？ 1)插入到 Nginx 站点 2)跳过, 我自己粘贴  请选择 [2]:`
  ——**默认是跳过**，什么都不装。而且它给出的 `out/vless_nginx-01.conf` 是
  ```nginx
  stream { server { listen 443; proxy_pass 127.0.0.1:31857; } }
  ```
  这与本机已在 443 跑 CDN 站点的 nginx **直接冲突**，用户也没法照抄。
- **同类检查**：Trojan / hysteria2 / TUIC / AnyTLS / Reality 脚本里**没有**硬编码 443，问题仅限 VLESS。

---

### P5 —【中】VLESS 推荐配置表里有 4 个 REALITY 档，但 VLESS.sh 一行 reality 都没有 → 一路回车"选中的预设"与"生成的节点"不是一回事

- **菜单**：同上，走到 `VLESS 推荐配置` 一路回车
- **期望**：一路回车 = 套用标称的预设
- **实际**：面板明确报告 `已套用预置: ① 隐匿优先 · REALITY` / `节点名后缀: REALITY`，但产出的是纯 TLS
- **有没有报错**：无。**没有任何一句提示说"本协议不支持 REALITY，已降级为 TLS"**
- **证据**：
  ```
  请选择 [1-10, 0=返回]: ... VLESS 推荐配置 ...
       1) ① 隐匿优先 · REALITY        裸TCP + XTLS Vision; 抗 DPI 最强; 不用证书
       2) ② gRPC 伪装 · REALITY         ...
       3) ③ gRPC 高并发 · REALITY      ...
       4) ⑤ xHTTP · REALITY (M 独有)    ...
       5) ⑥ xHTTP · 真证书 (M 独有)  ...
  选择 (默认: 1): [OK] 已套用预置: ① 隐匿优先 · REALITY
  [Info] 节点名后缀: REALITY
  [Info] 传输方式 (来自推荐配置): tcp
  ...
  [OK] VLESS 配置生成成功 ... 传输: 裸 TCP
  ```
  产出的 `conf/config.d/vless-01.yaml`：
  ```yaml
  listeners:
    - name: mVLESS01-TLS          # 名字后缀是 -TLS，不是 -REALITY
      type: vless
      port: 31857
      certificate: .../cert-01-fullchain.pem   # 用了真证书
      private-key: .../cert-01-privkey.pem
  ```
- **根因**：
  - 菜单 `2) VLESS` 的说明写着「仅 TLS」，Reality 是独立的 `1) Reality` 脚本；
  - `grep -c reality src/conf/VLESS.sh` = **0**；
  - 但 `src/lib/preset.sh:45-53` 的 `vless` 预设表里 ①②③⑤ 四档的证书维度都写着 `reality`。

---

### P6 —【中】smux 预设字段 `off` 被当成"已启用" —— 摘要、客户端配置、服务端三处互相打架

- **菜单**：`1. 添加节点` → `2) VLESS` → `2. 新增配置`（一路回车）
- **期望**：预设说 smux = off → 服务端不开 smux、客户端不开 smux、摘要显示"未启用"
- **实际**：
  - 摘要：`smux: 已启用 (off 档, brutal 200 Mbps/500 Mbps)`
  - `out/vless_client-01.yaml` 里真的写了 `smux: {enabled: true, protocol: smux, ...}`
  - `conf/config.d/vless-01.yaml` 只有 `mux-option: padding: true`，**没有任何 `smux` 块**
  - 片段头部注释：`# smux: off`
- **有没有报错**：无。三处自相矛盾，**这正是"界面显示成功但配置不是你要的"**
- **根因**：
  - `src/conf/VLESS.sh:698` `render_smux()` 用 `[[ -z "$SMUX_PROFILE" ]] && return` 判断；预设字段值是字符串 `"off"`（`src/lib/preset.sh:45` 第 3 段），非空 → 继续 → 写 `smux.enabled: true`
  - `src/conf/VLESS.sh:1240` `[[ -n "$SMUX_PROFILE" ]] && echo "smux: 已启用 (...)"` —— "off" 非空 → 打印"已启用"
  - 同行的 `${BRUTAL_ENABLED:+, brutal $BRUTAL_UP/$BRUTAL_DOWN}`：`BRUTAL_ENABLED="false"` 是非空字符串 → 也被展开，于是 brutal 参数凭空出现
  - 同一模式在 `Trojan.sh:753` / `Reality.sh:412` / `AnyTLS.sh:516` 也有（只是这些协议的预设没给 `off` 才没暴露）
- **说明**：我没有把 P6 认定为 mVLESS01-TLS 测速失败的**原因**（P4 的端口 443 才是主因）；这里只报告"配置与摘要不符"这一已确证的事实。

---

### P7 —【中】AnyTLS 预设 `② 真证书` / `③ 真证书 + padding` 是**死选项**，向导从不问证书路径

- **菜单**：`1. 添加节点` → `6) AnyTLS` → `2. 新增配置`
- **期望**：选 ② 能用本机真证书（本机明明有 `<SERVER_DOMAIN>` 的 certbot 证书）
- **实际**：证书在问预设**之前**就被无条件生成死了；选 ② / ③ 什么都不会变
- **有没有报错**：无
- **证据**：
  ```
  请输入监听端口 (默认: 50877): [Info] 生成自签证书 (ECDSA P-256, 叶子证书, 10年): cloudflare.com
  [OK] 自签证书生成完成: /root/catmi/mihomo/conf/certs/cert-cloudflare.com.crt
  ║ AnyTLS 推荐配置 (不想选就一路回车, 逐项自己配) ║
       1) ① 自签 (pin) · 通用         自签证书 + 钉扎; 一路回车就能建, 无需先备 crt/key
       2) ② 真证书                      CA 可信证书, 客户端无需 insecure/钉扎; 需先备好 crt/key
       3) ③ 真证书 + padding            在真证书基础上开 padding 填充, 改变流量形状
  选择 (默认: 1): [OK] 已套用预置: ① 自签 (pin) · 通用
  ...
  [OK] AnyTLS 配置生成成功 ... SNI: cloudflare.com
  ```
- **根因**：
  - `src/conf/AnyTLS.sh` 中 `grep -n "ask_cert" = 0`（其余 5 个协议都有），没有任何输入证书路径的机会
  - `src/conf/AnyTLS.sh:add_config()`：`DOMAIN="cloudflare.com"; generate_cert "$DOMAIN"` 写死在 `preset_ask` 之前
  - `src/lib/preset.sh` 把第 5 段解析进 `M_PRESET_CERT`，但 **全项目没有任何一处读它**（`grep -rn M_PRESET_CERT` 只命中 preset.sh 自身的 3 行）
  - 另外 `NODE_TAG="$(m_node_tag AnyTLS "$index" tls)"` 把 tag 写死成 `tls`，所以预设名里的"自签/真证书"连节点名都体现不出来（实测节点名 `mAnyTLS01-TLS`）

---

### P8 —【中】`fetch_script` 的 shebang 检查误杀合法脚本，Reality/Trojan 的伪装域名优选**从未成功过**

- **菜单**：`1. 添加节点` → `3. Trojan` → `2. 新增配置` → 安全模式选 `2) Reality` → 伪装域名留空
- **期望**：自动优选伪装目标域名
- **实际**：下载到的是合法脚本，被面板当成"不像可执行脚本"丢弃，退回硬编码 `www.microsoft.com`
- **有没有报错**：有三条，且指向的是下载内容而不是真正原因
- **证据**：
  ```
  Reality 伪装目标域名 (回车=自动优选 domains.sh): [Info] 未输入域名, 调用统一域名优选 domains.sh...
  [Warn] 下载内容不像可执行脚本, 已丢弃: domains.sh
  [Error] domains.sh 未返回有效域名
  [Error] 域名优选失败, 使用默认 www.microsoft.com
  ```
  手动 curl 同一 URL 完全正常：
  ```
  $ curl -sSL -o /tmp/d.sh -w "http=%{http_code} size=%{size_download}\n" \
      "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh"
  http=200 size=7837
  $ head -c 8 /tmp/d.sh | od -c
  0000000  \n   s   o   u   r   c   e
  $ bash -n /tmp/d.sh && echo SYNTAX_OK
  SYNTAX_OK
  ```
- **根因**：`src/lib/env.sh:100`
  ```bash
  if head -c 2 "$tmp" | grep -q '#!'; then
  ```
  只看**前 2 个字节**。该文件第 1 字节是换行、第 2 字节是 `s`，于是被判为非脚本。而且 `print_warn` 之后是 `return 1`，**直接跳出镜像循环**，备用源 `OCS_PROXY` 根本没试。
- **附带**：`src/lib/env.sh:522` 注释写着"本地内置一份常用清单 …… 不再强依赖外部 domains.sh"，但 `Trojan.sh:88` 仍走下载路径，这条兜底没被用上。

---

### P9 —【中】状态栏「运行中的协议端口」统计区间与实际端口分配区间不符，**长期少报甚至报 0**

- **菜单**：服务端面板主菜单底部状态栏（每屏都显示）
- **期望**：数字 = 正在监听的协议端口数
- **实测**：4 个节点、4 个真实 socket，面板显示 **1**
- **证据**：
  ```
    服务: 运行中 内核: Mihomo Meta v1.19.32 linux amd64 ...
    监听配置: 4        节点: 4    分享端口: 9443
    运行中的协议端口: 1 (TCP+UDP, 20000-29999)
  ```
  实际：
  ```
  tcp LISTEN *:31857  users:(("mihomo",...))      ← vless-01
  tcp LISTEN *:56676  users:(("mihomo",...))      ← trojan-01
  udp UNCONN *:56904  users:(("mihomo",...))      ← hysteria2-02
  udp UNCONN *:21168  users:(("mihomo",...))      ← hysteria2-01
  ```
  逐级拆解过滤器：
  ```
  awk '{print $4}'            → *:31857 *:56676 *:56904 *:21168
  sed -n 's/.*:\([0-9]\{1,5\}\)$/\1/p' → 31857 56676 56904 21168   (这一步是对的)
  awk '$1>=20000 && $1<=29999' → 21168                            (这一步丢 3 个)
  ```
- **根因**：`src/server.sh:76-79` 只统计 **20000–29999**，而 6 个单协议向导的默认端口都是
  ```bash
  random_port() { shuf -i 10000-60000 -n 1; }    # VLESS.sh:211 Trojan.sh:135 hysteria2.sh:72 TUIC.sh:53 AnyTLS.sh:72 Reality.sh:59
  ```
  平均约 **60%** 的节点端口落在 29999 以上。若某批节点端口全在 30000+，这一行会显示 **0**，用户会以为节点全挂了。
- **同样的 bug 出现两处**：`src/server.sh:79`（状态栏）与 `update_config()` 里的"占用端口"行（注释还写着"与 status_block 口径一致"）。31 节点时"占用端口"只列出 20000-20021 + 21168，漏掉 31857 / 56676 / 56904 / 38899 / 50877 / 1024 / 1025 / 10808。
- **为什么 `全协议一键生成` 看起来正常**：只有 `all.sh` 用 20000 起的区间，所以那 22 个节点全落在范围内，数字对得上 —— 两条生成路径的口径不一致。

---

### P10 —【中】`--quick` 生成的 6 个 CDN 档节点标"成功"，但实际全部不可用，且免责说明在 100 行之前

- **菜单**：`1. 添加节点` → `10) 全协议一键生成` → `2. 快速生成`（CDN 回源域名填了 `<SERVER_DOMAIN>`）
- **期望**：填了 CDN 域名 → 6 个 CDN 档节点挂上回源、可用
- **实际**：`--quick` 路径直接跳过 CDN 回源，`cdn_bindings.tsv` 没有新增任何记录；结果表仍标"成功"
- **有没有报错**：无错误，只有一句很靠前的提示
- **证据**：
  ```
  ② 之二、CDN 回源 —— Cloudflare 要能回源到 CDN 档位节点
     — --quick 且未设 CDN_DOMAIN (批量不提问)
     将生成 xhttp-cdn 源站, 但不会写入 Nginx 回源 —— 该节点需要你之后在
     服务端面板 → CDN 回源 挂一次。无人值守请设 CDN_DOMAIN=你的域名
  ...
  生成结果
    协议             端口   状态   备注
    CDN: VLESS+WS      20011    成功
    CDN: VLESS+gRPC    20012    成功
    CDN: VMess+WS      20013    成功
    CDN: VMess+gRPC    20014    成功
    CDN: Trojan+WS     20015    成功
    CDN: Trojan+gRPC   20016    成功
  汇总  成功 22 · 跳过 0 · 失败 0
  ```
  `cdn_bindings.tsv` 仍是清空前那 7 条旧记录，没有任何新增。<CLIENT_ALIAS> 测速结果：
  ```
       失败  Trojan         mTrojan06-CDN-gRPC
       失败  Trojan         mTrojan05-CDN-WS
       失败  Vless         mVLESS06-CDN-gRPC
       失败  Vless         mVLESS05-CDN-WS
       失败  Vmess         mVMess04-CDN-gRPC
       失败  Vmess         mVMess03-CDN-WS
  ```
- **定性**：代码行为本身是"诚实"的（明确说了会跳过），但**结果表把不可用的节点标成"成功"**，且提示与结果相隔约 100 行。用户扫一眼"成功 22"就会认为全通。
- 另外：我在第②步输入的 CDN 域名被静默忽略，`--quick` 不提示"你填的域名没用上"。

---

### P11 —【中】服务端装完后，"管理面板"提示指向的是**客户端**面板

- **菜单**：`3. 安装 / 内核管理` → `2. 安装 / 重装内核`（服务端，服务名 `mihomo`）
- **期望**：提示 `bash /root/catmi/mihomo/src/server.sh`
- **实际**：提示 `bash /root/catmi/mihomo/src/client.sh`
- **证据**：
  ```
    安装目录: /root/catmi/mihomo
    配置目录: /root/catmi/mihomo/conf
    节点目录: /root/catmi/mihomo/conf/config.d
    管理面板: bash /root/catmi/mihomo/src/client.sh      ← 服务端安装
  ```
- **根因**：`src/core_install.sh:838-839`
  ```bash
  _panel="server.sh"
  [[ -f "$INSTALL_DIR/src/client.sh" ]] && _panel="client.sh"
  ```
  注释写的是"面板脚本名按本机实际存在的那一个来定 —— 服务端是 server.sh, 客户端是 client.sh"，但服务端安装目录里 **两个文件都在**（主菜单第 17 项就是"切换到客户端面板"），所以这个条件永远为真。新用户装完服务端，被引导去打开客户端面板。

---

### P12 —【低】「安装 / 内核管理」菜单里"服务"一行下面多出一行孤立的 `inactive`

- **菜单**：`3. 安装 / 内核管理`（服务未运行时）
- **实际**：
  ```
      内核       : 未安装
      服务       : inactive
  inactive
  ```
  服务运行时（`active`）这行就不出现。
- **根因**：`src/lib/core_mgmt.sh:310`
  ```bash
  ui_kv_ascii "服务" "$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
  ```
  `systemctl is-active` 对 inactive 退出码是 3，于是 stdout 上先输出 `inactive` 再执行 `|| echo inactive`，命令替换捕获到两行。

---

### P13 —【低】菜单/文案一致性

- 客户端主菜单里 **`20. 重命名节点组` 插在 `6` 和 `7` 之间**，数字不连续（`src/client.sh:1146`）。
- 各协议子菜单的提示词不统一：VLESS/Trojan 用 `请选择:` + `按回车继续...`；Hysteria2/TUIC 用 `选择:` + `回车继续...`；TUIC 的 `0. 退出配置`、其它是 `0. 退出`。
- 各单协议面板在 `--quick` 批量生成后并不列出自己那批的结果，用户要回到主菜单点 `11. 查看当前节点` 才看得到。
- 空回车在服务端主菜单/core_menu 被静默忽略（直接重绘），在 `_all_run` 里则打印 `无效选项: `（后面跟一个空值），行为不一致。

---

### P14 —【低】分享链接的"对外地址"输入无任何校验

- **菜单**：`7. 生成分享链接` → 在「分享服务对外地址」处输入任意字符串
- **实际**：`out/share_addr.txt` 被写成该字符串，`out/share_tag-<tag>.txt` 拼出 `http://<输入>:9443/share/<token>`，面板照样打印 `[OK] 已生成分享链接`
- **证据**（第一次跑分享时喂进去一个 `0`）：
  ```
  $ cat /root/catmi/mihomo/out/share_addr.txt
  0
  $ cat /root/catmi/mihomo/out/share_tag-all.txt
  http://0:9443/share/<HEX32>
  ```
- **定性**：这是**我的输入污染**造成的（提示语确实写明"若不对请直接输入正确地址"），第二次正常跑得到 `<SERVER_IP>`。所以**不算功能性 bug**，但"输入 `0` 也照单全收并生成一条死链接"值得加个格式校验。

---

## 三、确实验证通过的功能

**安装 / 重装**
- <SERVER_ALIAS> 清空后经 `3→2` 重装成功：内核 `Mihomo Meta v1.19.32 linux amd64` 下载、冒烟测试、建 unit、启动全通
- <CLIENT_ALIAS> 清空后经 `15→2` 重装成功：正确识别 aarch64 下 `linux arm64` 内核，走本地代理 `http://127.0.0.1:10808` 下载成功
- <CLIENT_ALIAS> `1. 初始化基础配置` 成功：`mixed-port` 从 `0`（未启用）变成 `7890`，`allow-lan: true`，服务重启
- 缺 geosite 时给出明确告警 `[WARN] 缺少 geosite 数据, 已跳过 GEOSITE 规则`，不静默

**逐协议生成（`conf/config.d/*.yaml` + 合并 + 严格校验 + `mihomo -t` + 重启，全部实到）**
- VLESS ✅ / Trojan(REALITY) ✅ / Hysteria2 ✅ / TUIC v5 ✅ / AnyTLS ✅ / Shadowsocks ✅ / Snell ✅
- 每个都验证了 **socket 真的 bind 上**（`ss -tulnp | grep mihomo` 逐个核对）
- 证书扫描能识别 certbot 证书，并自动复制到 `conf/certs/`，还提示了 LE 符号链接不会随续期更新（提示质量很好）

**SOCKS 入站**
- 空用户名时正确报错 `[Error] 用户名不能为空` 并中止（必填项校验到位）
- 正常创建后 `127.0.0.1:10808` 真的在监听，**功能性验证**：正确账密 `http=200`，错误账密 `http=000`（拒绝）

**全协议一键生成**
- `1. 先预览` dry-run：22 项全"预览"、`未写入任何文件`、表格中文列对齐正确
- `2. 快速生成`：**22/22 成功**，端口 20000-20021 自动顺延不冲突，合并 31 个 listener，严格校验过，`mihomo -t` 成功，服务重载成功

**跨机 E2E（第四步）**
- <SERVER_ALIAS> `7→7` 安装分享服务：健康检查 `http://127.0.0.1:9443/status` 返回 200
- <SERVER_ALIAS> `7→1` 生成分享链接：`http://<SERVER_IP>:9443/share/363ead7b...`，外部 curl 200
- <CLIENT_ALIAS> `2. 添加节点` 填订阅 URL：**30 个节点**写入 `conf/providers/`，自动更新登记成功（`kind: http-auto`），`[Info] 已剔除 8 个内核不认的字段`
- <CLIENT_ALIAS> `10. 节点测速`：**可用 22/30**，延迟 168ms–227ms，表格按延迟排序，中文对齐正常
- <CLIENT_ALIAS> 经 `127.0.0.1:7890` 访问外网 `http=200`，日志确认走 `match Match using PROXY[mAnyTLS01-TLS]`；<CLIENT_ALIAS> 直连外网 `000`（符合"无公网出口"的设定）

**其它**
- `9. 校验配置 + 重载`：合并 / 严格字段 / `mihomo -t` 三道关全过，并重载
- `11. 查看当前节点`：31 行列表，UTF-8 正常、列对齐正常，**全流程未见中文乱码或表格错位**
- 全程**未出现** `set -u` 未定义变量导致的静默退出

---

## 四、明确**未**验证到的部分

- **6 个 CDN 档节点**：从未在 nginx 上真正配置过 Cloudflare 回源，因此不能判断"CDN 档节点在回源配好之后是否可用"——本次只能确认它们**当前不可用**且面板标了"成功"（P10）
- **mVLESS03-TLS-XHTTP**（`<SERVER_IP>:20009` 直连、xhttp）测速失败。P4 的端口错配只影响 `mVLESS01/04`，这个节点的订阅端口与 listener 一致，**失败原因未定位**（未单独排查内核 xhttp 行为）
- **mVLESS01-TLS 的客户端 `smux.enabled: true` 是否导致握手失败**：未单独验证（P4 已是充分失败原因，无法区分）
- **ECH（Cloudflare Encrypted Client Hello）分支**、**mTLS 分支**：全程回车默认关闭，未走
- **「重建」档位（`_all_rebuild`）**、「不含证书」档位、「只生成指定协议」档位：未跑
- **「拉取节点（从订阅导入）」**（服务端第 8 项）、**「查看已拉取订阅」**：未跑
- **出站 / 规则集 / 端口转发**（第 18 项）、**防火墙**（第 4 项）、**DNS 管理**（第 6 项）：未跑
- **卸载流程**（服务端 16 / 客户端 17 / 「完整卸载面板」）：未跑
- **Web UI / 仪表盘**（客户端 12）、**局域网配置分发**（客户端 14）、**下载通道**（客户端 13）：未跑
- **Realm 证书续期、`sync-hy2-certs.sh`**：<SERVER_ALIAS> 上 `mihomo-hy2-cert-sync.service` 处于 `failed`（`203/EXEC`，找不到 `/root/catmi/mihomo/sync-hy2-certs.sh`）。这是**清空前就存在**的状态，且该脚本不在本项目 `src/` 里，**归属未查明**，未处理
  > **已处理（2026-10-09 补记）**：归属查明 —— 它是本项目早期自己的同步脚本，随清空重装丢失，但 `/etc/systemd/system/` 不在清空范围内，于是留下孤儿定时器。实际失败区间是 **2026-10-05 起**（最后成功 10-04 03:44:36），不是 10-08。已由 `tools/cert-sync.sh --install` 接管并清理旧单元。详见 [known-issues](handover/known-issues.md) 的「续期后没人把新证书同步进 conf/certs」
- **客户端「删除节点 / 整组」「重命名节点组」「域名分流」**：未跑
- **多台客户端同时拉同一分享链接 / max_uses / TTL 过期**：未跑
- **边界输入**：非法 IP、非法端口、证书路径填错等错误路径只抽样测了 SOCKS 一处

---

## 五、给修复者的优先级建议

| 优先级 | 问题 | 位置 |
|---|---|---|
| P0 | 取消初始化仍建目录 | `src/lib/core_mgmt.sh:325` |
| P0 | VMess 菜单项完全失效 | `src/server.sh:164` |
| P0 | VLESS 分享链接端口硬编码 443 | `src/conf/VLESS.sh:371-374, 431` |
| P1 | 「添加节点」进的是管理面板（且与管理节点同源） | `src/server.sh:227-231` |
| P1 | 端口统计区间 20000-29999 vs 实际 10000-60000 | `src/server.sh:76-79` + `update_config` |
| P1 | `smux: off` 被当成启用 | `src/conf/VLESS.sh:698, 1240`（+Trojan:753 / Reality:412 / AnyTLS:516） |
| P2 | `fetch_script` 误杀无 shebang 脚本 | `src/lib/env.sh:100` |
| P2 | AnyTLS 真证书预设为死选项（`M_PRESET_CERT` 无人读） | `src/conf/AnyTLS.sh` + `src/lib/preset.sh` |
| P2 | VLESS 预设含 REALITY 档但脚本不支持 | `src/lib/preset.sh:45-53` vs `src/conf/VLESS.sh` |
| P3 | 安装完成提示指向 client.sh | `src/core_install.sh:838-839` |
| P3 | core_menu 重复打印 `inactive` | `src/lib/core_mgmt.sh:310` |
| P3 | `--quick` 的 CDN 节点标"成功" | `src/conf/all.sh` |

---

## 六、GitHub PAT 安全提醒

任务里给的 GitHub PAT `github_pat_***已脱敏***`
**本次验证全程没有用到它，也没有写进任何文件或 git remote**，明文只存在于本次任务描述中。

如果后续 push 需要用它，请务必用 askpass 方式，并且**用完立即 shred**：

```bash
# 一次性 askpass（不落盘明文到 shell 历史 / 不进 .git/config）
cat > /tmp/.gh_askpass.sh <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) echo x-access-token ;;
  *)          cat "$GH_TOKEN_FILE" ;;
esac
EOF
chmod 700 /tmp/.gh_askpass.sh
printf '%s' "$TOKEN" > /tmp/.gh_token && chmod 600 /tmp/.gh_token

GIT_ASKPASS=/tmp/.gh_askpass.sh GH_TOKEN_FILE=/tmp/.gh_token git push

shred -u /tmp/.gh_token /tmp/.gh_askpass.sh    # 用完立刻销毁
```

另外该 PAT 已在本次会话明文出现，**建议 push 完成后直接吊销并重新签发**。