# -*- coding: utf-8 -*-
"""pylib/Crypto/Random/__init__.py —— 随机数垫片（底层就是 os.urandom）"""

import os


def get_random_bytes(N):
    """返回 N 个密码学安全随机字节（与 pycryptodome 同名同语义）。"""
    if N < 0:
        raise ValueError("N must be non-negative")
    return os.urandom(N)


def randomize():
    """pycryptodome 里用于重播随机源的钩子；os.urandom 自带熵池，这里空实现。"""
    return None
