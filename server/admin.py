#
# BubbleDeck 管理后台 /admin（逻辑层，V4）
# 登录（密码 = BD_ADMIN_PASS 环境变量；会话 = session.py / BD_ADMIN_SECRET）+ 概览 / 卡密 / 包 三页
# 数据源与 app.py(V3) 一致：卡密 = licenses/<卡密>.json（每卡一文件），包 = SQLite packs 表
# 路由/会话/表单逻辑在本文件，全部 UI 在 templates/（Jinja2，改模板即时生效无需重启）
# 挂载见 app.py 末尾
#

import base64
import hashlib
import hmac
import io
import json
import os
import re
import secrets
import shutil
import sys
import tempfile
import time
import zipfile
from pathlib import PurePosixPath
from urllib.parse import quote

from fastapi import APIRouter, Request
from fastapi import HTTPException
from fastapi.responses import JSONResponse, RedirectResponse, FileResponse
from fastapi.templating import Jinja2Templates

import app as appmod
import session as sessionmod

PASS = os.environ.get("BD_ADMIN_PASS", "")                # 未配置则无法登录
SESSION_COOKIE = "bd_admin"
SESSION_HOURS = 12                                        # 会话有效期
MAX_GEN = 200                                             # 单次批量生成上限

# 快捷上传：zip → 服务器端 BDP2 打包 → 本站直链托管
TOOLS_DIR = "/opt/BubbleDeck_server/tools"                # pack.py（BDP2 唯一实现，禁止后台另写加密）
PACKS_FILES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "packs_files")
PACK_URL_BASE = "https://qb.xhhan.xyz/packfiles"
MAX_UPLOAD = 20 * 1024 * 1024                             # 20MB

# 登录限速：连续失败次数 + 锁定截止时间（单进程内存态）
_fail = {"count": 0, "until": 0}
FAIL_LIMIT, LOCK_SECONDS = 5, 60

templates = Jinja2Templates(directory=os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates"))

STATE_TXT = {"unused": "未使用", "active": "已激活", "revoked": "已封禁"}

router = APIRouter(prefix="/admin")

# ────── 会话（session.py：BD_ADMIN_SECRET 签名，无状态） ──────

def _check_session(request: Request) -> bool:
    return sessionmod.admin_check(request.cookies.get(SESSION_COOKIE, ""))

def guard(request: Request):
    """已登录返回 None，否则返回跳登录页的响应"""
    if _check_session(request):
        return None
    return RedirectResponse("/admin/login", 302)

# ────── 工具 ──────

async def formdict(request: Request) -> dict:
    """解析表单为单值 dict。全站统一 multipart/form-data 一种编码。

    历史教训：早期实现只解析 urlencoded（免 python-multipart 依赖的旧设计），
    异步化改造后浏览器 fetch 全发 multipart，导致列表操作收到空字段
    （"包不存在："空名事故）。现约定：所有后台接口只收 multipart；
    原生表单必须写 enctype="multipart/form-data"（登录/登记/生成 6 处已加）；
    curl 调试用 -F 不用 -d。
    """
    form = await request.form()
    return {k: v for k, v in form.items() if isinstance(v, str)}

def ts2str(ts) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts)) if ts else "-"

def redirect(url: str):
    return RedirectResponse(url, 302)

MOBILE_UA = re.compile(r"Mobile|Android|iPhone|iPad|Phone", re.I)

def dev(request: Request) -> str:
    """按 User-Agent 分流模板：m/ = 移动版，pc/ = 桌面版；?force=m|pc 可强制"""
    f = request.query_params.get("force")
    if f in ("m", "pc"):
        return f
    return "m" if MOBILE_UA.search(request.headers.get("user-agent", "")) else "pc"

def render(request: Request, name: str, active: str, title: str, flash: str = "", **ctx):
    return templates.TemplateResponse(request=request, name=f"{dev(request)}/{name}", context={
        "active": active, "title": title, "flash": flash, **ctx})

def bad(size) -> str:
    return f"{size/1024/1024:.2f}MB" if size >= 1024 * 1024 else f"{size/1024:.1f}KB" if size >= 1024 else f"{size}B"

