# -*- coding: utf-8 -*-
"""
pylib/Crypto/Hash/_base.py —— 哈希模块公共外壳
------------------------------------------------
Crypto.Hash.* 各子模块都返回这个对象，API 对齐 pycryptodome：
new(data=None) / update / digest / hexdigest / copy / digest_size / block_size / oid
底层就是标准库 hashlib（纯 C 内置于 CPython，无需第三方扩展）。
"""

import hashlib


class HashBase(object):
    def __init__(self, factory, algo, data=None,
                 digest_size=None, block_size=None, oid=None):
        self._factory = factory
        self._algo = algo
        self.digest_size = digest_size
        self.block_size = block_size
        self.oid = oid
        self._h = hashlib.new(algo)
        if data is not None:
            self.update(data)

    def update(self, data):
        self._h.update(data if isinstance(data, bytes) else data.encode())
        return self

    def digest(self):
        return self._h.digest()

    def hexdigest(self):
        return self._h.hexdigest()

    def copy(self):
        o = HashBase(self._factory, self._algo, None,
                     self.digest_size, self.block_size, self.oid)
        o._h = self._h.copy()
        return o

    def new(self, data=None):
        return self._factory(data)
