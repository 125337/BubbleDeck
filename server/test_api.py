#
# S1 自测脚本：对本地起的服务打满 4 接口 + 错误码全路径
# 前置：uvicorn app:app --port 8000（BD_SALT=bd-dev-salt）且 manage.py 造过数据
# 用法：python test_api.py http://127.0.0.1:8000
#

import sys
import os
import time
import json
import hmac
import hashlib
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000") + "/bd"
SALT = os.environ.get("BD_SALT", "bd-dev-salt")          # 打线上时用 BD_SALT 环境变量传生产盐
DEV_A = "TEST-DEVICE-AAAA"
DEV_B = "TEST-DEVICE-BBBB"

FAILS = []


def call(path, payload, ts=None, sign=None, raw=None):
    body = raw if raw is not None else json.dumps(payload).encode()
    ts = ts or str(int(time.time() * 1000))
    sign = sign if sign is not None else \
        hmac.new(SALT.encode(), f"{ts}|".encode() + body, hashlib.sha256).hexdigest()
    req = urllib.request.Request(BASE + path, data=body, method="POST",
                                 headers={"X-BD-Ts": ts, "X-BD-Sign": sign,
                                          "Content-Type": "application/json"})
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


# 1. 签名错误路径
r = call("/verify", {}, sign="deadbeef")
expect("错签名拒绝", r["code"] == 4003, r)
r = call("/verify", {}, ts="1000")
expect("过期时间戳拒绝", r["code"] == 4002, r)

# 2. activate：无效卡密
r = call("/activate", {"license": "ZZZZ-ZZZZ-ZZZZ-ZZZZ", "device_id": DEV_A,
                       "wxid": "wxid_test", "sys": "iOS 18.1", "model": "iPhone15,2"})
expect("无效卡密 1001", r["code"] == 1001, r)

# 3. activate：卡号来源——命令行第 2 参数（线上模式）优先，否则取本地 bd.db 第一张 unused 卡
import sqlite3, os
dbf = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bd.db")
card = sys.argv[2] if len(sys.argv) > 2 else None
if card:
    conn = None                                           # 线上模式：无本地库，revoke 步骤跳过
else:
    conn = sqlite3.connect(dbf) if os.path.exists(dbf) else None
    if conn:
        row = conn.execute("SELECT license FROM licenses WHERE state='unused' LIMIT 1").fetchone()
        conn.close()
        if not row:
            print("!! bd.db 没有 unused 卡，先跑 python manage.py gencards 3")
            sys.exit(1)
        card = row[0]
    else:
        print("!! 无本地 bd.db 也未传卡号：python test_api.py https://... 卡号")
        sys.exit(1)

r = call("/activate", {"license": card, "device_id": DEV_A,
                       "wxid": "wxid_test", "sys": "iOS 18.1", "model": "iPhone15,2"})
expect("激活成功", r["code"] == 0 and r["data"].get("token"), r)
token = r["data"]["token"]

# 4. 同设备重复激活 = 续发新 token（旧 token 作废，客户端只存最新）
r = call("/activate", {"license": card, "device_id": DEV_A,
                       "wxid": "wxid_test", "sys": "iOS 18.1", "model": "iPhone15,2"})
expect("同设备重激活", r["code"] == 0 and r["data"].get("token"), r)
token = r["data"]["token"]                               # 后续全部用最新 token
r = call("/verify", {"token": "stale" + "x" * 41, "device_id": DEV_A})
expect("旧 token 作废 2001", r["code"] == 2001, r)

# 5. 换设备激活 → 1003
r = call("/activate", {"license": card, "device_id": DEV_B,
                       "wxid": "wxid_test", "sys": "iOS 18.1", "model": "iPhone15,2"})
expect("换设备 1003", r["code"] == 1003, r)

# 6. verify 正常 / 坏 token
r = call("/verify", {"token": token, "device_id": DEV_A})
expect("verify 通过", r["code"] == 0 and r["data"]["active"] is True, r)
r = call("/verify", {"token": "bad" * 12, "device_id": DEV_A})
expect("坏 token 2001", r["code"] == 2001, r)

# 7. packs（无 key 字段泄漏）
r = call("/packs", {"token": token, "device_id": DEV_A})
expect("packs 列表", r["code"] == 0 and isinstance(r["data"].get("packs"), list), r)
if r["code"] == 0 and r["data"]["packs"]:
    leak = any("key" in p or "packkey" in p for p in r["data"]["packs"])
    expect("packs 不泄漏 key", not leak, r["data"]["packs"][0])

# 8. download（取 key）
r = call("/download", {"token": token, "device_id": DEV_A, "name": "BDK_TEST_BUBBLE"})
if r["code"] == 0:
    expect("download 返回 url/md5/key", all(r["data"].get(k) for k in ("url", "md5", "key")), r)
else:
    expect("download 3001", r["code"] == 3001, r)

# 9. revoke 后全链路失效（仅本地模式；线上模式无 revoke API，跳过）
if conn:
    conn = sqlite3.connect(dbf)
    conn.execute("UPDATE licenses SET state='revoked' WHERE license=?", (card,))
    conn.commit()
    conn.close()
    r = call("/verify", {"token": token, "device_id": DEV_A})
    expect("revoked 后 verify 拒绝", r["code"] == 2001, r)
else:
    print("[SKIP] revoke（线上模式无此 API，由 manage.py 执行）")

print()
if FAILS:
    print(f"== {len(FAILS)} 项失败: {FAILS}")
    sys.exit(1)
print("== 全部通过")
