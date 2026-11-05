#
# BubbleDeck 商家端 /biz（B 端，V4）
# 与 admin.py 同款能力（上传包/生成卡/删卡/上下架/编辑），但数据视野锁死 owner=自己。
# 铁律：
#   1) 所有查询强制 owner 过滤，所有写操作先校验归属，越权一律 404（不泄露存在性）
#   2) 复用 admin._process_zip（打包唯一实现），owner 参数写进 packs 表与卡密 JSON
#   3) 会话 cookie（bd_biz，path=/biz）与 admin 完全独立；商家停用立即失效（每次请求查库）
#   4) 商家永远不可见：他人数据、/admin、商家列表、全局统计
# 挂载见 app.py 末尾
#

import hashlib
import hmac
import os
import re
import sys
import time

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, RedirectResponse

import app as appmod
import session as sessionmod
from admin import (formdict, dev, jok, jerr, bad, _process_zip, _hash_pass, all_cards,
                   PACK_URL_BASE, PACKS_FILES_DIR, TOOLS_DIR, MAX_GEN, STATE_TXT)

BIZ_COOKIE = "bd_biz"
SESSION_HOURS = 12

# 登录限速（与 admin 独立计数，key=IP）
_bfail: dict = {}
BFAIL_LIMIT, BLOCK_SECONDS = 5, 300

router = APIRouter(prefix="/biz")

# ────── 会话（session.py：BD_BIZ_SECRET 签名；每次请求回库校验启用状态）──────

def _current_merchant(request: Request):
    """返回商家 dict（含 id），未登录/停用/账号已删 → None"""
    mid = sessionmod.biz_check(request.cookies.get(BIZ_COOKIE, ""))
    if not mid:
        return None
    with appmod.db() as c:
        m = c.execute("SELECT id, username, shop FROM merchants WHERE id=? AND state='on'",
                      (int(mid),)).fetchone()
    return {"id": str(m["id"]), "username": m["username"], "shop": m["shop"] or ""} if m else None

def guard_b(request: Request):
    if m := _current_merchant(request):
        return None, m
    return RedirectResponse("/biz/login", 302), None

def _g_b(request: Request):
    """JSON 守卫：未登录/停用 → 401 JSON"""
    m = _current_merchant(request)
    if not m:
        return JSONResponse({"code": 401, "msg": "登录已过期，请重新登录"}, status_code=401)
    return m

def render_b(request: Request, name: str, active: str, title: str, m: dict, **ctx):
    from admin import templates
    return templates.TemplateResponse(request=request, name=f"biz/{dev(request)}/{name}", context={
        "active": active, "title": title, "shop": m.get("shop") or m.get("username"), **ctx})

# ────── 登录 / 登出 ──────

def _client_ip(request: Request) -> str:
    return (request.headers.get("x-real-ip") or request.client.host or "?") if request.client else "?"

@router.get("/login")
async def login_page(request: Request, msg: str = ""):
    err = ""
    if msg == "bad":
        err = "账号或密码错误"
    elif msg == "off":
        err = "账号已停用，请联系管理员"
    until = _bfail.get(_client_ip(request), {}).get("until", 0)
    if time.time() < until:
        err = f"失败次数过多，请 {int(until - time.time()) + 1} 秒后再试"
    from admin import templates
    return templates.TemplateResponse(request=request, name=f"biz/{dev(request)}/login.html",
                                      context={"err": err})

@router.post("/login")
async def login(request: Request):
    ip = _client_ip(request)
    st = _bfail.setdefault(ip, {"n": 0, "until": 0})
    if time.time() < st["until"]:
        return RedirectResponse("/biz/login?msg=bad", 302)
    form = await formdict(request)
    username = str(form.get("username", "")).strip()
    pwd = str(form.get("pass", ""))
    with appmod.db() as c:
        m = c.execute("SELECT * FROM merchants WHERE username=?", (username,)).fetchone()
    if not m or not _verify_pwd(pwd, m["pass_hash"]):
        st["n"] += 1
        if st["n"] >= BFAIL_LIMIT:
            st["until"] = time.time() + BLOCK_SECONDS
            st["n"] = 0
        return RedirectResponse("/biz/login?msg=bad", 302)
    if m["state"] != "on":
        return RedirectResponse("/biz/login?msg=off", 302)
    _bfail.pop(ip, None)
    r = RedirectResponse("/biz", 302)
    r.set_cookie(BIZ_COOKIE, sessionmod.biz_make(str(m["id"])), max_age=SESSION_HOURS * 3600,
                 httponly=True, samesite="lax", path="/biz")
    return r

def _verify_pwd(pwd: str, stored: str) -> bool:
    try:
        salt, _, h = stored.partition("$")
        return hmac.compare_digest(
            hashlib.pbkdf2_hmac("sha256", pwd.encode(), salt.encode(), 100_000).hex(), h)
    except ValueError:
        return False

