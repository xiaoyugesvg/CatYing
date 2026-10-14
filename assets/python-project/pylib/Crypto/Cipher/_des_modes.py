# -*- coding: utf-8 -*-
"""DES / DES3 共用的**分组工作模式**（ECB / CBC / CFB / OFB）。

为什么单独一个文件：DES 与 3DES 只差一个"块加解密函数"，模式逻辑完全一样；
写两份必然走样。这里做成"传入 enc_block/dec_block + 块大小 8"的通用层。

只做源脚本里真正用得到的四个模式。**刻意不做** CTR / EAX / OPENPGP ——
按 pylib 的一贯口径：不预铺"看着有、其实算错"的 API，缺什么报什么。
"""


def _xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


class _BaseMode(object):
    block_size = 8

    def __init__(self, enc_block, dec_block):
        self._enc = enc_block
        self._dec = dec_block

    def _require_multiple(self, data):
        if len(data) % self.block_size:
            raise ValueError(
                "Data must be padded to %d byte boundary in this mode"
                % self.block_size)


class EcbMode(_BaseMode):
    def encrypt(self, data):
        self._require_multiple(data)
        out = bytearray()
        for i in range(0, len(data), 8):
            out += self._enc(bytes(data[i:i + 8]))
        return bytes(out)

    def decrypt(self, data):
        self._require_multiple(data)
        out = bytearray()
        for i in range(0, len(data), 8):
            out += self._dec(bytes(data[i:i + 8]))
        return bytes(out)


class CbcMode(_BaseMode):
    def __init__(self, enc_block, dec_block, iv):
        super(CbcMode, self).__init__(enc_block, dec_block)
        if len(iv) != 8:
            raise ValueError("IV must be 8 bytes long")
        self._prev = bytes(iv)

    def encrypt(self, data):
        self._require_multiple(data)
        out = bytearray()
        prev = self._prev
        for i in range(0, len(data), 8):
            blk = self._enc(_xor(bytes(data[i:i + 8]), prev))
            out += blk
            prev = blk
        self._prev = prev
        return bytes(out)

    def decrypt(self, data):
        self._require_multiple(data)
        out = bytearray()
        prev = self._prev
        for i in range(0, len(data), 8):
            blk = bytes(data[i:i + 8])
            out += _xor(self._dec(blk), prev)
            prev = blk
        self._prev = prev
        return bytes(out)


class CfbMode(_BaseMode):
    """CFB，默认 `segment_size=8`（按**字节**反馈）——与 pycryptodome 默认一致。

    反馈寄存器每处理 1 字节就左移 8 位，并把**密文**字节补进去。
    """

    def __init__(self, enc_block, dec_block, iv, segment_size=8):
        super(CfbMode, self).__init__(enc_block, dec_block)
        if segment_size != 8:
            raise NotImplementedError(
                "only segment_size=8 is implemented (got %r)" % (segment_size,))
        if len(iv) != 8:
            raise ValueError("IV must be 8 bytes long")
        self._fb = bytes(iv)

    def encrypt(self, data):
        out = bytearray()
        fb = self._fb
        for ch in bytearray(data):
            c = ch ^ self._enc(fb)[0]
            out.append(c)
            fb = fb[1:] + bytes([c])
        self._fb = fb
        return bytes(out)

    def decrypt(self, data):
        out = bytearray()
        fb = self._fb
        for ct in bytearray(data):
            out.append(ct ^ self._enc(fb)[0])
            fb = fb[1:] + bytes([ct])
        self._fb = fb
        return bytes(out)


class OfbMode(_BaseMode):
    """OFB：每 **8 字节**才重算一次 keystream（不是每字节重算）。"""

    def __init__(self, enc_block, dec_block, iv):
        super(OfbMode, self).__init__(enc_block, dec_block)
        if len(iv) != 8:
            raise ValueError("IV must be 8 bytes long")
        self._fb = bytes(iv)
        self._ks = b''

    def _stream(self, data):
        out = bytearray()
        buf = self._ks
        fb = self._fb
        for ch in bytearray(data):
            if not buf:
                fb = self._enc(fb)
                buf = fb
            out.append(ch ^ buf[0])
            buf = buf[1:]
        self._ks = buf
        self._fb = fb
        return bytes(out)

    def encrypt(self, data):
        return self._stream(data)

    def decrypt(self, data):
        return self._stream(data)


def build_mode(mode, enc_block, dec_block, args, kwargs):
    """按 `MODE_*` 造出模式对象；未实现的模式给出**明确**的报错。

    [args] / [kwargs] 直接沿用源脚本的写法：IV 既支持位置参数，也支持 `iv=` / `IV=`。
    """
    if mode == MODE_ECB:
        # pycryptodome 的 ECB 传 IV 会报错，这里也拒绝（早失败好排查）
        if args or kwargs:
            raise TypeError("ECB mode does not accept an IV")
        return EcbMode(enc_block, dec_block)

    def _iv():
        if args:
            return args[0]
        for key in ('iv', 'IV'):
            if key in kwargs:
                return kwargs[key]
        raise TypeError("this mode requires an IV")

    if mode == MODE_CBC:
        return CbcMode(enc_block, dec_block, _iv())
    if mode == MODE_CFB:
        return CfbMode(enc_block, dec_block, _iv(),
                       segment_size=kwargs.get('segment_size', 8))
    if mode == MODE_OFB:
        return OfbMode(enc_block, dec_block, _iv())

    raise NotImplementedError(
        "mode=%r 未实现（垫片只做 ECB/CBC/CFB/OFB）" % (mode,))


# 与 pycryptodome 数值一致的 MODE_*（DES/DES3 与之相同，故放这里共用）
MODE_ECB = 1
MODE_CBC = 2
MODE_CFB = 3
MODE_OFB = 5
MODE_CTR = 6
MODE_OPENPGP = 7
MODE_EAX = 9
