# -*- coding: utf-8 -*-
"""pylib/Crypto/Hash/SHA256.py —— SHA-256 垫片（hashlib 实现）"""

from ._base import HashBase

digest_size = 32
block_size = 64
oid = "2.16.840.1.101.3.4.2.1"


def new(data=None):
    return HashBase(new, 'sha256', data, digest_size, block_size, oid)


class SHA256Hash(HashBase):
    """兼容 `SHA256.SHA256Hash` 的类型引用。"""

    def __init__(self, data=None):
        HashBase.__init__(self, new, 'sha256', data,
                          digest_size, block_size, oid)
