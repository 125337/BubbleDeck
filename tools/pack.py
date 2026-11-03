#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pack.py — 气泡包目录 → .bdpack 加密容器（PC 侧打包工具，V3 BDP2 格式）

容器格式（与客户端 Engine/TDContainer.m 对应）：
  [0..3]  "BDP2" 魔数
  [4]     容器版本 = 2
  [5..16] 随机 IV（GCM nonce，12B）
  [17..]  AES-256-GCM(内含标准 zip) + tag(16B，密文体末尾)
  AAD     = "bdpack2|<包名>|<版本>"   ← 绑定包名与版本，防拼接/跨包挪用
密钥：32 字节随机（每包每版本一把），输出 base64，登记到服务器 keys 表

用法：
  python pack.py <气泡包目录> [-o out.bdpack] [-k <base64 32B 密钥>]
  python pack.py --all <气泡包根目录>            # 批量重打包整个 packs/（存量迁移）
  例：python pack.py "ThemeDeck/packs/蜜糖邦尼气泡包" -o dist/蜜糖邦尼气泡包.bdpack
  包名/版本取自 info.json 的 name/version 字段（缺省回落目录名 / "1.0"）
"""

import sys
import os
import io
import json
import base64
import zipfile
import hashlib
import secrets
import argparse

MAGIC = b"BDP2"
VERSION = 2

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    sys.exit("[X] 缺少 cryptography：pip install cryptography")


def build_bdpack(pack_dir: str, key32: bytes, name: str, version: str) -> bytes:
    # 内层：标准 zip（客户端解密后在内存建索引，按条目 inflate，不再落盘）
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(pack_dir):
            for f in sorted(files):
                full = os.path.join(root, f)
                rel = os.path.relpath(full, pack_dir).replace("\\", "/")
                zf.write(full, rel)
    zip_data = buf.getvalue()

    iv = secrets.token_bytes(12)
    aad = f"bdpack2|{name}|{version}".encode("utf-8")
    ct = AESGCM(key32).encrypt(iv, zip_data, aad)      # 返回 密文||tag(16B)
    return MAGIC + bytes([VERSION]) + iv + ct


def read_name_version(pack_dir: str):
    name = os.path.basename(pack_dir.rstrip("/\\"))
    version = "1.0"
    try:
        with open(os.path.join(pack_dir, "info.json"), encoding="utf-8") as f:
            info = json.load(f)
        if isinstance(info.get("name"), str) and info["name"]:
            name = info["name"]
        if isinstance(info.get("version"), str) and info["version"]:
            version = info["version"]
    except Exception:
        pass
    return name, version


def gen_key() -> str:
    return base64.b64encode(secrets.token_bytes(32)).decode("ascii")


def build_one(pack_dir: str, out: str, key_b64: str):
    name, version = read_name_version(pack_dir)
    blob = build_bdpack(pack_dir, base64.b64decode(key_b64), name, version)
    with open(out, "wb") as f:
        f.write(blob)

    md5 = hashlib.md5(blob).hexdigest()
    print(f"== 打包完成: {out}")
    print(f"   name    = {name}")
    print(f"   version = {version}")
    print(f"   size    = {len(blob)}")
    print(f"   md5     = {md5}")
    print(f"   key     = {key_b64}")
    print(f"== 登记命令（服务器执行）:")
    print(f'   python manage.py addpack "{name}" "{version}" "<GitHub Releases 直链>" '
          f'"{key_b64}" "{md5}" {len(blob)}')
    return name, version, md5, key_b64, len(blob)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", help="气泡包目录；--all 时传 packs 根目录")
    ap.add_argument("--all", action="store_true", help="批量：遍历根目录下每个含 info.json 的子目录")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("-k", "--key", default=None, help="base64 编码的 32B 密钥，缺省自动生成")
    a = ap.parse_args()

    if a.all:
        root = a.path
        if not os.path.isdir(root):
            sys.exit(f"[X] 目录不存在: {root}")
        rows = []
        for sub in sorted(os.listdir(root)):
            d = os.path.join(root, sub)
            if not os.path.isdir(d) or not os.path.isfile(os.path.join(d, "info.json")):
                continue
            out = os.path.join("dist", sub + ".bdpack")
            os.makedirs("dist", exist_ok=True)
            name, version, md5, key, size = build_one(d, out, gen_key())
            rows.append((name, version, md5, key, size))
            print()
        print(f"== 批量完成 {len(rows)} 个包，逐个执行上面的 addpack 命令登记")
        return

    pack_dir = a.path
    if not os.path.isdir(pack_dir):
        sys.exit(f"[X] 目录不存在: {pack_dir}")
    if not os.path.isfile(os.path.join(pack_dir, "info.json")):
        sys.exit("[X] 目录里没有 info.json（不是合法气泡包）")

    key = a.key or gen_key()
    try:
        if len(base64.b64decode(key)) != 32:
            raise ValueError
    except Exception:
        sys.exit("[X] 密钥必须是 base64 编码的 32 字节（AES-256）")

    out = a.out or os.path.splitext(os.path.basename(pack_dir.rstrip("/\\")))[0] + ".bdpack"
    build_one(pack_dir, out, key)


if __name__ == "__main__":
    main()
