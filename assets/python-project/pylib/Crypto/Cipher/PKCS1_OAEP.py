# -*- coding: utf-8 -*-
"""
pylib/Crypto/Cipher/PKCS1_OAEP.py —— RSA-OAEP 加解密垫片
---------------------------------------------------------
源脚本用法：

    from Crypto.Cipher import PKCS1_OAEP
    cipher = PKCS1_OAEP.new(key)                 # 默认摘要 SHA-1
    cipher = PKCS1_OAEP.new(key, hashAlgo=SHA256)
    pt = cipher.decrypt(ct)                      # 失败抛 ValueError
    pt = cipher.decrypt(ct, sentinel)            # 失败返回 sentinel

MGF 固定用 MGF1（与 hashAlgo 同摘要），这也是 pycryptodome 的默认行为。
"""

import os

from ..Hash import SHA1

_RAISE = object()


def _mgf1(seed, length, hash_new):
    """MGF1 掩码生成（RFC 8017 B.2.1）。"""
    out = b''
    counter = 0
    while len(out) < length:
        out += hash_new(seed + counter.to_bytes(4, 'big')).digest()
        counter += 1
    return out[:length]


def _xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


class OAEPCipher(object):
    def __init__(self, key, hash_mod, label):
        self._key = key
        self._hash = hash_mod
        self._label = label

    def can_encrypt(self):
        return True

    def _lhash(self):
        return self._hash.new(self._label).digest()

    def encrypt(self, message):
        message = bytes(message)
        k = self._key.size_in_bytes()
        h_len = self._hash.digest_size
        if len(message) > k - 2 * h_len - 2:
            raise ValueError(
                "Plaintext is too long (max %d bytes)" % (k - 2 * h_len - 2))

        l_hash = self._lhash()
        ps = b'\x00' * (k - len(message) - 2 * h_len - 2)
        db = l_hash + ps + b'\x01' + message
        seed = os.urandom(h_len)

        db_mask = _mgf1(seed, k - h_len - 1, self._hash.new)
        masked_db = _xor(db, db_mask)
        seed_mask = _mgf1(masked_db, h_len, self._hash.new)
        masked_seed = _xor(seed, seed_mask)

        em = b'\x00' + masked_seed + masked_db
        return self._key._encrypt(em)

    def decrypt(self, ciphertext, sentinel=_RAISE):
        """解密；不给 sentinel 时失败抛 ValueError（对齐新版 pycryptodome）。"""
        try:
            return self._decrypt(ciphertext)
        except Exception:                        # noqa: BLE001
            if sentinel is _RAISE:
                raise ValueError("Incorrect decryption.")
            return sentinel

    def _decrypt(self, ciphertext):
        ciphertext = bytes(ciphertext)
        k = self._key.size_in_bytes()
        h_len = self._hash.digest_size
        if len(ciphertext) != k:
            raise ValueError("Ciphertext with incorrect length.")
        if k < 2 * h_len + 2:
            raise ValueError("Decryption error")

        em = self._key._decrypt(ciphertext)
        if em[0] != 0x00:
            raise ValueError("Decryption error")

        masked_seed = em[1:1 + h_len]
        masked_db = em[1 + h_len:]

        seed_mask = _mgf1(masked_db, h_len, self._hash.new)
        seed = _xor(masked_seed, seed_mask)
        db_mask = _mgf1(seed, k - h_len - 1, self._hash.new)
        db = _xor(masked_db, db_mask)

        if db[:h_len] != self._lhash():
            raise ValueError("Decryption error")
        idx = db.find(b'\x01', h_len)               # 跳过 lHash + 0x00 填充
        if idx < 0:
            raise ValueError("Decryption error")
        return db[idx + 1:]


def new(key, hashAlgo=None, mgf=None, label=None):
    if mgf is not None:
        raise NotImplementedError(
            "纯 Python 垫片暂不支持自定义 MGF（默认 MGF1 + 同摘要已覆盖常见用法）")
    hash_mod = hashAlgo if hashAlgo is not None else SHA1
    if label is None:
        label = b''
    elif isinstance(label, str):
        label = label.encode()
    return OAEPCipher(key, hash_mod, label)
