# -*- coding: utf-8 -*-
"""
pylib/Crypto/Util/number.py —— 大整数 <-> 字节串 工具垫片
-----------------------------------------------------------
RSA 源脚本里几乎必然出现这两个函数（把密文/明文和模幂结果互转）：

    from Crypto.Util.number import long_to_bytes, bytes_to_long
    pt = long_to_bytes(pow(bytes_to_long(ct), d, n))
"""

import os


def long_to_bytes(n, blocksize=0):
    """整数按大端转字节串；blocksize>0 时左侧补零到其整数倍。"""
    if n < 0:
        raise ValueError("This function does not accept negative inputs")
    s = b""
    while n > 0:
        n, r = divmod(n, 0x100)
        s = bytes([r]) + s
    if not s:
        s = b"\x00"
    if blocksize > 0 and len(s) % blocksize:
        s = b"\x00" * (blocksize - len(s) % blocksize) + s
    return s


def bytes_to_long(s):
    """字节串按大端转整数。"""
    if isinstance(s, str):
        s = s.encode()
    return int.from_bytes(bytes(s), "big")


def inverse(u, v):
    """u 关于模 v 的乘法逆元；不存在时抛 ValueError。"""
    if v <= 0:
        raise ValueError("The modulus must be a positive integer")
    u3, v3 = u, v
    u1, v1 = 1, 0
    while v3 > 0:
        q = u3 // v3
        u1, v1 = v1, u1 - v1 * q
        u3, v3 = v3, u3 - v3 * q
    if u3 != 1:
        raise ValueError("No inverse value can be computed")
    return u1 % v


def getRandomInteger(N):
    """随机 N 位整数（RSA 里偶尔用来造随机数）。"""
    return bytes_to_long(os.urandom((N + 7) // 8)) >> ((-N) % 8)


def getPrime(N):
    """随机 N 位素数（垫片里按需实现，主要给 RSA.generate 用）。"""
    from ..PublicKey.RSA import _is_probable_prime
    if N < 2:
        raise ValueError("N must be at least 2")
    while True:
        candidate = getRandomInteger(N) | (1 << (N - 1)) | 1
        if _is_probable_prime(candidate):
            return candidate
