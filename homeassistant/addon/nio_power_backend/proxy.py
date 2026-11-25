#!/usr/bin/env python3
"""NIO Power 前端代理：静态页面 + /api 反向代理（服务端注入密钥，浏览器不接触密钥）。"""
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WWW = "/www"
PORT = int(os.environ.get("WEB_PORT", "8099"))
BACKEND = "http://127.0.0.1:8080"
GENERATED_API_KEY = "/data/generated/api_key"


def load_options() -> dict:
    try:
        with open("/data/options.json", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def load_keys() -> dict:
    opts = load_options()
    api_key = str(opts.get("api_key") or "")
    if not api_key:
        # run.sh 在选项留空时生成并保存的 Key
        try:
            with open(GENERATED_API_KEY, encoding="utf-8") as f:
                api_key = f.read().strip()
        except OSError:
            api_key = ""
    return {
        "X-API-Key": api_key,
        "X-Vehicle-Control-Key": str(opts.get("control_api_key") or ""),
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/"):
            self.proxy("GET")
        elif self.path.split("?")[0] == "/ui-config":
            self.serve_ui_config()
        else:
            self.serve_static()

    def do_POST(self):
        if self.path.startswith("/api/"):
            self.proxy("POST")
        else:
            self.send_error(404)

    def serve_ui_config(self):
        """前端只需要知道车控是否已配置；绝不返回任何密钥。"""
        keys = load_keys()
        body = json.dumps(
            {
                "control_configured": bool(keys.get("X-Vehicle-Control-Key")),
                # 换电目标档位 8 对应 102 kWh；其他档位跨电池系列含义不唯一，不推断。
                "default_battery_type": "102 kWh"
                if str(load_options().get("target_battery_cap_level")) == "8"
                else None,
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_static(self):
        path = self.path.split("?")[0]
        if path in ("/", ""):
            path = "/index.html"
        full = os.path.normpath(WWW + path)
        if not full.startswith(WWW) or not os.path.isfile(full):
            self.send_error(404)
            return
        with open(full, "rb") as f:
            body = f.read()
        if full.endswith(".html"):
            ctype = "text/html"
        elif full.endswith(".png"):
            ctype = "image/png"
        elif full.endswith(".svg"):
            ctype = "image/svg+xml"
        elif full.endswith(".css"):
            ctype = "text/css"
        elif full.endswith(".js"):
            ctype = "text/javascript"
        else:
            ctype = "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        # 页面与脚本每次重新校验，加载项更新后浏览器立即拿到新版本；图片可缓存。
        self.send_header(
            "Cache-Control",
            "public, max-age=86400" if full.endswith(".png") else "no-cache",
        )
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def proxy(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "content-length", "connection")
        }
        headers.update(load_keys())
        req = urllib.request.Request(
            BACKEND + self.path, data=body, headers=headers, method=method
        )
        try:
            # 车控与换电下单在后端最长会轮询约 90 秒，写请求需要更长的超时。
            timeout = 100 if method == "POST" else 60
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = resp.read()
                self.send_response(resp.status)
                self.send_header(
                    "Content-Type",
                    resp.headers.get("Content-Type", "application/json"),
                )
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as err:
            data = err.read()
            self.send_response(err.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as err:  # noqa: BLE001
            self.send_error(502, str(err))

    def log_message(self, fmt, *args):  # noqa: A002
        pass


if __name__ == "__main__":
    print(f"[proxy] serving {WWW} on 0.0.0.0:{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