def merchants_map() -> dict:
    """商家 id → username（admin 展示归属用）"""
    with appmod.db() as c:
        return {str(r["id"]): (r["username"] + (f"（{r['shop']}）" if r["shop"] else ""))
                for r in c.execute("SELECT id, username, shop FROM merchants").fetchall()}

# JSON 接口统一响应（与 /bd 风格一致：{code,msg,data}；code=0 成功 / 1 业务错误 / 2 冲突提示 / 401 未登录）
def jok(data=None, msg: str = ""):
    j = {"code": 0, "msg": msg}
    if data is not None:
        j["data"] = data
    return JSONResponse(j)

def jerr(msg: str, code: int = 1, data=None):
    j = {"code": code, "msg": msg}
    if data is not None:
        j["data"] = data
    return JSONResponse(j)

def _g(request: Request):
    """JSON 接口守卫：未登录返回 401 JSON（页面路由用 guard 返回 redirect）"""
    return jerr("登录已过期，请刷新页面", 401) if guard(request) else None

def all_cards() -> list:
    """扫描卡密目录，返回按卡号排序的摘要列表（V3：licenses/*.json）"""
    out = []
    try:
        fns = os.listdir(appmod.CARDS_DIR)
    except FileNotFoundError:
        return out
    for fn in fns:
        if not fn.endswith(".json"):
            continue
        lic = fn[:-5]
        c = appmod.load_card(lic)
        if not isinstance(c, dict):
            continue
        devs = c.get("devices") or {}
        last_dev = max(devs.items(), key=lambda kv: kv[1])[0] if devs else ""
        out.append({"license": lic, "pack": c.get("pack_name") or "-",
                    "state": c.get("state") or "unused",
                    "owner": c.get("owner") or "",
                    "wxid": c.get("bind_wxid") or "-", "device": last_dev or "-",
                    "at": ts2str(c.get("activated_at")),
                    "act_ts": c.get("activated_at") or 0})
    out.sort(key=lambda r: r["license"])
    return out

# ────── 登录 / 登出 ──────

@router.get("/login")
async def login_page(request: Request, msg: str = ""):
    err = ""
    if msg == "bad":
        err = "密码错误"
    elif msg == "nopass":
        err = "服务端未配置 BD_ADMIN_PASS，无法登录"
    lock = max(0, int(_fail["until"] - time.time()))
    if lock:
        err = f"失败次数过多，请 {lock} 秒后再试"
    return templates.TemplateResponse(request=request, name=f"{dev(request)}/login.html", context={"err": err})

@router.post("/login")
async def login(request: Request):
    if time.time() < _fail["until"]:
        return redirect("/admin/login?msg=bad")
    form = await formdict(request)
    pwd = str(form.get("pass", ""))
    if not PASS:
        return redirect("/admin/login?msg=nopass")
    if not hmac.compare_digest(pwd, PASS):
        _fail["count"] += 1
        if _fail["count"] >= FAIL_LIMIT:
            _fail["until"] = time.time() + LOCK_SECONDS
            _fail["count"] = 0
        return redirect("/admin/login?msg=bad")
    _fail["count"] = 0
    r = redirect("/admin")
    r.set_cookie(SESSION_COOKIE, sessionmod.admin_make(), max_age=SESSION_HOURS * 3600,
                 httponly=True, samesite="lax", path="/")
    return r

@router.get("/logout")
async def logout():
    r = redirect("/admin/login")
    r.delete_cookie(SESSION_COOKIE, path="/")
    return r

# ────── 概览 ──────

