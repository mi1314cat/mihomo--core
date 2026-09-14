# mihomo-manager — Mihomo Linux Bootstrap / Installer / Manager

轻量 Bash 工具：**安装内核 → systemd 服务 → 配置补全 → MetaCubeXD UI → 系统代理**。
不是 Web 面板，不实现 Dashboard，不引入 Docker / 数据库 / 前端框架。

## 调研结论（与官方对齐的部分）

| 决策 | 官方依据 |
|---|---|
| 沿用 `/root/catmi` 目录与 `mihomo` 手动路径 | 你的环境已在用，且 `-d` 工作目录参数由脚本管理，无迁移收益 |
| 上传包识别：按 MIME + ELF 架构 + `mihomo -v`，不依赖文件名 | 官方命名规则为 `mihomo-linux-{amd64,amd64-compatible,arm64,armv7,...}-vX.Y.Z.gz`（另有 .deb/.rpm/.pkg.tar.zst、`-go12x` 变体），未来可能变化 |
| amd64 自动下载选 `mihomo-linux-amd64-compatible-$tag.gz` | compatible 可在所有 x86_64（含旧/非 V2 CPU）上运行；失败回落标准 amd64 |
| UI 部署 = 下载 `metacubexd/archive/refs/heads/gh-pages.zip` 解压到 `external-ui` 目录 | 官方 wiki (General configuration) 即此方式，metacubexd 的 `gh-pages` 分支 **真实存在** |
| `external-controller` 缺失才补 `127.0.0.1:9090`；已存在为 `0.0.0.0` 时**只提示不修改** | 官方示例默认 `127.0.0.1:9090`；公网监听要求强 `secret` + 防火墙 |
| `unified-delay: true`、`external-ui` 缺失才追加 | 你指定的必要字段；存在则尊重现值 |
| 系统代理走 `/etc/profile.d/mihomo-proxy.sh` + 独立 conf | 大小写双写（http_proxy/HTTP_PROXY…），不碰 `.bashrc`，一键可关 |

## 目录结构

```
mihomo-manager/
├── mihomo-manager.sh                  # 主脚本（全部功能）
├── conf/mihomo-manager.conf.template  # 配置模板（脚本生成 /root/catmi/mihomo-manager.conf）
├── templates/mihomo.service           # service 参考模板（脚本内嵌渲染逻辑一致）
└── README.md
```

服务器上运行后的布局：

```
/root/catmi/
├── mihomo              # 内核二进制
├── config.yaml         # 你的 mihomo 配置（脚本只做最小补充）
├── ui/                 # MetaCubeXD（gh-pages 内容）
├── version.txt         # 仅健康检查通过后才更新
├── mihomo-upload/      # ← 手动上传官方 mihomo-linux-XXX-vX.Y.Z.gz 的目录
├── mihomo-manager.conf # 下载代理、路径等配置
├── mihomo-proxy.conf   # 系统代理变量（由系统代理功能生成/删除）
└── backup/             # 内核/service/config/UI 备份
```

## 安装方法

```bash
# 1) 从本机上传到服务器（或其他能访问服务器的途径任意拷贝均可）：
scp -r mihomo-manager root@服务器IP:/root/

# 2) 在服务器上以 root 运行：
bash /root/mihomo-manager/mihomo-manager.sh --dry-run install   # 只看不改，先确认
bash /root/mihomo-manager/mihomo-manager.sh install             # 正式执行
```

### 快捷命令 `catmi`

脚本首次成功运行（非 dry-run 需 root）时会自动把自身链接到
`/usr/local/bin/catmi`，之后任何路径下直接：

```bash
catmi                # 打开交互菜单
catmi --dry-run install
catmi update
catmi proxy on
```

若 `/usr/local/bin/catmi` 已被其他脚本占用，脚本不会覆盖，会打印提示。

依赖：`curl`、`unzip`、`file`（`file` 缺失时跳过 ELF 校验，只靠运行测试兜底），
`gzip`/`tar`（系统自带）。无其他依赖。

## 使用方法（上传内核 + 一键安装）

1. 在任意能访问 GitHub 的机器下载官方 Release 压缩包，不需要改名：

   ```
   https://github.com/MetaCubeX/mihomo/releases/latest
   例：mihomo-linux-amd64-compatible-v1.19.30.gz
   ```

2. 上传到服务器：`scp mihomo-linux-*.gz root@服务器:/root/catmi/mihomo-upload/`

