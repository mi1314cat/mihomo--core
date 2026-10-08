# 部署与更新

## 服务器角色

| 角色 | 用途 | 规则 |
|---|---|---|
| **测试服务器** | 日常开发与验证 | **随意使用**, 随便改随便重装 |
| **生产服务器** | 对外服务 | **默认只读**, 改之前必须明确授权 |

**客户端机器**是第三台, 装的是 `mihomo-client`, 用于真实双端测试。

> 本文用「测试服务器 / 生产服务器 / 客户端」指代三台机器, 不写真实地址。

---

## 常规更新流程

### 1. 本地改代码

```bash
cd <项目目录>

# 1) 脱敏 (发布到 GitHub 前必须干净)
python3 tools/scrub.py

# 2) 全部门禁
bash tools/check_all.sh
# → "全部 13 项通过"
```

### 2. 提交

```bash
git add -A
git commit -m "一句话说清改了什么和为什么"
```

### 3. 推两个分支

**顺序不能反**:

```bash
# 先 refactor/v2 —— pre-push 钩子在这里跑, 自动 bump src/VERSION 并生成提交
git push origin HEAD:refs/heads/refactor/v2

# 再 main (此时 HEAD 已经包含版本号提交了)
git push origin HEAD:refs/heads/main
```

反了的话, main 会少一个版本号提交。

### 4. 部署到服务器

```bash
tar czf /tmp/x.tgz src/
scp -q /tmp/x.tgz <服务器>:/tmp/x.tgz
ssh <服务器> 'cd <项目根> && tar xzf /tmp/x.tgz'
```

---

## 在服务器上生成配置

### 服务端

```bash
cd <项目根>
bash src/server.sh
```

主菜单里:

| 编号 | 功能 |
|---|---|
| 1 | 添加节点 (共 10 项, **第 10 项 = 全协议一键生成**) |
| 3 | 管理节点 |
| 6 | 校验 + 重载 |
| 8 | CDN 回源 |
| 12 | 生成分享链接 |
| 13 | 客户端产物设置 |

**全协议一键生成 = 添加节点 → 第 10 项。**

### 客户端

```bash
cd <项目根>
bash src/client.sh
```

| 编号 | 功能 |
|---|---|
| 1 | 初始化基础配置 |
| 2 | 添加节点 (分享链接 / 订阅 / 本地文件) |
| 4 | 查看节点 |
| 5 | 更新订阅节点 |
| 6 | 删除节点 / 整组 |
| 7 | 重命名节点组 |
| 8 | 节点测速 |
| 16 | DNS 管理 |
| 17 | 安装 / 内核管理 |

> 菜单编号**不能凭印象记**, 改过菜单之后用 `tools/check_menu_ids.sh` 校验。

---

## 驱动交互式菜单 (自动化测试用)

长任务用这个方式驱动, 不要手点:

```bash
# 生成带延时的输入序列
{ for i in $(seq 1 22); do echo ""; sleep 2; done; sleep 75; } > /tmp/i.txt

timeout 400 script -qec "bash src/conf/all.sh" /dev/null < /tmp/i.txt > /tmp/run.log 2>&1
```

**要点**:
- 启动需要约 **8 秒**, 输入太早会被吞
- 整体时长可能 3-5 分钟 → 用后台任务跑, 不要占着 SSH
- 菜单项编号要照着实际菜单来, 见上一节

SSH 长连接会被掐断, 稳妥做法:

```bash
# 在远端后台跑, 然后轮询日志
ssh <服务器> 'setsid nohup bash /tmp/run.sh > /tmp/run.log 2>&1 < /dev/null &'
# 之后
ssh <服务器> 'tail -5 /tmp/run.log'
```

---

## 测速的正确姿势

### 读历史值, 不要乱调 healthcheck API

```bash
S=<面板密钥>
curl -s -H "Authorization: Bearer $S" http://127.0.0.1:9090/providers/proxies \
  | python3 -c '
import json,sys
for pid,v in json.load(sys.stdin)["providers"].items():
    for p in v.get("proxies") or []:
        h=p.get("history") or []
        if h: print(p["name"], h[-1].get("delay"))'
```

**踩过的坑**:

| 错误做法 | 实际行为 |
|---|---|
| `GET /proxies` 取 `.proxies` | 返回 `{"proxies":{...}}`, 结构对, 但**不是所有字段都能这么取** |
| `GET /proxies/<组>` 当成字典 | **直接返回组对象本身**, 节点列表在 `.all` |
| `PUT /providers/proxies/<id>/healthcheck` | **404 / "Resource not found"** |
| `GET /providers/proxies/<id>/<节点>/delay` | **404** |

**正确做法就是读 `.history[-1].delay`**, 最省事也最准。

---

## nginx 相关的两条铁律

### 1. nginx 在 Docker 里

```bash
docker exec nginx nginx -T          # 看真实生效的配置
docker exec nginx nginx -s reload   # 重载
```

宿主机上的 `nginx -T` 看到的是**另一个文件**, 改它没有任何作用 —— 本项目踩过。

### 2. 站点配置里可能有第三方内容

生产服务器的 nginx 配置里**同时托管着别的面板的 CDN 段落**。
改配置时**只碰自己那段**, 别把别人的整块覆盖掉。

---

## SAFE_PATHS 与证书

mihomo 有 SAFE_PATHS 限制: **拒绝加载工作目录 `-d` 之外的证书文件**。

但 **`mihomo -t` 对越界证书是放行的** —— 配置测试通过, 实际启动静默失败。

所以:

- 证书必须放在 `conf/certs/` 下面
- 写完选证书菜单之后**必须重新做路径检查**
- 报告绑定失败时读 `journalctl -u mihomo`, 不要另起一个 mihomo 去试
  (端口被占, 会得到误导性的 `address already in use`)

---

## 上线前检查清单

```bash
python3 tools/scrub.py           # 脱敏
bash tools/check_all.sh          # 13 项门禁
bash -n src/server.sh            # 语法
```

三样都过再推。