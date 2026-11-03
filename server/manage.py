#
# BubbleDeck 服务端管理脚本（跑在服务器/本地均可）
#   python manage.py init                     初始化建表
#   python manage.py gencards 10              生成 10 张卡密入库（打印卡号）
#   python manage.py addpack <名> <版本> <url> <key> <md5> [size]   登记一个包
#   python manage.py listpacks                查看包
#   python manage.py listlic                  查看卡密/绑定状态
#   python manage.py revoke <卡密>            停用卡密
#

import sys
import sqlite3
import secrets

sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
import app as appmod


def gencards(n: int):
    alpha = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"           # 去掉易混字符
    cards = []
    with appmod.db() as c:
        for _ in range(n):
            raw = "".join(secrets.choice(alpha) for _ in range(16))
            card = "-".join(raw[i:i + 4] for i in range(0, 16, 4))
            c.execute("INSERT INTO licenses(license, state) VALUES(?, 'unused')", (card,))
            cards.append(card)
    print("\n".join(cards))


def addpack(name, version, url, key, md5, size=0):
    with appmod.db() as c:
        c.execute("""INSERT INTO packs(name, version, size, md5, url, packkey)
                     VALUES(?,?,?,?,?,?)
                     ON CONFLICT(name) DO UPDATE SET version=?, size=?, md5=?, url=?, packkey=?""",
                  (name, version, size, md5, url, key, version, size, md5, url, key))
    print(f"OK {name} v{version} md5={md5}")


def listpacks():
    with appmod.db() as c:
        for r in c.execute("SELECT name,version,size,md5,url,state FROM packs ORDER BY name"):
            print(f"{r['name']}\tv{r['version']}\t{r['size']}B\t{r['state']}\t{r['md5']}\n  {r['url']}")


def listlic():
    with appmod.db() as c:
        for r in c.execute("""SELECT license,state,bind_device,bind_wxid,activated_at
                              FROM licenses ORDER BY license"""):
            print(f"{r['license']}\t{r['state']}\t{r['bind_device'] or '-'}\t{r['bind_wxid'] or '-'}")


def revoke(license_key):
    with appmod.db() as c:
        n = c.execute("UPDATE licenses SET state='revoked', token=NULL, token_exp=NULL "
                      "WHERE license=?", (license_key,)).rowcount
    print("revoked" if n else "not found")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "init":
        appmod.init_db()
        print("db ready:", appmod.DB_PATH)
    elif cmd == "gencards":
        gencards(int(sys.argv[2]))
    elif cmd == "addpack":
        addpack(*sys.argv[2:7], size=int(sys.argv[7]) if len(sys.argv) > 7 else 0)
    elif cmd == "listpacks":
        listpacks()
    elif cmd == "listlic":
        listlic()
    elif cmd == "revoke":
        revoke(sys.argv[2])
    else:
        print(__doc__)