@router.get("")
@router.get("/")
async def overview(request: Request):
    if r := guard(request):
        return r
    cards = all_cards()
    stats = {"unused": 0, "active": 0, "revoked": 0}
    today0 = int(time.time()) - int(time.time()) % 86400 - 8 * 3600    # 东八区当日零点
    today_act = 0
    recent_raw = []
    for r in cards:
        stats[r["state"]] = stats.get(r["state"], 0) + 1
        if r["state"] == "active" and r["act_ts"] >= today0:
            today_act += 1
        if r["act_ts"]:
            recent_raw.append(r)
    recent_raw.sort(key=lambda r: r["act_ts"], reverse=True)
    with appmod.db() as c:
        pk = dict(c.execute("SELECT state, COUNT(*) n FROM packs GROUP BY state").fetchall())
    cards_stat = [
        {"label": "卡密总数", "value": len(cards), "tone": "indigo"},
        {"label": "未使用", "value": stats.get("unused", 0), "tone": "gray"},
        {"label": "已激活", "value": stats.get("active", 0), "tone": "green"},
        {"label": "已封禁", "value": stats.get("revoked", 0), "tone": "red"},
        {"label": "今日激活", "value": today_act, "tone": "cyan"},
        {"label": "上架包数", "value": f"{pk.get('on', 0)}/{pk.get('on', 0) + pk.get('off', 0)}", "tone": "amber"},
    ]
    recent = [{"license": r["license"], "wxid": r["wxid"], "device": r["device"], "at": r["at"]}
              for r in recent_raw[:10]]
    return render(request, "overview.html", "ov", "概览", cards_stat=cards_stat, recent=recent,
                  packs_on=pk.get('on', 0), packs_total=pk.get('on', 0) + pk.get('off', 0),
                  now=time.strftime("%Y-%m-%d %H:%M:%S"))

# ────── 卡密（页面骨架 + JSON API，列表与操作全异步零刷新）──────

@router.get("/cards")
async def cards_page(request: Request):
    if r := guard(request):
        return r
    with appmod.db() as c:
        packs_on = [r["name"] for r in c.execute(
            "SELECT name FROM packs WHERE state='on' ORDER BY name").fetchall()]
    return render(request, "cards.html", "cards", "卡密管理",
                  packs_on=packs_on, state_options=STATE_TXT,
                  merchants=[{"id": mid, "name": mn} for mid, mn in merchants_map().items()])

@router.get("/api/cards")
async def api_cards_list(request: Request):
    if g := _g(request):
        return g
    mmap = merchants_map()
    rows = [{**r, "state_cn": STATE_TXT.get(r["state"], r["state"]),
             "owner_cn": mmap.get(r["owner"], "直营") if r["owner"] else "直营",
             "can_revoke": r["state"] != "revoked"} for r in all_cards()]
    return jok({"rows": rows})

@router.post("/api/cards/generate")
async def api_cards_generate(request: Request):
    if g := _g(request):
        return g
    form = await formdict(request)
    n = str(form.get("n", ""))
    pack = str(form.get("pack", "")).strip()
    owner = str(form.get("owner", "")).strip()          # 归属商家 id（空=直营）
    if not n.isdigit() or not (1 <= int(n) <= MAX_GEN):
        return jerr(f"数量需为 1-{MAX_GEN} 的整数")
    if not pack:
        return jerr("必须选择卡密对应的气泡包")
    with appmod.db() as c:
        if not c.execute("SELECT 1 FROM packs WHERE name=?", (pack,)).fetchone():
            return jerr("包不存在：" + pack + "（先在包管理页上架）")
        if owner and not c.execute("SELECT 1 FROM merchants WHERE id=?", (owner,)).fetchone():
            return jerr("归属商家不存在")
    alpha = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"                  # 去易混字符，同 manage.gencards
    cards = []
    for _ in range(int(n)):
        while True:                                            # 撞号重生成（文件即唯一键）
            raw = "".join(secrets.choice(alpha) for _ in range(16))
            card = "-".join(raw[i:i + 4] for i in range(0, 16, 4))
            if not os.path.exists(appmod.card_path(card)):
                break
        appmod.save_card({"license": card, "pack_name": pack, "state": "unused", "owner": owner})
        cards.append(card)
    return jok({"cards": cards}, msg=f"已生成 {len(cards)} 张，请立即复制保存")

@router.post("/api/cards/state")
async def api_cards_state(request: Request):
    if g := _g(request):
        return g
    form = await formdict(request)
    license_key = str(form.get("license", "")).strip()
    card = appmod.load_card(license_key) if license_key else None
    if not card:
        return jerr(f"卡密不存在：{license_key}")
    if card.get("state") != "revoked":                    # 记住封禁前状态，解封/恢复用
        card["prev_state"] = card["state"]
        card["state"] = "revoked"
        appmod.save_card(card)
    return jok({"license": license_key, "state": "revoked"},
               msg=f"已封禁 {license_key}（激活接口将拒绝该码）")