@router.get("/logout")
async def logout():
    r = RedirectResponse("/biz/login")
    r.delete_cookie(BIZ_COOKIE, path="/biz")
    return r

# ────── 修改密码（商家自助）──────

@router.get("/password")
async def password_page(request: Request):
    red, m = guard_b(request)
    if red:
        return red
    return render_b(request, "password.html", "password", "修改密码", m)

@router.post("/api/password")
async def api_password(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    form = await formdict(request)
    old = str(form.get("old", ""))
    new = str(form.get("new", ""))
    if not old or not new:
        return jerr("请填写旧密码和新密码", 2)
    if not 6 <= len(new) <= 64:
        return jerr("新密码长度需在 6-64 位之间", 2)
    with appmod.db() as c:
        row = c.execute("SELECT pass_hash FROM merchants WHERE id=?", (int(m["id"]),)).fetchone()
        if not row or not _verify_pwd(old, row["pass_hash"]):
            return jerr("旧密码错误", 2)
        c.execute("UPDATE merchants SET pass_hash=? WHERE id=?", (_hash_pass(new), int(m["id"])))
    return jok({"username": m["username"]}, msg="密码已修改")

# ────── 页面 ──────

@router.get("")
@router.get("/")
async def overview(request: Request):
    r, m = guard_b(request)
    if r:
        return r
    own = str(m["id"])
    cards = [c for c in _own_cards(own)]
    stats = {"unused": 0, "active": 0, "revoked": 0}
    recent_raw = []
    for c in cards:
        stats[c["state"]] = stats.get(c["state"], 0) + 1
        if c["act_ts"]:
            recent_raw.append(c)
    recent_raw.sort(key=lambda x: x["act_ts"], reverse=True)
    with appmod.db() as c:
        pk = dict(c.execute("SELECT state, COUNT(*) n FROM packs WHERE owner=? GROUP BY state",
                            (own,)).fetchall())
    cards_stat = [
        {"label": "我的卡密", "value": len(cards), "tone": "indigo"},
        {"label": "未使用", "value": stats.get("unused", 0), "tone": "gray"},
        {"label": "已激活", "value": stats.get("active", 0), "tone": "green"},
        {"label": "已封禁", "value": stats.get("revoked", 0), "tone": "red"},
        {"label": "我的包", "value": pk.get("on", 0) + pk.get("off", 0), "tone": "cyan"},
        {"label": "上架中", "value": pk.get("on", 0), "tone": "amber"},
    ]
    recent = [{"license": x["license"], "wxid": x["wxid"], "device": x["device"], "at": x["at"]}
              for x in recent_raw[:10]]
    return render_b(request, "overview.html", "ov", "概览", m, cards_stat=cards_stat, recent=recent,
                    packs_on=pk.get('on', 0), packs_total=pk.get('on', 0) + pk.get('off', 0),
                    now=time.strftime("%Y-%m-%d %H:%M:%S"))

@router.get("/packs")
async def packs_page(request: Request, edit: str = ""):
    r, m = guard_b(request)
    if r:
        return r
    own = str(m["id"])
    edit_row = None
    if edit:
        with appmod.db() as c2:
            e = c2.execute("""SELECT p.name, p.version, p.size, p.md5, p.url,
                                     k.packkey AS packkey
                              FROM packs p LEFT JOIN keys k
                                ON k.pack=p.name AND k.version=p.version
                              WHERE p.name=? AND p.owner=?""", (edit, own)).fetchone()
        if e:
            edit_row = {"name": e["name"], "version": e["version"], "size": e["size"],
                        "md5": e["md5"], "url": e["url"], "packkey": e["packkey"]}
        else:
            return RedirectResponse("/biz/packs", 302)      # 他人包：不泄露存在性
    return render_b(request, "packs.html", "packs", "包管理", m, edit=edit_row)

@router.get("/cards")
async def cards_page(request: Request):
    r, m = guard_b(request)
    if r:
        return r
    with appmod.db() as c:
        packs_on = [x["name"] for x in c.execute(
            "SELECT name FROM packs WHERE state='on' AND owner=? ORDER BY name",
            (str(m["id"]),)).fetchall()]
    return render_b(request, "cards.html", "cards", "卡密管理", m,
                    packs_on=packs_on, state_options=STATE_TXT)

# ────── 数据（仅 owner=自己）──────

def _own_cards(own: str) -> list:
    from admin import all_cards
    return [c for c in all_cards() if c.get("owner") == own]

# ────── 包 API（全部带归属校验）──────

def _own_pack(c, name: str, own: str):
    """返回包行；不存在或不属于自己 → None（统一 404 语义，不泄露存在性）"""
    return c.execute("SELECT name, url, state, owner FROM packs WHERE name=? AND owner=?",
                     (name, own)).fetchone()

@router.get("/api/packs")
async def api_packs_list(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    with appmod.db() as c:
        raw = c.execute("SELECT name,version,size,md5,url,state FROM packs WHERE owner=? ORDER BY name",
                        (m["id"],)).fetchall()
    rows = [{"name": x["name"], "version": x["version"], "size": x["size"], "size_cn": bad(x["size"]),
             "md5": x["md5"], "url": x["url"], "on": x["state"] == "on"} for x in raw]
    return jok({"rows": rows})

@router.post("/api/packs/upload")
async def api_packs_upload(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    form = await request.form()
    up = form.get("file")
    if up is None or not getattr(up, "filename", ""):
        return JSONResponse({"code": 1, "msg": "请选择 zip 文件"})
    raw = await up.read()
    res = _process_zip(raw, up.filename,
                       name=str(form.get("name") or "").strip(),
                       version=str(form.get("version") or "").strip(),
                       owner=m["id"])
    if res["ok"]:
        return JSONResponse({"code": 0, "msg": "", "data": res["data"]})
    j = {"code": 2 if res.get("conflict") else 1, "msg": res["msg"]}
    if res.get("conflict"):
        j["data"] = {"name": res["name"], "version": res["version"]}
    return JSONResponse(j)

@router.post("/api/packs/upsert")
async def api_packs_upsert(request: Request):
    """商家只允许改版本号：服务端对盘上 BDP2 包重签（内层 info.json version 同步改写），
    直链 URL 与密钥不变（密钥复制登记到新版本）；url/md5/size/密钥本身不可手改。"""
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    form = await formdict(request)
    name = str(form.get("name", "")).strip()
    version = str(form.get("version", "")).strip()
    if not (name and version):
        return jerr("包名和版本不能为空", 2)
    with appmod.db() as c:
        row = c.execute("SELECT version, url FROM packs WHERE name=? AND owner=?",
                        (name, m["id"])).fetchone()
        if not row:
            return jerr("包不存在", code=2)
        old_ver = row["version"]
        if version == old_ver:
            return jerr("新版本号与当前版本相同", 2)
        k = c.execute("SELECT packkey, ver FROM keys WHERE pack=? AND version=?",
                      (name, old_ver)).fetchone()
        if not k:
            return jerr("该包缺少密钥记录，无法改版本，请联系管理员", 2)
        if k["ver"] != 2:
            return jerr("旧格式（v1）包不支持改版本，请重新上传 zip", 2)
        if not (row["url"] or "").startswith(f"{PACK_URL_BASE}/"):
            return jerr("外链包不支持改版本，请重新上传 zip", 2)
        fpath = os.path.join(PACKS_FILES_DIR, os.path.basename(row["url"]))
        try:
            with open(fpath, "rb") as f:
                blob = f.read()
        except OSError:
            return jerr("包文件缺失，无法改版本，请重新上传 zip", 2)
        if TOOLS_DIR not in sys.path:
            sys.path.insert(0, TOOLS_DIR)
        import pack as packtool
        try:
            new_blob = packtool.repack_version(blob, name, old_ver, version, k["packkey"])
        except Exception:
            return jerr("包文件重签失败（容器损坏或密钥不匹配？），请重新上传 zip", 2)
        with open(fpath, "wb") as f:
            f.write(new_blob)
        c.execute("UPDATE packs SET version=?, size=?, md5=? WHERE name=? AND owner=?",
                  (version, len(new_blob),
                   hashlib.md5(new_blob).hexdigest(), name, m["id"]))
        c.execute("""INSERT INTO keys(pack, version, packkey, ver) VALUES(?,?,?,?)
                     ON CONFLICT(pack, version) DO UPDATE SET packkey=excluded.packkey, ver=excluded.ver""",
                  (name, version, k["packkey"], 2))
    return jok({"name": name, "version": version},
               msg=f"已将 {name} 版本更新为 {version}（包文件已重签，直链不变）")

@router.post("/api/packs/state")
async def api_packs_state(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    form = await formdict(request)
    name = str(form.get("name", "")).strip()
    state = "on" if form.get("state") == "on" else "off"
    with appmod.db() as c:
        n = c.execute("UPDATE packs SET state=? WHERE name=? AND owner=?",
                      (state, name, m["id"])).rowcount
    if not n:
        return jerr("包不存在", code=2)
    return jok({"name": name, "on": state == "on"},
               msg=f"{name} 已{'上架' if state == 'on' else '下架'}")

@router.post("/api/packs/delete")
async def api_packs_delete(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    form = await formdict(request)
    name = str(form.get("name", "")).strip()
    with appmod.db() as c:
        row = _own_pack(c, name, m["id"])
        if not row:
            return jerr("包不存在", code=2)
        # 挂卡拒删：全量检查（不限归属）——包删了任何人的卡都无包可装
        n_cards = sum(1 for cd in all_cards() if cd.get("pack") == name)
        if n_cards:
            return jerr(f"拒删 {name}：还有 {n_cards} 张卡密挂在它上面，请先删除这些卡密", code=2)
        c.execute("DELETE FROM keys WHERE pack=?", (name,))
        c.execute("DELETE FROM packs WHERE name=? AND owner=?", (name, m["id"]))
    url = row["url"] or ""
    if url.startswith(f"{PACK_URL_BASE}/"):
        try:
            os.remove(os.path.join(PACKS_FILES_DIR, os.path.basename(url)))
        except OSError:
            return jerr(f"已删除 {name} 的登记与密钥，但包文件移除失败，请联系管理员清理")
    return jok({"name": name}, msg=f"已删除 {name}（登记、密钥、包文件一并移除，不可恢复）")

# ────── 卡密 API（全部带归属校验）──────

@router.get("/api/cards")
async def api_cards_list(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    rows = [{**c, "state_cn": STATE_TXT.get(c["state"], c["state"]),
             "can_revoke": c["state"] != "revoked"} for c in _own_cards(m["id"])]
    return jok({"rows": rows})

@router.post("/api/cards/generate")
async def api_cards_generate(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    form = await formdict(request)
    n = str(form.get("n", ""))
    pack = str(form.get("pack", "")).strip()
    if not n.isdigit() or not (1 <= int(n) <= MAX_GEN):
        return jerr(f"数量需为 1-{MAX_GEN} 的整数")
    if not pack:
        return jerr("必须选择卡密对应的气泡包")
    with appmod.db() as c:
        if not _own_pack(c, pack, m["id"]):
            return jerr("包不存在（只能为自己的包生成卡密）", code=2)
    import secrets as _secrets
    alpha = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    cards = []
    for _ in range(int(n)):
        while True:
            raw = "".join(_secrets.choice(alpha) for _ in range(16))
            card = "-".join(raw[i:i + 4] for i in range(0, 16, 4))
            if not os.path.exists(appmod.card_path(card)):
                break
        appmod.save_card({"license": card, "pack_name": pack, "state": "unused", "owner": m["id"]})
        cards.append(card)
    return jok({"cards": cards}, msg=f"已生成 {len(cards)} 张，请立即复制保存")

def _own_card(license_key: str, own: str):
    """归属校验：卡不存在 / 不属于自己 → None（统一 404 语义）"""
    if not license_key:
        return None
    card = appmod.load_card(license_key)
    if not isinstance(card, dict) or (card.get("owner") or "") != own:
        return None
    return card

@router.post("/api/cards/state")
async def api_cards_state(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    form = await formdict(request)
    license_key = str(form.get("license", "")).strip()
    card = _own_card(license_key, m["id"])
    if not card:
        return jerr("卡密不存在", code=2)
    if card.get("state") != "revoked":                    # 记住封禁前状态，解封恢复用
        card["prev_state"] = card["state"]
        card["state"] = "revoked"
        appmod.save_card(card)
    return jok({"license": license_key, "state": "revoked"},
               msg=f"已封禁 {license_key}（激活接口将拒绝该码）")

@router.post("/api/cards/unrevoke")
async def api_cards_unrevoke(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    form = await formdict(request)
    license_key = str(form.get("license", "")).strip()
    card = _own_card(license_key, m["id"])
    if not card:
        return jerr("卡密不存在", code=2)
    if card.get("state") != "revoked":
        return jerr("该卡密未被封禁", code=2)
    prev = card.get("prev_state") or "unused"
    if prev == "revoked":                                 # 数据兜底：异常卡一律回到未使用
        prev = "unused"
    card["state"] = prev
    if prev == "unused":                                  # 回到未使用 → 清空激活痕迹，可重新激活
        card.pop("bind_wxid", None)
        card.pop("activated_at", None)
        card.pop("devices", None)
    card.pop("prev_state", None)
    appmod.save_card(card)
    state_cn = STATE_TXT.get(prev, prev)
    return jok({"license": license_key, "state": prev},
               msg=f"已解封 {license_key}（回到{state_cn}）")

@router.post("/api/cards/delete")
async def api_cards_delete(request: Request):
    m = _g_b(request)
    if isinstance(m, JSONResponse):
        return m
    form = await formdict(request)
    license_key = str(form.get("license", "")).strip()
    card = _own_card(license_key, m["id"])
    if not card:
        return jerr("卡密不存在", code=2)
    was_active = card.get("state") == "active"
    try:
        os.remove(appmod.card_path(license_key))
    except OSError:
        return jerr(f"删除失败：{license_key}")
    msg = f"已删除 {license_key}" + ("（该微信号的授权随即失效）" if was_active else "（文件已移除，不可恢复）")
    return jok({"license": license_key, "was_active": was_active}, msg=msg)
