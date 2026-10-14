# -*- coding: utf-8 -*-
"""
pylib/Crypto/Cipher/PKCS1_v1_5.py —— RSA PKCS#1 v1.5 加解密垫片
-----------------------------------------------------------------
源脚本里的典型用法（解密接口下发的密文）：

    from Crypto.Cipher import PKCS1_v1_5
    cipher = PKCS1_v1_5.new(key)            # key 来自 RSA.import_key / construct
    pt = cipher.decrypt(ct, sentinel)       # 解密失败返回 sentinel，不抛异常

注：只实现加解密；签名/验签（new(key, hash_obj) 那条路径）本垫片不支持，
显式传入 hash_obj 会给出明确报错，避免静默算错。
"""

import os


class PKCS115_Cipher(object):
    def __init__(self, key):
        self._key = key

    def can_encrypt(self):
        return True

    def can_decrypt(self):
        return self._key.has_private()

    def encrypt(self, message):
        """EM = 0x00 || 0x02 || PS(非零随机, ≥8 字节) || 0x00 || M"""
        message = bytes(message)
        k = self._key.size_in_bytes()
        ps_len = k - len(message) - 3
        if ps_len < 8:
            raise ValueError(
                "Plaintext is too long (%d bytes, max %d bytes allowed)"
                % (len(message), k - 11))

        ps = bytearray()
        while len(ps) < ps_len:                  # 随机字节里剔掉 0x00
            ps += bytes(b for b in os.urandom(ps_len - len(ps) + 16) if b != 0)
        em = b'\x00\x02' + bytes(ps[:ps_len]) + b'\x00' + message
        return self._key._encrypt(em)

    def decrypt(self, ciphertext, sentinel, expected_pt_len=0):
        """返回明文；填充非法/长度不符时返回 [sentinel]（与 pycryptodome 一致）。"""
        ciphertext = bytes(ciphertext)
        k = self._key.size_in_bytes()
        if len(ciphertext) != k:
            return sentinel
        try:
            em = self._key._decrypt(ciphertext)
        except Exception:                        # noqa: BLE001 - 统一回 sentinel
            return sentinel

        if em[0] != 0x00 or em[1] != 0x02:
            return sentinel
        # PS 至少 8 字节 ⇒ 分隔符 0x00 的下标至少是 10
        idx = em.find(b'\x00', 2)
        if idx < 10:
            return sentinel

        message = em[idx + 1:]
        if expected_pt_len and len(message) != expected_pt_len:
            return sentinel
        return message


def new(key, hash_obj=None):
    """构造 cipher。带 hash_obj 的签名模式本垫片不支持。"""
    if hash_obj is not None:
        raise NotImplementedError(
            "纯 Python 垫片暂不支持 PKCS#1 v1.5 签名/验签（sign/verify）")
    return PKCS115_Cipher(key)
