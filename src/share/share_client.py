#!/usr/bin/env python3
"""
share_client.py — M 接入公共分享服务的适配层

架构位置:

    M 面板 (share.sh, 九项菜单不变)
        ↓
    本文件 (只做 HTTP 调用 + 参数校验)
        ↓
    proxy-share-service  (Token / TTL / max_uses / 存储)

M 只管理 provider=mihomo 的记录 —— 公共服务的列表与删除**强制**要求带
provider 参数, 所以 M 在结构上不可能看到或误删 SB/X 的分享。

设计要点:
  * 公共服务是**服务器上的公共基础服务**, 不是 M 的子服务。
    本文件负责"确保它在位"(不存在则从独立项目安装), 但**不负责卸载它**。
  * 端口从公共服务的 env 文件读 —— 它可能因为端口回避而**不是** 9443,
    绝不能在这里写死。
  * 所有输出都是 JSON, 交给 share.sh 用 python3 解析 (沿用项目既有风格)。

子命令:
    health                     健康检查, 打印 JSON; 服务不在则退出码 1
    port                       打印公共服务端口
    ensure                     确保服务在位 (不存在则安装); 打印端口
    list   [--type node|config]
    create --type T --content-file F [--ttl N] [--max-uses N] [--meta JSON]
    update --token T [--content-file F] [--enabled true|false] [--meta JSON]
    delete --token T
    get    --token T
    token-file                 打印管理密钥文件路径 (给 bash 用, 不打印密钥本身)
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

PROVIDER = os.environ.get("SHARE_PROVIDER", "mihomo")
ETC = os.environ.get("SHARE_ETC", "/etc/proxy-share-service")
ENV_FILE = os.path.join(ETC, "env")
TOKEN_FILE = os.environ.get("SHARE_ADMIN_TOKEN_FILE", os.path.join(ETC, "admin.token"))
PORT_FILE = os.environ.get("SHARE_PORT_FILE", "/run/proxy-share-service/port")
FALLBACK_PORT = os.environ.get("SHARE_PORT", "9443")
# 公共服务不存在时从这里装 —— 它是**独立项目**, M 只是调用方
INSTALL_URL = os.environ.get(
    "SHARE_SERVICE_INSTALL_URL",
    "https://raw.githubusercontent.com/mi1314cat/Share-Service/main/install.sh")


def die(msg: str, code: int = 1):
    sys.stderr.write("share_client: %s\n" % msg)
    sys.exit(code)


def read_env_port() -> str:
    try:
        with open(ENV_FILE, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("SHARE_PORT="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def actual_port() -> str:
    """实际端口优先 —— 端口回避后 env 里的值可能与实际绑定不同。"""
    try:
        with open(PORT_FILE, encoding="utf-8") as fh:
            p = fh.read().strip()
            if p:
                return p
    except OSError:
        pass
    return read_env_port() or FALLBACK_PORT


def base_url() -> str:
    return "http://127.0.0.1:%s" % actual_port()


def admin_token() -> str:
    try:
        with open(TOKEN_FILE, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def request(method: str, path: str, body=None, auth: bool = True, timeout: int = 10):
    """返回 (status, parsed_or_bytes)。"""
    url = base_url() + path
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if auth:
        tok = admin_token()
        if not tok:
            die("管理密钥不存在: %s (公共服务没装好?)" % TOKEN_FILE)
        headers["Authorization"] = "Bearer " + tok
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raw = e.read()
        status = e.code
    except (urllib.error.URLError, OSError) as e:
        die("连不上公共服务 %s: %s" % (base_url(), e))
    ctype = "json"
    try:
        return status, json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return status, raw


def api_ok(method: str, path: str, body=None):
    status, data = request(method, path, body)
    if status >= 400:
        msg = data.get("error") if isinstance(data, dict) else str(data)
        die("公共服务返回 %s: %s" % (status, msg))
    return data


# ---------------------------------------------------------------- 子命令
def cmd_health(_):
    status, data = request("GET", "/api/v1/health", auth=False, timeout=4)
    if status != 200 or not isinstance(data, dict):
        return 1
    print(json.dumps(data, ensure_ascii=False))
    return 0


def cmd_port(_):
    print(actual_port())
    return 0


def _health_ok() -> bool:
    """静默健康探测 —— 不往 stdout 打任何东西 (ensure 的调用方只要端口)。"""
    try:
        status, data = request("GET", "/api/v1/health", auth=False, timeout=4)
    except SystemExit:
        return False
    return status == 200 and isinstance(data, dict) and data.get("status") == "ok"


def cmd_ensure(_):
    """确保公共服务在位。已存在则**什么都不做**(不重装/不改端口/不碰数据)。"""
    if _health_ok():
        print(actual_port())
        return 0
    # 没装 → 从独立项目安装。它是公共基础服务, 装上之后 SB/X 会直接复用。
    sys.stderr.write("share_client: 公共分享服务不在, 正在从独立项目安装...\n")
    installer = "/tmp/proxy-share-service-install.sh"
    try:
        urllib.request.urlretrieve(INSTALL_URL, installer)
    except Exception as e:  # noqa: BLE001
        die("下载安装器失败 (%s): %s" % (INSTALL_URL, e))
    r = subprocess.run(["bash", installer], check=False)
    if r.returncode != 0:
        die("公共分享服务安装失败")
    if _health_ok():
        print(actual_port())
        return 0
    die("服务装上了但健康检查没过")
    return 1


def cmd_token_file(_):
    print(TOKEN_FILE)
    return 0


def cmd_list(a):
    q = "?provider=%s" % PROVIDER
    if a.type:
        q += "&type=%s" % a.type
    data = api_ok("GET", "/api/v1/shares" + q)
    print(json.dumps(data.get("shares", []), ensure_ascii=False))
    return 0


def cmd_get(a):
    data = api_ok("GET", "/api/v1/shares/%s?provider=%s" % (a.token, PROVIDER))
    print(json.dumps(data, ensure_ascii=False))
    return 0


def _content_from(a) -> str:
    if a.content_file:
        try:
            with open(a.content_file, encoding="utf-8") as fh:
                return fh.read()
        except OSError as e:
            die("读不到内容文件 %s: %s" % (a.content_file, e))
    if a.content is not None:
        return a.content
    return ""


def cmd_create(a):
    if a.type not in ("node", "config"):
        die("--type 只能是 node 或 config")
    content = _content_from(a)
    if not content:
        die("内容为空 (--content-file 或 --content)")
    body = {
        "provider": PROVIDER,
        "type": a.type,
        "content": content,
        "content_type": a.content_type,
        "ttl": a.ttl,
        "max_uses": a.max_uses,
    }
    if a.meta:
        try:
            body["meta"] = json.loads(a.meta)
        except ValueError:
            die("--meta 不是合法 JSON")
    if a.token:
        body["token"] = a.token          # 迁移用: 沿用旧 token, 保住已发出的链接
    if a.expires_at is not None:
        body["expires_at"] = a.expires_at  # 迁移用: 保留原到期时间 (含"已过期")
    data = api_ok("POST", "/api/v1/shares", body)
    print(json.dumps(data, ensure_ascii=False))
    return 0


def cmd_update(a):
    body = {"provider": PROVIDER}
    if a.content_file or a.content is not None:
        body["content"] = _content_from(a)
    if a.enabled is not None:
        body["enabled"] = (a.enabled == "true")
    if a.meta:
        try:
            body["meta"] = json.loads(a.meta)
        except ValueError:
            die("--meta 不是合法 JSON")
    if a.ttl is not None:
        body["ttl"] = a.ttl
    if a.used_count is not None:
        body["used_count"] = a.used_count
    data = api_ok("PUT", "/api/v1/shares/%s" % a.token, body)
    print(json.dumps(data, ensure_ascii=False))
    return 0


def cmd_delete(a):
    data = api_ok("DELETE", "/api/v1/shares/%s?provider=%s" % (a.token, PROVIDER))
    print(json.dumps(data, ensure_ascii=False))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("health").set_defaults(fn=cmd_health)
    sub.add_parser("port").set_defaults(fn=cmd_port)
    sub.add_parser("ensure").set_defaults(fn=cmd_ensure)
    sub.add_parser("token-file").set_defaults(fn=cmd_token_file)

    p = sub.add_parser("list"); p.add_argument("--type", default=""); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("get"); p.add_argument("--token", required=True); p.set_defaults(fn=cmd_get)
    p = sub.add_parser("delete"); p.add_argument("--token", required=True); p.set_defaults(fn=cmd_delete)

    p = sub.add_parser("create")
    p.add_argument("--type", required=True)
    p.add_argument("--content-file", default="")
    p.add_argument("--content", default=None)
    p.add_argument("--content-type", default="text/yaml; charset=utf-8")
    p.add_argument("--ttl", type=int, default=0)
    p.add_argument("--max-uses", type=int, default=0)
    p.add_argument("--meta", default="")
    p.add_argument("--token", default="")
    p.add_argument("--expires-at", type=int, default=None, dest="expires_at")
    p.set_defaults(fn=cmd_create)

    p = sub.add_parser("update")
    p.add_argument("--token", required=True)
    p.add_argument("--content-file", default="")
    p.add_argument("--content", default=None)
    p.add_argument("--enabled", default=None)
    p.add_argument("--meta", default="")
    p.add_argument("--ttl", type=int, default=None)
    p.add_argument("--used-count", type=int, default=None, dest="used_count")
    p.set_defaults(fn=cmd_update)

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