@router.post("/api/cards/delete")
async def api_cards_delete(request: Request):
    if g := _g(request):
        return g
    form = await formdict(request)
    license_key = str(form.get("license", "")).strip()
    card = appmod.load_card(license_key) if license_key else None
    if not card:
        return jerr(f"卡密不存在：{license_key}")
    was_active = card.get("state") == "active"
    try:
        os.remove(appmod.card_path(license_key))
    except OSError:
        return jerr(f"删除失败：{license_key}")
    msg = f"已删除 {license_key}" + ("（该微信号的授权随即失效）" if was_active else "（文件已移除，不可恢复）")
    return jok({"license": license_key, "was_active": was_active}, msg=msg)

# ────── 包 ──────

@router.get("/packs")
async def packs_page(request: Request, edit: str = ""):
    if r := guard(request):
        return r
    edit_row = None
    if edit:
        with appmod.db() as c2:
            e = c2.execute("""SELECT p.name, p.version, p.size, p.md5, p.url,
                                     k.packkey AS packkey
                              FROM packs p LEFT JOIN keys k
                                ON k.pack=p.name AND k.version=p.version
                              WHERE p.name=?""", (edit,)).fetchone()
        if e:
            edit_row = {"name": e["name"], "version": e["version"], "size": e["size"],
                        "md5": e["md5"], "url": e["url"], "packkey": e["packkey"]}
        else:
            return redirect("/admin/packs")
    return render(request, "packs.html", "packs", "包管理", edit=edit_row,
                  merchants=[{"id": mid, "name": mn} for mid, mn in merchants_map().items()])

@router.get("/api/packs")
async def api_packs_list(request: Request):
    if g := _g(request):
        return g
    mmap = merchants_map()
    with appmod.db() as c:
        raw = c.execute("SELECT name,version,size,md5,url,state,owner FROM packs ORDER BY name").fetchall()
    rows = [{"name": x["name"], "version": x["version"], "size": x["size"], "size_cn": bad(x["size"]),
             "md5": x["md5"], "url": x["url"], "on": x["state"] == "on",
             "owner": x["owner"] or "",
             "owner_cn": mmap.get(x["owner"] or "", "直营") if x["owner"] else "直营"} for x in raw]
    return jok({"rows": rows})

def _pack_root(base: str) -> str:
    """归一化 zip 包根（对齐客户端 TDLocatePackRoot）：剥掉用户右键压缩带来的包裹层"""
    if os.path.isfile(os.path.join(base, "info.json")):
        return base
    entries = [e for e in os.listdir(base) if e != "__MACOSX" and not e.startswith(".")]
    if len(entries) == 1 and os.path.isdir(os.path.join(base, entries[0])):
        return os.path.join(base, entries[0])          # 唯一顶层目录即包根（info.json 随后强制重写）
    return base

def _fallback_name(filename: str) -> str:
    """包名兜底：zip 文件名去 .zip 后缀"""
    base = os.path.basename((filename or "").replace("\\", "/")).strip()
    return base[:-4].strip() if base.lower().endswith(".zip") else base

