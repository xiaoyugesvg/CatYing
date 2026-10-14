# -*- coding: utf-8 -*-
"""pylib/Crypto/Cipher/DES.py —— 纯 Python **DES** 垫片（FIPS 46-3）。

真 pycryptodome 的 `Crypto.*` 是 C 扩展，iOS 上交叉编译不了（与 lxml 同一个坑），
这里用纯 Python 复刻源脚本里的常见用法，并对齐官方 API：

    from Crypto.Cipher import DES
    cipher = DES.new(key, DES.MODE_CBC, iv)     # IV 支持位置参数与 iv=/IV= 关键字
    ct = cipher.encrypt(pad(data, 8))
    pt = unpad(cipher.decrypt(ct), 8)

已实现 MODE_ECB / CBC / CFB / OFB；CTR / EAX / OPENPGP **未实现**（会明确报错，
不预铺"看着有、其实算错"的 API）。

性能：纯 Python **位级**实现，每 8 字节约 0.3~0.8ms —— 解密钥串 / 签名 / 一小段
密文（源脚本的实际用法）无感；解 MB 级数据会明显慢（那种用法不会出现在源里）。

表来自 `_des_tables.py`（脚本从权威实现提取 + 逐表校验后生成）；
DES/DES3 的正确性由与真 pycryptodome 的**双向对拍**保证（见 scratch 下的验证脚本）。
"""

from . import _des_modes
from ._des_tables import E, FP, IP, LEFT_ROTATIONS, P, PC1, PC2, SBOX

MODE_ECB = _des_modes.MODE_ECB
MODE_CBC = _des_modes.MODE_CBC
MODE_CFB = _des_modes.MODE_CFB
MODE_OFB = _des_modes.MODE_OFB
MODE_CTR = _des_modes.MODE_CTR
MODE_OPENPGP = _des_modes.MODE_OPENPGP
MODE_EAX = _des_modes.MODE_EAX

block_size = 8
key_size = 8


# ---- 位级工具 -------------------------------------------------------------

def _to_bits(data):
    """bytes → 位列表（**高位在前**，与 FIPS 46-3 的位编号一致）。"""
    bits = []
    for byte in bytearray(data):
        bits.extend(((byte >> 7) & 1, (byte >> 6) & 1, (byte >> 5) & 1,
                     (byte >> 4) & 1, (byte >> 3) & 1, (byte >> 2) & 1,
                     (byte >> 1) & 1, byte & 1))
    return bits


def _from_bits(bits):
    out = bytearray()
    for i in range(0, len(bits), 8):
        v = 0
        for b in bits[i:i + 8]:
            v = (v << 1) | b
        out.append(v)
    return bytes(out)


def _permute(bits, table):
    """按 [table]（**0-based 源下标**）重排位。"""
    return [bits[i] for i in table]


# ---- DES 本体 -------------------------------------------------------------

def _subkeys(key):
    """16 组 48 位子密钥：PC1 → 循环左移 → PC2。"""
    k = _permute(_to_bits(key), PC1)
    c, d = k[:28], k[28:]
    keys = []
    for rot in LEFT_ROTATIONS:
        c = c[rot:] + c[:rot]
        d = d[rot:] + d[:rot]
        keys.append(_permute(c + d, PC2))
    return keys


def _f(r, subkey):
    """轮函数：E 扩展 → 异或子密钥 → 8 个 S 盒 → P 置换。"""
    x = [a ^ b for a, b in zip(_permute(r, E), subkey)]
    s = []
    for i in range(8):
        b = x[i * 6:i * 6 + 6]
        # 行 = 首尾两位，列 = 中间四位
        row = (b[0] << 1) | b[5]
        col = (b[1] << 3) | (b[2] << 2) | (b[3] << 1) | b[4]
        v = SBOX[i][row * 16 + col]
        s.extend(((v >> 3) & 1, (v >> 2) & 1, (v >> 1) & 1, v & 1))
    return _permute(s, P)


def _crypt_block(block, keys):
    bits = _permute(_to_bits(block), IP)
    left, right = bits[:32], bits[32:]
    for k in keys:
        left, right = right, [a ^ b for a, b in zip(left, _f(right, k))]
    # ⚠️ 16 轮结束后**不再交换** L/R，直接拼 R||L 过 FP（教科书的标准收尾）
    return _from_bits(_permute(right + left, FP))


class _DesCipher(object):
    """DES 本体：只对上层暴露"块加解密"（模式层与 3DES 都复用它）。"""

    def __init__(self, key):
        if len(key) != 8:
            raise ValueError("Incorrect DES key length (%d bytes)" % len(key))
        self._enc_keys = _subkeys(key)
        # 解密 = 子密钥倒序
        self._dec_keys = list(reversed(self._enc_keys))

    def encrypt_block(self, block):
        return _crypt_block(block, self._enc_keys)

    def decrypt_block(self, block):
        return _crypt_block(block, self._dec_keys)


def new(key, mode, *args, **kwargs):
    key = bytes(key)
    cipher = _DesCipher(key)
    return _des_modes.build_mode(
        mode, cipher.encrypt_block, cipher.decrypt_block, args, kwargs)
