# mihomo--core

基于 [Mihomo Meta](https://github.com/MetaCubeX/mihomo) 的节点部署与分发面板。

服务端负责建节点、合并配置、发分享；客户端负责拉分享、导入节点、选组出网。
分享内容是 Mihomo 原生的订阅格式，客户端直接导入，不需要任何格式转换。

## 功能

**服务端**

- 六种协议建节点：VLESS + Reality、Trojan、Hysteria2、TUIC v5、AnyTLS、纯 VLESS
- 节点按 `<协议>-<编号>.yaml` 分文件存放，改动后自动合并进主配置
- 每次改动走三道关：合并 → 严格字段校验 → `mihomo -t`，任一不过就整体回滚，不会带着坏配置重启
- 生成分享链接：可设有效期与拉取次数，支持随时禁用或重置 Token
- 拉取外部订阅并并入自己的分享体系
- 查看当前节点、分享内容、运行日志、系统信息

**客户端**

- 拉分享链接导入节点，自动转成 `proxy-provider`，新增节点不用改配置
- 区分一次性链接与永久订阅：前者只拉一次存本地，后者定时自动更新
- 节点分组（手动选择 / 自动测速）、延迟测试、一键测速全部节点
- 配置自检：严格字段校验 + 内核校验
- 内置 Web 面板，密钥保护

## 安装

```bash
bash <(curl -fsSL https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/install.sh)
```

按提示选择服务端、客户端或两者。也可以直接指定：

```bash
bash <(curl -fsSL .../install.sh) server
bash <(curl -fsSL .../install.sh) client
```

装好后：

```bash
bash /root/catmi/mihomo/src/server.sh          # 服务端
bash /root/catmi/mihomo-client/src/client.sh   # 客户端
```

## 目录

```
服务端 /root/catmi/mihomo/
├── mihomo                  内核
├── install_info.env        环境变量 (UUID / 端口 / 密钥)
├── conf/
│   ├── config.yaml         主配置 (自动合并生成)
│   ├── config.d/           节点配置, 每协议一个文件
│   └── certs/              证书
├── out/                    节点分享内容
└── share/shares/           分享 Token 状态

客户端 /root/catmi/mihomo-client/
├── mihomo
├── conf/
│   ├── config.yaml         自动生成
│   └── providers/          每个订阅一个 provider
└── nodes/                  订阅来源记录
```

## 说明

- 内核版本、架构（x86_64 自动区分 v3 / compatible）与 arm64 适配由安装脚本处理
- 分享链接若包含 mTLS 客户端证书，私钥会随订阅下发，建议只用于一次性链接
- 外部依赖只剩证书签发走 acme.sh，其余脚本已全部本地化

## 许可

本项目脚本部分沿用原仓库许可；Mihomo Meta 内核遵循其上游许可。