def _process_zip(raw: bytes, filename: str, name: str = "", version: str = "", owner: str = "",
                 author: str = "") -> dict:
    """zip → 归一化 → BDP2 打包 → 双表登记 → 落盘（上传链路唯一实现）。
    成功返回 {"ok":True,"data":{...}}，失败 {"ok":False,"msg":"..."}。
    包名留空 = 文件名兜底，版本留空 = 1.0；info.json 强制重写保证盘上 version ≡ AAD version。
    owner：商家 id（admin 直营传空）
    author：作者名（客户端主题页副标题展示用）。表单值优先，zip 内原 info.json 的 author 兜底，
    两者都无则不写该字段（客户端显示「未知作者」）"""
    name = (name or _fallback_name(filename)).strip()
    version = (version or "1.0").strip()
    if not name or len(name) > 64 or "/" in name or "\\" in name:
        return {"ok": False, "msg": "包名不合法（≤64字符，不含路径符）"}
    if len(raw) > MAX_UPLOAD:
        return {"ok": False, "msg": "文件超过 20MB 上限"}
    if raw[:2] != b"PK":
        return {"ok": False, "msg": "不是合法的 zip 文件"}
    with appmod.db() as c:
        exist = c.execute("SELECT owner FROM packs WHERE name=?", (name,)).fetchone()
        if exist:
            if owner and exist["owner"] != owner:
                # 商家链路：包名全局唯一，撞他人（直营/别家）包名一律拒绝，绝不覆盖
                return {"ok": False, "msg": "包名已被其他店铺使用，请换一个包名"}
            if exist["version"] == version:
                # conflict 标记：前端据此渲染「改版本重传」控件（admin 撞名不同版本=覆盖更新）
                return {"ok": False, "msg": f"{name} v{version} 已存在，改个版本号可直接重传",
                        "conflict": True, "name": name, "version": version}

    tmpd = tempfile.mkdtemp(prefix="bdup_")
    try:
        try:
            with zipfile.ZipFile(io.BytesIO(raw)) as zf:
                for n in zf.namelist():                # 防 zip 路径穿越
                    if n.startswith("/") or ".." in PurePosixPath(n).parts:
                        return {"ok": False, "msg": "zip 内路径不安全，拒收"}
                zf.extractall(tmpd)
        except zipfile.BadZipFile:
            return {"ok": False, "msg": "zip 无法解压（文件已损坏？）"}
        root = _pack_root(tmpd)
        # 归一化 Assets/：客户端按根级 Assets/ 前缀取图，散在包根的图片自动挪入（非图片不动）
        IMG_EXT = (".png", ".jpg", ".jpeg", ".webp", ".gif")
        assets = os.path.join(root, "Assets")
        if not os.path.isdir(assets):
            loose = [f for f in os.listdir(root)
                     if os.path.isfile(os.path.join(root, f))
                     and f != "info.json" and f.lower().endswith(IMG_EXT)]
            if loose:
                os.makedirs(assets, exist_ok=True)
                for f in loose:
                    shutil.move(os.path.join(root, f), os.path.join(assets, f))
        # 0 图拒收：全树一张图标都没有的包没有意义，直接报错避免生成废包
        n_img = sum(1 for r, _d, fs in os.walk(root)
                    if os.path.basename(r) != "__MACOSX"
                    for f in fs if f.lower().endswith(IMG_EXT))
        if n_img == 0:
            return {"ok": False, "msg": "包里没有气泡图标（Assets/ 下或根级需要至少一张图片），拒收"}
        # info.json 强制重写：AAD 一致性铁律。author：表单优先，zip 内原 info.json 兜底（展示用）
        if not author:
            try:
                with open(os.path.join(root, "info.json"), encoding="utf-8") as f:
                    orig = json.load(f)
                if isinstance(orig, dict) and isinstance(orig.get("author"), str):
                    author = orig["author"].strip()
            except Exception:
                pass
        author = author[:64]
        info = {"name": name, "version": version}
        if author:
            info["author"] = author
        with open(os.path.join(root, "info.json"), "w", encoding="utf-8") as f:
            json.dump(info, f, ensure_ascii=False)
        try:
            if TOOLS_DIR not in sys.path:
                sys.path.insert(0, TOOLS_DIR)
            import pack as packtool                    # BDP2 打包唯一实现，直接复用
        except ImportError:
            return {"ok": False, "msg": f"打包工具缺失：{TOOLS_DIR}/pack.py"}
        key = packtool.gen_key()
        blob = packtool.build_bdpack(root, base64.b64decode(key), name, version)
        os.makedirs(PACKS_FILES_DIR, exist_ok=True)
        fname = f"pack-{secrets.token_hex(6)}.bdpack"  # 随机 slug，防猜防中文 URL 坑
        with open(os.path.join(PACKS_FILES_DIR, fname), "wb") as f:
            f.write(blob)
        md5 = hashlib.md5(blob).hexdigest()
        url = f"{PACK_URL_BASE}/{fname}"
        with appmod.db() as c:
            c.execute("""INSERT INTO packs(name, version, size, md5, url, packkey, state, owner)
                         VALUES(?,?,?,?,?,?,'off',?)
                         ON CONFLICT(name) DO UPDATE SET version=?, size=?, md5=?, url=?,
                           packkey=?, state='off'""",
                      (name, version, len(blob), md5, url, key, owner,
                       version, len(blob), md5, url, key))
            c.execute("""INSERT INTO keys(pack, version, packkey, ver) VALUES(?,?,?,2)
                         ON CONFLICT(pack,version) DO UPDATE SET packkey=excluded.packkey, ver=2""",
                      (name, version, key))
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    return {"ok": True, "data": {"name": name, "version": version, "size": len(blob),
                                 "size_cn": bad(len(blob)), "md5": md5, "url": url, "key": key}}

