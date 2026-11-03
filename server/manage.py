#
# BubbleDeck 服务端管理脚本（V3，跑在服务器/本地均可）
#   python manage.py init                          初始化（建目录建表）
#   python manage.py gencards <数量> <包名>         生成卡密（按卡一文件，发卡必须带包名）
#   python manage.py addpack <名> <版本> <url> <key(base64)> <md5> [size] [ver]
#                                                  登记一个包（packs + keys 双表）
#   python manage.py listpacks                     查看包
#   python manage.py listlic                       查看卡密/绑定状态
#   python manage.py revoke <卡密>                 停用卡密
#

import sys
import os
import json
import sqlite3
import secrets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import app as appmod


def gencards(n: int, pack_name: str):
    alpha = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"           # 去掉易混字符
    cards = []
    for _ in range(n):
        raw = "".join(secrets.choice(alpha) for _ in range(16))
        card = "-".join(raw[i:i + 4] for i in range(0, 16, 4))
        appmod.save_card({"license": card, "pack_name": pack_name,
                          "state": "unused", "bind_wxid": None,
                          "devices": {}, "activated_at": None})
        cards.append(card)
    print("\n".join(cards))


def addpack(name, version, url, key, md5, size=0, ver=2):
    with appmod.db() as c:
        c.execute("""INSERT INTO packs(name, version, size, md5, url, packkey)
                     VALUES(?,?,?,?,?,?)
                     ON CONFLICT(name) DO UPDATE SET version=?, size=?, md5=?, url=?, packkey=?""",
                  (name, version, size, md5, url, key, version, size, md5, url, key))
        c.execute("""INSERT INTO keys(pack, version, packkey, ver) VALUES(?,?,?,?)
                     ON CONFLICT(pack, version) DO UPDATE SET packkey=?, ver=?""",
                  (name, version, key, ver, key, ver))
    print(f"OK {name} v{version} (容器 v{ver}) md5={md5}")


def listpacks():
    with appmod.db() as c:
        for r in c.execute("SELECT name,version,size,md5,url,state FROM packs ORDER BY name"):
            print(f"{r['name']}\tv{r['version']}\t{r['size']}B\t{r['state']}\t{r['md5']}\n  {r['url']}")


def listlic():
    for fn in sorted(os.listdir(appmod.CARDS_DIR)):
        if not fn.endswith(".json"):
            continue
        card = appmod.load_card(fn[:-5])
        if not card:
            continue
        print(f"{card['license']}\t{card.get('state', '-')}\t"
              f"{card.get('bind_wxid') or '-'}\t{card.get('pack_name', '-')}\t"
              f"{len(card.get('devices') or {})}台")


def revoke(license_key):
    card = appmod.load_card(license_key)
    if not card:
        print("not found")
        return
    card["state"] = "revoked"
    appmod.save_card(card)
    print("revoked")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "init":
        appmod.init_db()
        print("db ready:", appmod.DB_PATH, "| cards:", appmod.CARDS_DIR)
    elif cmd == "gencards":
        if len(sys.argv) < 4:
            sys.exit("用法: python manage.py gencards <数量> <包名>")
        gencards(int(sys.argv[2]), sys.argv[3])
    elif cmd == "addpack":
        if len(sys.argv) < 7:
            sys.exit("用法: python manage.py addpack <名> <版本> <url> <key> <md5> [size] [ver]")
        addpack(*sys.argv[2:7],
                size=int(sys.argv[7]) if len(sys.argv) > 7 else 0,
                ver=int(sys.argv[8]) if len(sys.argv) > 8 else 2)
    elif cmd == "listpacks":
        listpacks()
    elif cmd == "listlic":
        listlic()
    elif cmd == "revoke":
        revoke(sys.argv[2])
    else:
        print(__doc__)
