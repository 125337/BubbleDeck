#
# BubbleDeck 会话模块（admin / biz 共用，V4 信任架构重构）
# 设计要点：
#   1) 双 secret：BD_ADMIN_SECRET / BD_BIZ_SECRET 环境变量，只存服务器端。
#      与客户端 dylib 彻底无关——插件被逆向也拿不到后台 cookie 的签名钥匙。
#   2) scope 混签：签名内容混入域标识（admin/biz），cookie 跨域无效。
#   3) 无状态自签 cookie，格式：{exp}.{payload}.{hmac}；到期/签名不符一律拒绝。
#      旧版（SALT 签名）cookie 换密钥后自然失效 → 重新登录一次即可。
#   4) biz 的 payload = 商家 id；停用/删号校验每次请求回库查（biz.py 负责）。
#

import os
import time
import hmac
import hashlib

# 未配置时回落开发默认值（生产部署必须设置强随机值，见部署清单）
ADMIN_SECRET = os.environ.get("BD_ADMIN_SECRET", "bd-admin-dev-secret")
BIZ_SECRET   = os.environ.get("BD_BIZ_SECRET", "bd-biz-dev-secret")

SESSION_HOURS = 12


def _sign(secret: str, scope: str, exp: int, payload: str) -> str:
    msg = f"{scope}|{exp}|{payload}".encode()
    return hmac.new(secret.encode(), msg, hashlib.sha256).hexdigest()


def make_token(secret: str, scope: str, payload: str) -> str:
    exp = int(time.time()) + SESSION_HOURS * 3600
    return f"{exp}.{payload}.{_sign(secret, scope, exp, payload)}"


def check_token(secret: str, scope: str, token: str):
    """校验通过返回 payload，否则 None（过期/签名不符/格式非法统一拒绝）"""
    exp, _, rest = (token or "").partition(".")
    payload, _, sig = rest.partition(".")
    if not exp.isdigit() or not payload or not sig:
        return None
    if int(exp) < time.time():
        return None
    if not hmac.compare_digest(_sign(secret, scope, int(exp), payload), sig):
        return None
    return payload


# ── admin（固定身份 root，只判断登录态）──

def admin_make() -> str:
    return make_token(ADMIN_SECRET, "admin", "root")


def admin_check(token: str) -> bool:
    return check_token(ADMIN_SECRET, "admin", token) == "root"


# ── biz（payload = 商家 id 数字串）──

def biz_make(mid: str) -> str:
    return make_token(BIZ_SECRET, "biz", str(mid))


def biz_check(token: str):
    p = check_token(BIZ_SECRET, "biz", token)
    return p if p and p.isdigit() else None