@router.post("/api/packs/upload")
async def api_packs_upload(request: Request):
    """上传流水线原子接口：单个 zip → JSON 结果（页面 JS 逐个调用组队批量）"""
    if r := guard(request):
        return JSONResponse({"code": 401, "msg": "未登录"}, status_code=401)
    form = await request.form()
    up = form.get("file")
    if up is None or not getattr(up, "filename", ""):
        return JSONResponse({"code": 1, "msg": "请选择 zip 文件"})
    raw = await up.read()
    res = _process_zip(raw, up.filename,
                       name=str(form.get("name") or "").strip(),
                       version=str(form.get("version") or "").strip(),
                       author=str(form.get("author") or "").strip())
    if res["ok"]:
        return JSONResponse({"code": 0, "msg": "", "data": res["data"]})
    j = {"code": 2 if res.get("conflict") else 1, "msg": res["msg"]}
    if res.get("conflict"):                      # code=2 冲突：带详情供前端「改版本重传」
        j["data"] = {"name": res["name"], "version": res["version"]}
    return JSONResponse(j)

@router.get("/static/{fname}")
async def admin_static(fname: str):
    """共享前端脚本（admin.js / upload.js，pc/m 双端各一份引用，逻辑只有一份）"""
    if fname not in ("admin.js", "upload.js") or "/" in fname or ".." in fname:
        raise HTTPException(status_code=404)
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates", "static", fname)
    return FileResponse(p, media_type="text/javascript",
                        headers={"Cache-Control": "no-cache"})   # 脚本常改，禁强缓存

@router.post("/api/packs/upsert")
async def api_packs_upsert(request: Request):
    if g := _g(request):
        return g
    form = await formdict(request)
    name = str(form.get("name", "")).strip()
    version = str(form.get("version", "")).strip()
    url = str(form.get("url", "")).strip()
    packkey = str(form.get("packkey", "")).strip()
    md5 = str(form.get("md5", "")).strip().lower()
    size = str(form.get("size", "") or "0")
    if not (name and version and url and packkey and md5):
        return jerr("必填项不能为空")
    if not size.isdigit():
        return jerr("大小需为数字（字节）")
    with appmod.db() as c:
        c.execute("""INSERT INTO packs(name, version, size, md5, url, packkey)
                     VALUES(?,?,?,?,?,?)
                     ON CONFLICT(name) DO UPDATE SET version=?, size=?, md5=?, url=?, packkey=?""",
                  (name, version, int(size), md5, url, packkey, version, int(size), md5, url, packkey))
        # 密钥唯一来源是 keys 表（packs.packkey 仅历史遗留，不再被接口读取）
        kver = 2 if (len(packkey) == 44 and packkey.endswith("=")) else 1
        c.execute("""INSERT INTO keys(pack, version, packkey, ver) VALUES(?,?,?,?)
                     ON CONFLICT(pack,version) DO UPDATE SET packkey=excluded.packkey, ver=excluded.ver""",
                  (name, version, packkey, kver))
        tip = f"{'BDP2' if kver == 2 else 'v1'} 密钥已写入 keys 表"
    return jok({"kver": kver}, msg=f"已保存 {name} v{version}（{tip}）")

@router.post("/api/packs/state")
async def api_packs_state(request: Request):
    if g := _g(request):
        return g
    form = await formdict(request)
    name = str(form.get("name", "")).strip()
    state = "on" if form.get("state") == "on" else "off"
    with appmod.db() as c:
        n = c.execute("UPDATE packs SET state=? WHERE name=?", (state, name)).rowcount
    if not n:
        return jerr(f"包不存在：{name}")
    return jok({"name": name, "on": state == "on"},
               msg=f"{name} 已{'上架' if state == 'on' else '下架'}")

