# -*- coding: utf-8 -*-
"""pylib/Crypto/Hash/MD5.py —— MD5 垫片（hashlib 实现）"""

from ._base import HashBase

digest_size = 16
block_size = 64
oid = "1.2.840.113549.2.5"


def new(data=None):
    return HashBase(new, 'md5', data, digest_size, block_size, oid)


class MD5Hash(HashBase):
    def __init__(self, data=None):
        HashBase.__init__(self, new, 'md5', data,
                          digest_size, block_size, oid)
