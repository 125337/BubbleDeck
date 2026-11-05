#
# BubbleDeck 授权 API（V4：客户端零秘密）
# 两业务接口：activate / packs，外加 ping。无请求签名校验（dylib 零秘密，
# 防护 = HTTPS + 限频 + 卡密 16 位熵 + wxid 绑定业务逻辑，见 docs/授权系统方案.md §信任模型）。
# 存储：卡密 = 按卡一文件 licenses/<卡密>.json；包 = SQLite（packs + keys 两表）
# 限频：实例内存滑动窗口（activate 100 次/时 → 1007；packs 120 次/时 → 429）
# 契约见 docs/授权系统方案.md §三
#
# 运行：uvicorn app:app --host 127.0.0.1 --port 8000
# 环境变量：BD_DB（SQLite 路径，默认同目录 bd.db）
#           BD_LICENSES_DIR（卡密文件目录，默认同目录 licenses/）
# 后台/商家会话密钥见 session.py（BD_ADMIN_SECRET / BD_BIZ_SECRET）
#

import os
import json
import time
import sqlite3

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
DB_PATH    = os.environ.get("BD_DB", os.path.join(BASE_DIR, "bd.db"))
CARDS_DIR  = os.environ.get("BD_LICENSES_DIR", os.path.join(BASE_DIR, "licenses"))

ACTIVATE_HOURLY = 100                                     # 同 device_id|IP 每小时（买 30 个包一次激活够用）
PACKS_HOURLY    = 120

app = FastAPI()

# ────── SQLite（packs + keys） ──────

def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    os.makedirs(CARDS_DIR, exist_ok=True)
    with db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS packs(
            name    TEXT PRIMARY KEY,
            version TEXT NOT NULL,
            size    INTEGER NOT NULL DEFAULT 0,
            md5     TEXT NOT NULL,
            url     TEXT NOT NULL,
            packkey TEXT NOT NULL,                        -- 兼容遗留：v1 容器 32 字符原文
            state   TEXT NOT NULL DEFAULT 'on'            -- on/off
        );
        CREATE TABLE IF NOT EXISTS keys(                  -- 每包每版本一把（base64 32B）
            pack    TEXT NOT NULL,
            version TEXT NOT NULL,
            packkey TEXT NOT NULL,
            ver     INTEGER NOT NULL DEFAULT 2,           -- 容器版本（2=BDP2）
            PRIMARY KEY(pack, version)
        );
        CREATE TABLE IF NOT EXISTS merchants(             -- B 端商家账号（biz.py 用）
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            username  TEXT NOT NULL UNIQUE,
            pass_hash TEXT NOT NULL,                      -- pbkdf2: salt$hex
            shop      TEXT NOT NULL DEFAULT '',
            state     TEXT NOT NULL DEFAULT 'on',         -- on/off
            created   INTEGER NOT NULL DEFAULT 0
        );
        """)
        # 轻量迁移：packs 补 owner 列（'' = 平台直营；B 端商家归属）
        cols = {r[1] for r in c.execute("PRAGMA table_info(packs)").fetchall()}
        if "owner" not in cols:
            c.execute("ALTER TABLE packs ADD COLUMN owner TEXT NOT NULL DEFAULT ''")

# ────── 限频（实例内存，重启清零即可） ──────

_RATE: dict = {}

def rate_hit(scope: str, ident: str, limit: int) -> bool:
    """未超限 True 并记一次；超限 False"""
    now = time.time()
    key = f"{scope}|{ident}"
    arr = [t for t in _RATE.get(key, ()) if now - t < 3600]
    ok = len(arr) < limit
    if ok:
        arr.append(now)
    _RATE[key] = arr
    return ok

def client_ip(request: Request) -> str:
    # SCF/反代场景取转发头，兜底直连地址
    fwd = request.headers.get("X-Forwarded-For", "")
    return (fwd.split(",")[0].strip() if fwd else "") or (request.client.host if request.client else "?")

# ────── 卡密文件（按卡一 JSON） ──────

def card_path(license_key: str) -> str:
    return os.path.join(CARDS_DIR, license_key + ".json")

def load_card(license_key: str):
    try:
        with open(card_path(license_key), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def save_card(card: dict):
    with open(card_path(card["license"]), "w", encoding="utf-8") as f:
        json.dump(card, f, ensure_ascii=False, indent=1)

# ────── 工具 ──────

def resp(code=0, msg="ok", data=None):
    return JSONResponse({"code": code, "msg": msg, "data": data or {}})

# ────── 接口 ──────

@app.post("/bd/activate")
async def activate(request: Request):
    body = await request.body()
    try:
        j = json.loads(body)
        license_key, device, wxid = j["license"], j["device_id"], j["wxid"]
    except Exception:
        return resp(1004, "参数缺失")
    if not rate_hit("activate", f"{device}|{client_ip(request)}", ACTIVATE_HOURLY):
        return resp(1007, "操作过于频繁，请一小时后再试")

    card = load_card(license_key)
    if not card:
        return resp(1001, "卡密不存在")
    if card.get("state") == "revoked":
        return resp(1002, "卡密已停用")
    bound = card.get("bind_wxid")
    if bound and bound != wxid:
        return resp(1005, "此码已绑定其他微信号")      # 一票否决：码跟着号走
    if not bound:                                       # 首输码者拥有该码，永久生效
        card["state"] = "active"
        card["bind_wxid"] = wxid
        card["activated_at"] = int(time.time())
    card.setdefault("devices", {})[device] = int(time.time())   # IDFV 仅记录，不参与校验
    save_card(card)
    return resp(data={"pack_name": card.get("pack_name", "")})

@app.post("/bd/packs")
async def packs(request: Request):
    body = await request.body()
    try:
        j = json.loads(body)
        device, wxid = j["device_id"], j["wxid"]
    except Exception:
        return resp(1004, "参数缺失")
    if not rate_hit("packs", f"{device}|{client_ip(request)}", PACKS_HOURLY):
        return resp(429, "请求过于频繁，请稍后再试")

    # owned = 该 wxid 名下 state=active 的卡
    owned = set()
    try:
        for fn in os.listdir(CARDS_DIR):
            if not fn.endswith(".json"):
                continue
            card = load_card(fn[:-5])
            if card and card.get("state") == "active" and card.get("bind_wxid") == wxid:
                owned.add(card.get("pack_name"))
    except FileNotFoundError:
        pass

    out = []
    with db() as c:
        rows = c.execute("""SELECT name, version, size, md5, url, packkey FROM packs
                            WHERE state='on' ORDER BY name""").fetchall()
        for r in rows:
            item = {"name": r["name"], "version": r["version"], "size": r["size"],
                    "md5": r["md5"], "url": r["url"], "owned": r["name"] in owned}
            if item["owned"]:
                k = c.execute("SELECT packkey, ver FROM keys WHERE pack=? AND version=?",
                              (r["name"], r["version"])).fetchone()
                if k:                                   # 密钥只认 keys 表（BDP2: ver=2）
                    item["key"], item["ver"] = k["packkey"], k["ver"]
                else:                                   # keys 表无记录 → 不下发
                    item["key"], item["ver"] = None, None
            else:
                item["key"], item["ver"] = None, None
            out.append(item)
    return resp(data={"packs": out})

@app.get("/bd/ping")
async def ping():
    return resp(data={"service": "BubbleDeck", "time": int(time.time())})

init_db()

from admin import router as admin_router
app.include_router(admin_router)
from biz import router as biz_router
app.include_router(biz_router)
