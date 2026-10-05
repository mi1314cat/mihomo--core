#!/usr/bin/env python3
"""
share_server.py — 分享服务 (token / TTL / max_uses)

与 参考实现 的差异(刻意保留):
    * sing-box 发 JSON outbounds, 客户端需要 to_sb.py 转换
    * **本项目直接发 Mihomo 的 `proxies:` YAML** —— Mihomo 的 proxy-provider
      能原生死, 不需要任何转换器 (已在 v1.19.31 实测: 11 个生产节点
      载入 provider 后真实出网成功)

语义约定:
    expires_at == 0  → 永久
    max_uses  == 0   → 不限次数
    tag == "all"     → 全部节点聚合

关键不变量(照搬自 参考实现 的正确做法):
    **先扣次数, 再发 body**。客户端拿到 200 就一定拿到了完整 body,
    反之任何失败路径(禁用/过期/用尽/服务不在/文件缺失)都不会消耗额度。
    整个 校验→扣减→保存 在 flock 内完成, 并发拉取不会双花最后一次额度。

路由:
    GET  /share/<token>   200 订阅 YAML / 404 不存在 / 410 失效 / 503 暂不可用
    HEAD /share/<token>   200 (不消耗额度, 供客户端预检)
    GET  /status          健康检查
"""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler

import fcntl
import json
import os
import socket
import socketserver
import subprocess
import sys
import threading
import time
import contextlib

SHARE_DIR = os.environ.get("SHARE_DIR", "/root/catmi/mihomo/share")
OUT_DIR = os.environ.get("OUT_DIR", "/root/catmi/mihomo/out")
# 客户端侧节点来自 proxy-providers (服务端侧是空目录, 见 build_sub.py --providers-dir)
PROVIDERS_DIR = os.environ.get("PROVIDERS_DIR", "")
PORT = int(os.environ.get("SHARE_PORT", "9443"))
SERVICE = os.environ.get("MIHOMO_SERVICE", "mihomo")
SHARES = os.path.join(SHARE_DIR, "shares")
LOCK = os.path.join(SHARE_DIR, ".share.lock")
BUILD_SUB = os.environ.get("BUILD_SUB", "")   # build_sub.py 绝对路径

# 进程内互斥。**必需**:
#   ThreadingTCPServer 是多线程模型, 而 flock 作用于"打开文件描述 (OFD)"。
#   同一进程内多个线程共享同一个 fd 时 flock 根本不会阻塞 —— 等于没加锁。
#   实测: 12 个并发请求抢 1 次额度会全部返回 200 (超发 12 倍)。
# 正确做法 = threading.Lock (进程内) + 每次单独 open 后的 flock (跨进程)。
_THREAD_LOCK = threading.Lock()


@contextlib.contextmanager
def share_lock():
    """进程内 (threading) + 跨进程 (flock) 两层互斥。"""
    os.makedirs(SHARE_DIR, exist_ok=True)
    with _THREAD_LOCK:
        # 每次单独 open → 独立 OFD → flock 才真正互斥
        fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


# =============================================================
# 存储
# =============================================================
def store_path(token: str) -> str:
    return os.path.join(SHARES, f"{token}.json")


def load_meta(token: str):
    try:
        with open(store_path(token), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def save_meta(meta: dict) -> None:
    os.makedirs(SHARES, exist_ok=True)
    tmp = store_path(meta["share_token"]) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=1)
    os.replace(tmp, store_path(meta["share_token"]))


# =============================================================
# 负载构建 —— 每次请求都重新从 out/ 生成, 保证是最新节点
# =============================================================
def build_payload(tag: str) -> bytes | None:
    if not BUILD_SUB or not os.path.isfile(BUILD_SUB):
        return None
    try:
        cmd = [sys.executable, BUILD_SUB, "--out-dir", OUT_DIR, "--tag", tag]
        if PROVIDERS_DIR:
            cmd += ["--providers-dir", PROVIDERS_DIR]
        out = subprocess.run(cmd, capture_output=True, timeout=20, check=False)
    except subprocess.TimeoutExpired:
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    body = out.stdout
    if b"proxies:" not in body:
        return None
    return body


def core_healthy() -> bool:
    """主服务不在时不发订阅(也不扣额度)。"""
    try:
        r = subprocess.run(["systemctl", "is-active", "--quiet", SERVICE],
                           capture_output=True, timeout=6)
        return r.returncode == 0
    except Exception:  # noqa: BLE001
        return True   # 非 systemd 环境不拦截


# =============================================================
# HTTP
# =============================================================
class Handler(BaseHTTPRequestHandler):
    server_version = "mihomo-share/2"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):  # 安静一点
        sys.stderr.write("[share] %s - %s\n" % (self.address_string(), fmt % a))

    def _send(self, code: int, body: bytes = b"", ctype: str = "text/plain; charset=utf-8"):
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
            return self._send(200, b"mihomo share server OK\n")

        if not path.startswith("/share/"):
            return self._send(404, b"not found\n")

        token = path[len("/share/"):]
        # 形状校验: 只允许字母数字, 杜绝路径穿越
        if not token or not token.isalnum() or len(token) < 16:
            return self._send(404, b"not found\n")

        with share_lock():
            meta = load_meta(token)
            if meta is None:
                return self._send(404, b"not found\n")

            if not meta.get("enabled", True):
                return self._send(410, b"disabled\n")

            now = int(time.time())
            exp = int(meta.get("expires_at", 0))
            if exp and now > exp:
                return self._send(410, b"expired\n")

            used = int(meta.get("used_count", 0))
            maxu = int(meta.get("max_uses", 0))
            if maxu and used >= maxu:
                return self._send(410, b"used up\n")

            if not core_healthy():
                return self._send(503, b"mihomo service inactive\n")

            # HEAD 只做存在性预检, 不构造负载也不扣额度
            if self.command == "HEAD":
                return self._send(200, b"", "text/yaml")

            body = build_payload(meta.get("tag", "all"))
            if body is None:
                return self._send(503, b"config unavailable\n")

            # 提交消费: 在发出响应体之前扣减 —— 拿到 200 必然拿到完整 body
            meta["used_count"] = used + 1
            meta["last_used_at"] = now
            save_meta(meta)

            return self._send(200, body, "text/yaml; charset=utf-8")


class Srv6(socketserver.ThreadingTCPServer):
    """双栈监听: IPv6 通配 + v4 映射, 一个端口同时收 v4/v6。"""
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
    os.makedirs(SHARES, exist_ok=True)
    os.makedirs(SHARE_DIR, exist_ok=True)
    open(LOCK, "a").close()   # 确保 lock 文件存在

    for cls, addr, label in ((Srv6, "::", "双栈 IPv4+IPv6"),
                             (Srv4, "0.0.0.0", "仅 IPv4")):
        try:
            srv = cls((addr, PORT), Handler)
            print(f"分享服务已启动: http://{addr}:{PORT}  ({label})", flush=True)
            print(f"  SHARE_DIR={SHARE_DIR}", flush=True)
            print(f"  OUT_DIR  ={OUT_DIR}", flush=True)
            srv.serve_forever()
            return 0
        except OSError as e:
            print(f"绑定 {addr} 失败: {e}", flush=True)
    print("无法绑定任何监听地址", file=sys.stderr, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())