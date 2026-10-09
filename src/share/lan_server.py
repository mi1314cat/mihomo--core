#!/usr/bin/env python3
"""
lan_server.py — 局域网配置分发服务 (**M 自己的功能, 不属于公共服务**)

用途:
    把本客户端**正在用的这份完整配置**以 URL 形式提供给局域网里的其他设备,
    让它们导入后直接可用。不是中转代理 —— 别的设备拿到配置后自己连服务器。

为什么它**不**进公共分享服务:
    它要读 conf/config.yaml、要按 mihomo 的字段名剥掉 mixed-port / secret /
    external-controller 等本机专属段 —— 这是**协议知识**。
    公共服务的边界是"只存不解析", 所以这个功能必须留在 M。

路由:
    GET /sub/<token>   200 完整配置 / 403 token 不对 / 404 形状非法 / 503 没节点

    token 是**必填**的。这一点是修过的缺陷:
      原实现写在 share_server.py 里, 校验条件是 `if LAN_TOKEN and token != LAN_TOKEN`
      —— LAN_TOKEN 为空时整个校验被**跳过**, 于是任意 16 位 alnum 字符串都能拉到
      完整配置。而服务端部署恰好不设 LAN_TOKEN, 那个端点又是无条件开启的:
      本该只做节点分享的端口上, 意外开着一个无认证的配置分发口。
      现在没有 token 就**拒绝服务**, 不存在"忘了配等于全开"。

内容生成委托给 lan_config.py (唯一实现) —— 面板里的"预览"与实际分发用的是
同一份代码, 不会再出现"看到的不是别人拿到的"。

环境变量 (由 lan_dispatch.sh 传, 保持原有名字以免调用点都要改):
    LAN_ROOT     客户端根目录
    LAN_TOKEN    分发令牌 (必填)
    LAN_TMP      临时目录
    SHARE_PORT   监听端口
"""
from __future__ import annotations

import hmac
import os
import socket
import socketserver
import sys
from http.server import BaseHTTPRequestHandler

LAN_ROOT = os.environ.get("LAN_ROOT", "/root/catmi/mihomo-client")
LAN_TOKEN = os.environ.get("LAN_TOKEN", "")
LAN_TMP = os.environ.get("LAN_TMP", "/tmp/mihomo-lan-sub")
PORT = int(os.environ.get("SHARE_PORT", "19100"))

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import lan_config
except ImportError:
    lan_config = None


def log(msg: str) -> None:
    sys.stderr.write("[lan-server] %s\n" % msg)
    sys.stderr.flush()


class Handler(BaseHTTPRequestHandler):
    server_version = "mihomo-lan/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        log("%s - %s" % (self.address_string(), fmt % a))

    def _send(self, code: int, body: bytes = b"",
              ctype: str = "text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/status":
            return self._send(200, b"mihomo lan server OK\n")
        if not path.startswith("/sub/"):
            return self._send(404, b"not found\n")

        # ★ token 必填。没配就拒绝服务 —— 绝不"忘了配等于全开"。
        if not LAN_TOKEN:
            return self._send(503, b"lan dispatch not configured\n")
        token = path[len("/sub/"):]
        if not token or not token.isalnum() or len(token) < 16:
            return self._send(404, b"not found\n")
        # 常数时间比较: 避免按字符逐位比较的时序侧信道
        if not hmac.compare_digest(token, LAN_TOKEN):
            return self._send(403, b"forbidden\n")

        if lan_config is None:
            return self._send(500, b"build failed: lan_config.py missing\n")
        out = os.path.join(LAN_TMP, "lan-sub.yaml")
        try:
            text, n = lan_config.build(LAN_ROOT)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "w", encoding="utf-8") as fh:
                fh.write(text)
        except Exception as e:  # noqa: BLE001
            return self._send(500, ("build failed: %s\n" % e).encode())
        # 没有节点的分发是没意义的
        if n == 0:
            return self._send(503, b"no nodes\n")
        with open(out, "rb") as fh:
            body = fh.read()
        return self._send(200, body, "text/yaml; charset=utf-8")


class Srv6(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


class Srv4(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    if not LAN_TOKEN:
        log("未设置 LAN_TOKEN —— 拒绝启动 (没有令牌的分发等于公开泄露完整配置)")
        return 1
    for cls, addr, label in ((Srv6, "::", "双栈 IPv4+IPv6"),
                             (Srv4, "0.0.0.0", "仅 IPv4")):
        try:
            srv = cls((addr, PORT), Handler)
            log("已启动 http://%s:%d  (%s)  根目录 %s" % (addr, PORT, label, LAN_ROOT))
            srv.serve_forever()
            return 0
        except OSError as e:
            log("绑定 %s 失败: %s" % (addr, e))
    log("无法绑定任何监听地址")
    return 1


if __name__ == "__main__":
    sys.exit(main())
