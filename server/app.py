#
# BubbleDeck 授权 API（V1）
# 四接口：activate / verify / packs / download，SQLite 存储，HMAC 请求校验
# 契约见 docs/授权系统方案.md
#
# 运行：uvicorn app:app --host 127.0.0.1 --port 8000
# 环境变量：BD_SALT（签名盐，必配）  BD_DB（SQLite 路径，默认同目录 bd.db）
#

import os
import time
import hmac
import hashlib
import secrets
import sqlite3

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

DB_PATH = os.environ.get("BD_DB", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bd.db"))
SALT = os.environ.get("BD_SALT", "bd-dev-salt")          # 生产部署必须覆盖
TOKEN_DAYS = 7                                            # 本地凭证兜底期；正常每次启动都 verify 续期
TS_WINDOW_MS = 300_000                                    # 签名时间窗 ±300s

app = FastAPI()

# ────── DB ──────

def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS licenses(
            license     TEXT PRIMARY KEY,
            state       TEXT NOT NULL DEFAULT 'unused',   -- unused/active/revoked
            bind_device TEXT,
            bind_wxid   TEXT,
            activated_at INTEGER,
            token       TEXT,
            token_exp   INTEGER
        );
        CREATE TABLE IF NOT EXISTS packs(
            name    TEXT PRIMARY KEY,
            version TEXT NOT NULL,
            size    INTEGER NOT NULL DEFAULT 0,
            md5     TEXT NOT NULL,
            url     TEXT NOT NULL,
            packkey TEXT NOT NULL,
            state   TEXT NOT NULL DEFAULT 'on'            -- on/off
        );
        """)

# ────── 签名校验 ──────

def check_sign(ts: str, sign: str, body: bytes):
    """失败返回错误码字符串，成功返回 None"""
    if not ts or not sign:
        return 4001
    try:
        ts_ms = int(ts)
    except ValueError:
        return 4001
    if abs(int(time.time() * 1000) - ts_ms) > TS_WINDOW_MS:
        return 4002
    expect = hmac.new(SALT.encode(), f"{ts}|".encode() + body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expect, sign):
        return 4003
    return None

# ────── 工具 ──────

def resp(code=0, msg="ok", data=None):
    return JSONResponse({"code": code, "msg": msg, "data": data or {}})

def token_ok(c, token: str, device: str):
    """token + 设备匹配且未过期 → 返回 license 行，否则 None"""
    row = c.execute("SELECT * FROM licenses WHERE token=? AND bind_device=?",
                    (token or "", device or "")).fetchone()
    if not row or row["state"] != "active":
        return None
    if not row["token_exp"] or row["token_exp"] < time.time():
        return None
    return row

def extend_token(c, license_key: str) -> int:
    exp = int(time.time()) + TOKEN_DAYS * 86400
    c.execute("UPDATE licenses SET token_exp=? WHERE license=?", (exp, license_key))
    return exp

def issue_token(c, license_key: str):
    token = secrets.token_hex(24)                          # 48 字符
    exp = int(time.time()) + TOKEN_DAYS * 86400
    c.execute("UPDATE licenses SET token=?, token_exp=? WHERE license=?",
              (token, exp, license_key))
    return token, exp

# ────── 接口 ──────

@app.post("/bd/activate")
async def activate(request: Request):
    body = await request.body()
    if err := check_sign(request.headers.get("X-BD-Ts"), request.headers.get("X-BD-Sign"), body):
        return resp(err, "签名校验失败")
    try:
        j = __import__("json").loads(body)
        license_key, device = j["license"], j["device_id"]
        wxid, sysv, model = j["wxid"], j["sys"], j["model"]
    except Exception:
        return resp(1004, "参数缺失")
    with db() as c:
        row = c.execute("SELECT * FROM licenses WHERE license=?", (license_key,)).fetchone()
        if not row:
            return resp(1001, "卡密不存在")
        if row["state"] == "revoked":
            return resp(1002, "卡密已停用")
        if row["bind_device"] and row["bind_device"] != device:
            return resp(1003, "设备数超限")
        if not row["bind_device"]:                          # 首次激活 = 绑定
            c.execute("""UPDATE licenses SET state='active', bind_device=?, bind_wxid=?,
                         activated_at=? WHERE license=?""",
                      (device, wxid, int(time.time()), license_key))
        c.execute("UPDATE licenses SET bind_wxid=? WHERE license=?", (wxid, license_key))
        token, exp = issue_token(c, license_key)
    return resp(data={"token": token, "expires_at": exp})

@app.post("/bd/verify")
async def verify(request: Request):
    body = await request.body()
    if err := check_sign(request.headers.get("X-BD-Ts"), request.headers.get("X-BD-Sign"), body):
        return resp(err, "签名校验失败")
    try:
        j = __import__("json").loads(body)
        token, device = j["token"], j["device_id"]
    except Exception:
        return resp(1004, "参数缺失")
    with db() as c:
        row = token_ok(c, token, device)
        if not row:
            return resp(2001, "token 无效或已过期")
        exp = extend_token(c, row["license"])
    return resp(data={"active": True, "expires_at": exp})

@app.post("/bd/packs")
async def packs(request: Request):
    body = await request.body()
    if err := check_sign(request.headers.get("X-BD-Ts"), request.headers.get("X-BD-Sign"), body):
        return resp(err, "签名校验失败")
    try:
        j = __import__("json").loads(body)
        token, device = j["token"], j["device_id"]
    except Exception:
        return resp(1004, "参数缺失")
    with db() as c:
        if not token_ok(c, token, device):
            return resp(2001, "token 无效或已过期")
        rows = c.execute("""SELECT name, version, size, md5, url FROM packs
                            WHERE state='on' ORDER BY name""").fetchall()
    return resp(data={"packs": [dict(r) for r in rows]})

@app.post("/bd/download")
async def download(request: Request):
    body = await request.body()
    if err := check_sign(request.headers.get("X-BD-Ts"), request.headers.get("X-BD-Sign"), body):
        return resp(err, "签名校验失败")
    try:
        j = __import__("json").loads(body)
        token, device, name = j["token"], j["device_id"], j["name"]
    except Exception:
        return resp(1004, "参数缺失")
    with db() as c:
        if not token_ok(c, token, device):
            return resp(2001, "token 无效或已过期")
        row = c.execute("SELECT url, md5, packkey FROM packs WHERE name=? AND state='on'",
                        (name,)).fetchone()
    if not row:
        return resp(3001, "包不存在或已下架")
    return resp(data={"url": row["url"], "md5": row["md5"], "key": row["packkey"]})

@app.get("/bd/ping")
async def ping():
    return resp(data={"service": "BubbleDeck", "time": int(time.time())})

init_db()
