# -*- coding: utf-8 -*-
"""pylib/Crypto/Hash/SHA512.py —— SHA-512 垫片（hashlib 实现）"""

from ._base import HashBase

digest_size = 64
block_size = 128
oid = "2.16.840.1.101.3.4.2.3"


def new(data=None):
    return HashBase(new, 'sha512', data, digest_size, block_size, oid)


class SHA512Hash(HashBase):
    def __init__(self, data=None):
        HashBase.__init__(self, new, 'sha512', data,
                          digest_size, block_size, oid)