3. 服务器上执行：

   ```bash
   bash mihomo-manager.sh install    # 自动扫描/识别架构/验证/备份/替换/启动/健康检查
   ```

   或进入菜单：`bash mihomo-manager.sh`（无参数即交互菜单）。

## 升级方法

- **在线**（服务器有代理或可直连）：在 `mihomo-manager.conf` 设 `MIHOMO_DOWNLOAD_PROXY=http://127.0.0.1:7890`，然后：

  ```bash
  bash mihomo-manager.sh update
  ```

  下载 → MIME 校验 → ELF 架构校验 → `mihomo -v` 运行校验 → 停服 → 替换 → 启动 → 健康检查，任何一步失败自动回滚到旧内核。

- **离线指定版本**：上传新的 .gz 到 `mihomo-upload/`，重复 `import`/`install` 流程。
  多个候选包时脚本会列出让你选择，绝不随机选。

## 回滚方法

```bash
bash mihomo-manager.sh backup    # 列出 /root/catmi/backup 并交互回滚
```

备份文件名形如 `mihomo+20260914-192239`（内核）、`mihomo.service+...`、`config.yaml+...`、`ui+...`。
每类保留最近 `KEEP_BACKUPS=5` 份。更新内核失败时脚本会自动回滚；手动回滚用此命令。

## 系统代理（Linux 全局环境变量）

```bash
bash mihomo-manager.sh proxy on            # 交互输入 HTTP/HTTPS/SOCKS
bash mihomo-manager.sh proxy on http://192.168.1.178:10809 "" socks5://192.168.1.178:1080
bash mihomo-manager.sh proxy off           # 一键关闭（删除两份由本工具创建的文件）
bash mihomo-manager.sh proxy status        # 查看来源与当前值
```

实现：生成 `/root/catmi/mihomo-proxy.conf`（小写+大写双写变量），入口写 `/etc/profile.d/mihomo-proxy.sh`。
- 新登录 shell / 重启自动生效；不污染 `.bashrc`；
- 关闭时只删除本工具自己创建的两份文件，不动你的其他代理配置；
- 若 `/etc/profile.d/mihomo-proxy.sh` 已存在但非本工具创建，脚本会拒绝覆盖并提示手工合并。

## systemd service

- 存在 `mihomo.service` 时：先 `systemctl cat` 展示现状 → 备份 → 确认后才用模板接管；
- 模板：`ExecStart=/root/catmi/mihomo -f /root/catmi/config.yaml -d /root/catmi`，
  `Restart=on-failure`、`RestartSec=5s`、`LimitNOFILE=1048576`。如需 TUN，请自行在
  `templates/mihomo.service` / 已安装 service 中放开 `CAP_NET_ADMIN` 注释块。

## 对你现有环境的影响（默认 install 流程）

| 对象 | 行为 |
|---|---|
| `/root/catmi/config.yaml` | **不重新生成**。缺 `external-ui`/`external-controller`/`unified-delay` 时在文件末尾追加缺失项（值与你现有键冲突时只提示不覆盖）；全程先备份 |
| `external-controller: 0.0.0.0:9090` | 不修改 0.0.0.0。若无 `secret` 会给出风险提示（建议加 secret + 防火墙限源）；需要局域网访问可保留，由你决定 |
| `version.txt` | 移除写坏的时机，改为「服务健康检查通过后」才写入 |
| `mihomo` 二进制 | 保留为同一路径，变得可用（先备份、验证后替换、失败回滚） |
| `mihomo.service` | 已存在则 `systemctl cat` 展示并备份后询问接管；不存在则创建 |
| UI | 直接使用官方 MetaCubeXD gh-pages，不做自研 UI |
| 系统代理 | 独立、可开关，由本工具统一管理 |

## 安全门：dry-run

所有写操作命令（替换内核、写 service、改 config、删文件）都经一个 `run_cmd` 包装，
`--dry-run` 时全局只打印 `[dry-run] ...`，不写任何文件：

```bash
bash mihomo-manager.sh --dry-run install
```

## 日常速查

```bash
bash mihomo-manager.sh status      # 状态总览
bash mihomo-manager.sh logs        # journalctl -u mihomo -f
bash mihomo-manager.sh check       # 内核/配置语法(mihomo -t)/systemd/UI 体检
bash mihomo-manager.sh restart
bash mihomo-manager.sh service     # 接管/重建 service
bash mihomo-manager.sh ui          # 更新 MetaCubeXD
```
