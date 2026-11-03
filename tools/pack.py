#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pack.py — 气泡包目录 → .bdpack 加密容器（PC 侧打包工具）

容器格式：BDPK 魔数(4) + 版本(1) + 随机IV(16) + AES-256-CBC(内含标准zip, PKCS7)
密钥：32 字符随机串（-k 传入 或 自动生成），登记到服务器 manage.py addpack
产出：<out> .bdpack 文件，并打印 key / md5 / size

用法：
  python pack.py <气泡包目录> [-o out.bdpack] [-k 密钥]
  例：python pack.py "ThemeDeck/packs/蜜糖邦尼气泡包" -o dist/蜜糖邦尼气泡包.bdpack
"""

import sys
import os
import io
import zipfile
import hashlib
import secrets
import argparse

MAGIC = b"BDPK"
VERSION = 1

try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives import padding
except ImportError:
    sys.exit("[X] 缺少 cryptography：pip install cryptography")


def encrypt_aes(data: bytes, key32: bytes, iv16: bytes) -> bytes:
    padder = padding.PKCS7(128).padder()
    padded = padder.update(data) + padder.finalize()
    enc = Cipher(algorithms.AES(key32), modes.CBC(iv16)).encryptor()
    return enc.update(padded) + enc.finalize()


def build_bdpack(pack_dir: str, key: str) -> bytes:
    # 内层：标准 zip（客户端解密后交给 SSZipArchive 普通解压）
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(pack_dir):
            for f in sorted(files):
                full = os.path.join(root, f)
                rel = os.path.relpath(full, pack_dir).replace("\\", "/")
                zf.write(full, rel)
    zip_data = buf.getvalue()
    iv = secrets.token_bytes(16)
    ct = encrypt_aes(zip_data, key.encode("utf-8"), iv)
    return MAGIC + bytes([VERSION]) + iv + ct


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pack_dir")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("-k", "--key", default=None, help="32字符密钥，缺省自动生成")
    a = ap.parse_args()

    if not os.path.isdir(a.pack_dir):
        sys.exit(f"[X] 目录不存在: {a.pack_dir}")
    if not os.path.isfile(os.path.join(a.pack_dir, "info.json")):
        sys.exit("[X] 目录里没有 info.json（不是合法气泡包）")

    key = a.key or "".join(secrets.choice("ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")
                           for _ in range(32))
    if len(key) != 32:
        sys.exit("[X] 密钥必须是 32 字符（AES-256）")

    blob = build_bdpack(a.pack_dir, key)
    out = a.out or os.path.splitext(os.path.basename(a.pack_dir.rstrip("/\\")))[0] + ".bdpack"
    with open(out, "wb") as f:
        f.write(blob)

    md5 = hashlib.md5(blob).hexdigest()
    name = os.path.basename(a.pack_dir.rstrip("/\\"))
    print(f"== 打包完成: {out}")
    print(f"   name  = {name}")
    print(f"   size  = {len(blob)}")
    print(f"   md5   = {md5}")
    print(f"   key   = {key}")
    print(f"== 登记命令（服务器执行）:")
    print(f'   python manage.py addpack "{name}" 1.0 "<GitHub Releases 直链>" "{key}" "{md5}" {len(blob)}')


if __name__ == "__main__":
    main()
