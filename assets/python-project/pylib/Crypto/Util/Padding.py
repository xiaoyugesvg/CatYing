# -*- coding: utf-8 -*-
"""
pylib/Crypto/Util/Padding.py —— 填充垫片
------------------------------------------
对齐 pycryptodome 的 pad()/unpad()，支持 pkcs7（最常用）/ iso7816 / x923。
源脚本里的典型写法：

    from Crypto.Util.Padding import pad, unpad
    ct = cipher.encrypt(pad(data, AES.block_size))
    pt = unpad(cipher.decrypt(ct), AES.block_size)
"""


def _as_bytes(data):
    if isinstance(data, str):
        return data.encode()
    return bytes(data)


def pad(data_to_pad, block_size, style='pkcs7'):
    """按 [style] 填充到 [block_size] 的整数倍。"""
    data = _as_bytes(data_to_pad)
    if block_size <= 0 or block_size > 255:
        raise ValueError("block_size must be between 1 and 255")

    padding_len = block_size - len(data) % block_size
    if style == 'pkcs7':
        if padding_len == 0:
            padding_len = block_size
        return data + bytes([padding_len]) * padding_len
    if style == 'iso7816':
        # 0x80 + 若干 0x00，且总是至少补一块
        return data + b'\x80' + b'\x00' * (padding_len - 1)
    if style == 'x923':
        if padding_len == 0:
            padding_len = block_size
        return data + b'\x00' * (padding_len - 1) + bytes([padding_len])
    raise ValueError("Unknown padding style: %s" % style)


def unpad(padded_data, block_size, style='pkcs7'):
    """校验并去掉填充；填充非法时抛 ValueError（与 pycryptodome 一致）。"""
    data = _as_bytes(padded_data)
    if block_size <= 0 or block_size > 255:
        raise ValueError("block_size must be between 1 and 255")
    if len(data) == 0 or len(data) % block_size:
        raise ValueError("Length of padded data is not a multiple of %d"
                         % block_size)

    if style == 'pkcs7':
        padding_len = data[-1]
        if padding_len == 0 or padding_len > block_size:
            raise ValueError("Padding is incorrect.")
        if data[-padding_len:] != bytes([padding_len]) * padding_len:
            raise ValueError("Padding is incorrect.")
        return data[:-padding_len]

    if style == 'iso7816':
        idx = len(data) - 1
        while idx >= 0 and data[idx] == 0x00:
            idx -= 1
        if idx < 0 or data[idx] != 0x80:
            raise ValueError("Padding is incorrect.")
        # 0x80 必须落在最后一个块内
        if len(data) - idx > block_size:
            raise ValueError("Padding is incorrect.")
        return data[:idx]

    if style == 'x923':
        padding_len = data[-1]
        if padding_len == 0 or padding_len > block_size:
            raise ValueError("Padding is incorrect.")
        if data[-padding_len:-1] != b'\x00' * (padding_len - 1):
            raise ValueError("Padding is incorrect.")
        return data[:-padding_len]

    raise ValueError("Unknown padding style: %s" % style)
