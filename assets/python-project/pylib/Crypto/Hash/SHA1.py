# -*- coding: utf-8 -*-
"""pylib/Crypto/Hash/SHA1.py —— SHA-1 垫片（hashlib 实现，同时是 OAEP 默认摘要）"""

from ._base import HashBase

digest_size = 20
block_size = 64
oid = "1.3.14.3.2.26"


def new(data=None):
    return HashBase(new, 'sha1', data, digest_size, block_size, oid)


class SHA1Hash(HashBase):
    def __init__(self, data=None):
        HashBase.__init__(self, new, 'sha1', data,
                          digest_size, block_size, oid)
