#
# 自测脚本（V4）：activate / packs 两接口 + 错误码全路径
# V4 客户端零秘密：无请求签名，直接 JSON POST。
# 前置：uvicorn app:app --port 8000 且 manage.py 造过数据
# 用法：python test_api.py http://127.0.0.1:8000 [卡号]
#       线上模式：python test_api.py https://qb.xhhan.xyz <卡号>
#

import sys
import os
import json
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000") + "/bd"
DEV = "TEST-DEVICE-AAAA"
WXA = "wxid_test_a"
WXB = "wxid_test_b"

FAILS = []


def call(path, payload, raw=None):
    body = raw if raw is not None else json.dumps(payload).encode()
    req = urllib.request.Request(BASE + path, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"code": e.code, "msg": "http %d" % e.code}


def expect(name, cond, detail=""):
    tag = "PASS" if cond else "FAIL"
    print(f"[{tag}] {name} {detail}")
    if not cond:
        FAILS.append(name)


# 1. activate：无效卡密
r = call("/activate", {"license": "ZZZZ-ZZZZ-ZZZZ-ZZZZ", "device_id": DEV,
                       "wxid": WXA, "sys": "iOS 18.1", "model": "iPhone15,2"})
expect("无效卡密 1001", r["code"] == 1001, r)

# 2. 卡号来源——命令行第 2 参数（线上模式）优先，否则取本地 bd.db 第一张 unused 卡
import sqlite3
dbf = os.environ.get("BD_DB", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bd.db"))
card = sys.argv[2] if len(sys.argv) > 2 else None
local = card is None
if local:
    conn = sqlite3.connect(dbf) if os.path.exists(dbf) else None
    if conn:
        row = conn.execute("SELECT license FROM licenses WHERE state='unused' LIMIT 1").fetchone()
        conn.close()
        if not row:
            print("!! bd.db 没有 unused 卡，先跑 python manage.py gencards 3 <包名>")
            sys.exit(1)
        card = row[0]
    else:
        print("!! 无本地 bd.db 也未传卡号：python test_api.py https://... 卡号")
        sys.exit(1)

# 3. 激活成功 → 返回包名
r = call("/activate", {"license": card, "device_id": DEV,
                       "wxid": WXA, "sys": "iOS 18.1", "model": "iPhone15,2"})
expect("激活成功返回包名", r["code"] == 0 and r["data"].get("pack_name"), r)
pack_name = r["data"].get("pack_name", "")

# 4. 同号重复激活 = 幂等成功
r = call("/activate", {"license": card, "device_id": DEV,
                       "wxid": WXA, "sys": "iOS 18.1", "model": "iPhone15,2"})
expect("同号重复激活幂等", r["code"] == 0, r)

# 5. 换号激活 → 1005（一次绑定不可换绑）
r = call("/activate", {"license": card, "device_id": DEV,
                       "wxid": WXB, "sys": "iOS 18.1", "model": "iPhone15,2"})
expect("换号激活 1005", r["code"] == 1005, r)

# 6. packs：owned 包带 key，未拥有包无 key
r = call("/packs", {"device_id": DEV, "wxid": WXA})
expect("packs 列表", r["code"] == 0 and isinstance(r["data"].get("packs"), list), r)
mine = next((p for p in r["data"]["packs"] if p["name"] == pack_name), None)
expect("owned 包带 key", mine and mine["owned"] is True and mine["key"], mine)
others = [p for p in r["data"]["packs"] if p["name"] != pack_name]
expect("未拥有包无 key", all(p["owned"] is False and p["key"] is None for p in others),
       f"{len(others)} 个橱窗包")

# 7. 换号报到：清单里没有该包
r = call("/packs", {"device_id": DEV, "wxid": WXB})
other = next((p for p in r["data"]["packs"] if p["name"] == pack_name), None)
expect("换号报到无授权", other and other["owned"] is False and other["key"] is None, other)

# 8. 封卡后失效（仅本地模式；线上模式由 manage.py revoke 执行）
if local:
    conn = sqlite3.connect(dbf)
    conn.execute("UPDATE licenses SET state='revoked' WHERE license=?", (card,))
    conn.commit()
    conn.close()
    r = call("/packs", {"device_id": DEV, "wxid": WXA})
    gone = next((p for p in r["data"]["packs"] if p["name"] == pack_name), None)
    expect("封卡后 owned=false", gone and gone["owned"] is False and gone["key"] is None, gone)
else:
    print("[SKIP] 封卡（线上模式无此 API，由 manage.py revoke 执行）")

print()
if FAILS:
    print(f"== {len(FAILS)} 项失败: {FAILS}")
    sys.exit(1)
print("== 全部通过")