@router.post("/api/packs/delete")
async def api_packs_delete(request: Request):
    if g := _g(request):
        return g
    form = await formdict(request)
    name = str(form.get("name", "")).strip()
    with appmod.db() as c:
        row = c.execute("SELECT url FROM packs WHERE name=?", (name,)).fetchone()
        if not row:
            return jerr(f"包不存在：{name}")
        # 有卡密挂在该包上时拒删：删包后这些卡将无包可装，先处理卡密
        n_cards = sum(1 for cd in all_cards() if cd.get("pack") == name)
        if n_cards:
            return jerr(f"拒删 {name}：还有 {n_cards} 张卡密挂在它上面，请先删除或改绑这些卡密", code=2)
        c.execute("DELETE FROM keys WHERE pack=?", (name,))   # 密钥唯一来源，必须随包清掉
        c.execute("DELETE FROM packs WHERE name=?", (name,))
    url = row["url"] or ""
    if url.startswith(f"{PACK_URL_BASE}/"):        # 本站直链才删文件；外链（GitHub 等）不动
        try:
            os.remove(os.path.join(PACKS_FILES_DIR, os.path.basename(url)))
        except OSError:
            return jerr(f"已删除 {name} 的登记与密钥，但包文件移除失败，请手动清理 packs_files")
    return jok({"name": name}, msg=f"已删除 {name}（登记、密钥、包文件一并移除，不可恢复）")

# ────── 商家（B 端账号管理）──────

def _hash_pass(pw: str) -> str:
    salt = secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 100_000).hex()
    return f"{salt}${h}"

def _verify_pass(pw: str, stored: str) -> bool:
    try:
        salt, _, h = stored.partition("$")
        return hmac.compare_digest(
            hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 100_000).hex(), h)
    except ValueError:
        return False

def _gen_password() -> str:
    return "".join(secrets.choice("ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")
                   for _ in range(10))

@router.get("/merchants")
async def merchants_page(request: Request):
    if r := guard(request):
        return r
    return render(request, "merchants.html", "merchants", "商家管理")

@router.get("/api/merchants")
async def api_merchants_list(request: Request):
    if g := _g(request):
        return g
    with appmod.db() as c:
        rows = [{"id": str(r["id"]), "username": r["username"], "shop": r["shop"] or "",
                 "on": r["state"] == "on", "created": ts2str(r["created"])}
                for r in c.execute("SELECT * FROM merchants ORDER BY id").fetchall()]
    return jok({"rows": rows})

@router.post("/api/merchants/create")
async def api_merchants_create(request: Request):
    if g := _g(request):
        return g
    form = await formdict(request)
    username = str(form.get("username", "")).strip()
    shop = str(form.get("shop", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9_]{3,24}", username):
        return jerr("账号需为 3-24 位字母/数字/下划线")
    pw = _gen_password()
    with appmod.db() as c:
        if c.execute("SELECT 1 FROM merchants WHERE username=?", (username,)).fetchone():
            return jerr(f"账号 {username} 已存在")
        c.execute("INSERT INTO merchants(username, pass_hash, shop, state, created) VALUES(?,?,?,'on',?)",
                  (username, _hash_pass(pw), shop, int(time.time())))
    # 初始密码仅此一次明文返回，请商家立即修改习惯由重置密码兜底
    return jok({"username": username, "password": pw}, msg=f"商家 {username} 已创建")

@router.post("/api/merchants/reset")
async def api_merchants_reset(request: Request):
    if g := _g(request):
        return g
    form = await formdict(request)
    mid = str(form.get("id", "")).strip()
    pw = _gen_password()
    with appmod.db() as c:
        n = c.execute("UPDATE merchants SET pass_hash=? WHERE id=?", (_hash_pass(pw), mid)).rowcount
    if not n:
        return jerr("商家不存在")
    return jok({"password": pw}, msg="密码已重置")

@router.post("/api/merchants/state")
async def api_merchants_state(request: Request):
    if g := _g(request):
        return g
    form = await formdict(request)
    mid = str(form.get("id", "")).strip()
    state = "on" if form.get("state") == "on" else "off"
    with appmod.db() as c:
        n = c.execute("UPDATE merchants SET state=? WHERE id=?", (state, mid)).rowcount
    if not n:
        return jerr("商家不存在")
    return jok({"id": mid, "on": state == "on"},
               msg=f"商家已{'启用' if state == 'on' else '停用'}（停用后立即无法登录与操作）")
