# -*- coding: utf-8 -*-
"""
pylib/Crypto —— pycryptodome 的纯 Python 垫片
==============================================
iOS 上真 pycryptodome 是 C 扩展，交叉编译不了（与 lxml 同一个坑），
但视频/书源里真正用到的只是少数几个符号。这里按需复刻：

    Crypto.Cipher.AES            纯 Python AES（ECB/CBC/CFB/OFB/CTR）
    Crypto.Cipher.PKCS1_v1_5     RSA PKCS#1 v1.5 加解密
    Crypto.Cipher.PKCS1_OAEP     RSA-OAEP 加解密
    Crypto.PublicKey.RSA         PEM/DER 导入、construct、(n,e,d) 原始解密
    Crypto.Util.Padding          pad/unpad（pkcs7/iso7816/x923）
    Crypto.Util.number           long_to_bytes / bytes_to_long / inverse
    Crypto.Hash.*                MD5/SHA1/SHA256/SHA512（hashlib 实现）
    Crypto.Random                get_random_bytes

未覆盖的（遇到再补）：GCM/CCM 等 AEAD 模式、带口令的加密私钥、RSA 签名验签、
DES/3DES 等其它算法。刻意不预铺没人用的 API，避免"看着有、其实算错"。
"""

__version__ = '3.21.0'
