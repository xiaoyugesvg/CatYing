# -*- coding: utf-8 -*-
"""pylib/Crypto/Cipher/DES3.py —— 纯 Python **3DES（EDE）** 垫片。

    from Crypto.Cipher import DES3
    cipher = DES3.new(key, DES3.MODE_CBC, iv)   # key 必须 16 或 24 字节

key 规则（与 pycryptodome 一致）：
    · 16 字节 → K1||K2，**K3 = K1**（两个密钥的 3DES，即 EDE 退化成 E-D-E）
    · 24 字节 → K1||K2||K3
    · 其它长度 → ValueError('Not a valid TDES key')（与官方文案一致）

加解密 = **EDE**：`E_K3(D_K2(E_K1(x)))` / `D_K1(E_K2(D_K3(x)))`。
模式与 DES 共用 `_des_modes`（ECB / CBC / CFB / OFB；CTR 等未实现会明确报错）。
"""

from . import _des_modes
from .DES import _DesCipher

MODE_ECB = _des_modes.MODE_ECB
MODE_CBC = _des_modes.MODE_CBC
MODE_CFB = _des_modes.MODE_CFB
MODE_OFB = _des_modes.MODE_OFB
MODE_CTR = _des_modes.MODE_CTR
MODE_OPENPGP = _des_modes.MODE_OPENPGP
MODE_EAX = _des_modes.MODE_EAX

block_size = 8
key_size = (16, 24)


def adjust_key_parity(key_in):
    """把 key 每个字节调成**奇校验**（最低位是校验位）—— 与 pycryptodome 一致。

    ⚠️ DES 本身**不使用**校验位（PC1 会把它丢掉），这个函数只是给调用方用的
    工具函数；有源脚本会先调它再造 cipher。
    """
    out = bytearray()
    for b in bytearray(key_in):
        parity = 1
        for i in range(1, 8):
            parity ^= (b >> i) & 1
        out.append((b & 0xFE) | parity)
    return bytes(out)


class _Des3Cipher(object):
    """3DES 本体：三个 DES 实例 + EDE 组合。"""

    def __init__(self, key):
        n = len(key)
        if n == 16:
            k1, k2, k3 = key[:8], key[8:16], key[:8]
        elif n == 24:
            k1, k2, k3 = key[0:8], key[8:16], key[16:24]
        else:
            raise ValueError("Not a valid TDES key")
        # 只造三个实例（K3 与 K1 相同时共用同一个对象）
        self._c1 = _DesCipher(k1)
        self._c2 = _DesCipher(k2)
        self._c3 = self._c1 if k3 == k1 else _DesCipher(k3)

    def encrypt_block(self, block):
        # E_K3 ∘ D_K2 ∘ E_K1
        return self._c3.encrypt_block(
            self._c2.decrypt_block(self._c1.encrypt_block(block)))

    def decrypt_block(self, block):
        # D_K1 ∘ E_K2 ∘ D_K3
        return self._c1.decrypt_block(
            self._c2.encrypt_block(self._c3.decrypt_block(block)))


def new(key, mode, *args, **kwargs):
    key = bytes(key)
    cipher = _Des3Cipher(key)
    return _des_modes.build_mode(
        mode, cipher.encrypt_block, cipher.decrypt_block, args, kwargs)
