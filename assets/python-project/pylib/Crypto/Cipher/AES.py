# -*- coding: utf-8 -*-
"""
pylib/Crypto/Cipher/AES.py —— AES 纯 Python 垫片
--------------------------------------------------
真 pycryptodome 的 Crypto.* 是 C 扩展，iOS 上交叉编译不了（与 lxml 同理），
所以这里用纯 Python 复刻源脚本里最常见的 AES 用法，并对齐官方 API 形态：

    from Crypto.Cipher import AES
    cipher = AES.new(key, AES.MODE_CBC, iv)      # IV 支持位置参数与 iv=/IV= 关键字
    ct = cipher.encrypt(pad(data, 16))
    pt = unpad(cipher.decrypt(ct), 16)

MODE_* 常量数值与 pycryptodome 完全一致；已实现 ECB / CBC / CFB / OFB / CTR / **GCM**。
性能：纯 Python 每 16 字节块约数十微秒，解几百字节密钥串无感；解 MB 级会慢。
"""

import binascii
import os

# 与 pycryptodome 数值一致
MODE_ECB = 1
MODE_CBC = 2
MODE_CFB = 3
MODE_OFB = 5
MODE_CTR = 6
MODE_OPENPGP = 7
MODE_CCM = 8
MODE_EAX = 9
MODE_SIV = 10
MODE_GCM = 11
MODE_OCB = 12

block_size = 16
key_size = (16, 24, 32)


# ---- GF(2^8) 基础运算（本原多项式 0x11B）---------------------------------

def _gmul(a, b):
    """GF(2^8) 乘法（俄罗斯农夫乘法）。"""
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


def _build_tables():
    """生成 S 盒 / 逆 S 盒。

    不硬编码 256 个常量（手抄极易错一位），改为按 FIPS-197 定义现算：
    GF(2^8) 逆元 + 仿射变换。
    """
    exp = [0] * 255
    log = [0] * 256
    x = 1
    for i in range(255):          # 以 0x03 为生成元建 exp/log 表
        exp[i] = x
        log[x] = i
        x = _gmul(x, 3)

    sbox = [0] * 256
    for a in range(256):
        inv = 0 if a == 0 else exp[(255 - log[a]) % 255]
        # 仿射变换：s = inv ^ rotl(inv,1) ^ rotl(inv,2) ^ rotl(inv,3) ^ rotl(inv,4) ^ 0x63
        # ⚠️ 四个旋转量必须都取自**原始** inv；写成 b ^= rotl(b,k) 会让后一次旋转
        #    使用已被改写过的 b，S 盒整体错位（ECB 都对不上）。
        r1 = ((inv << 1) | (inv >> 7)) & 0xFF
        r2 = ((inv << 2) | (inv >> 6)) & 0xFF
        r3 = ((inv << 3) | (inv >> 5)) & 0xFF
        r4 = ((inv << 4) | (inv >> 4)) & 0xFF
        sbox[a] = (inv ^ r1 ^ r2 ^ r3 ^ r4 ^ 0x63) & 0xFF

    rsbox = [0] * 256
    for a in range(256):
        rsbox[sbox[a]] = a
    return sbox, rsbox


_SBOX, _RSBOX = _build_tables()

# MixColumns / InvMixColumns 的倍乘表（避免每列现算 4 次 gmul）
_GM2 = [_gmul(x, 2) for x in range(256)]
_GM3 = [_gmul(x, 3) for x in range(256)]
_GM9 = [_gmul(x, 9) for x in range(256)]
_GM11 = [_gmul(x, 11) for x in range(256)]
_GM13 = [_gmul(x, 13) for x in range(256)]
_GM14 = [_gmul(x, 14) for x in range(256)]


def _expand_key(key):
    """密钥扩展，返回 (轮密钥字列表, 轮数)。"""
    nk = len(key) // 4
    if nk not in (4, 6, 8):
        raise ValueError("Incorrect AES key length (%d bytes)" % len(key))

    nr = nk + 6
    w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
    rcon = 1
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= rcon
            rcon = _gmul(rcon, 2)
        elif nk > 6 and i % nk == 4:
            t = [_SBOX[b] for b in t]
        w.append([w[i - nk][j] ^ t[j] for j in range(4)])
    return w, nr


# ---- 单块加解密（state 按列优先存放：下标 = 4*列 + 行，与 FIPS-197 一致）----

def _add_round_key(st, w, rnd):
    base = rnd * 4
    for c in range(4):
        wc = w[base + c]
        i = 4 * c
        st[i] ^= wc[0]
        st[i + 1] ^= wc[1]
        st[i + 2] ^= wc[2]
        st[i + 3] ^= wc[3]


def _shift_rows(st):
    for r in range(1, 4):
        row = [st[4 * ((c + r) % 4) + r] for c in range(4)]
        for c in range(4):
            st[4 * c + r] = row[c]


def _inv_shift_rows(st):
    for r in range(1, 4):
        row = [st[4 * c + r] for c in range(4)]
        for c in range(4):
            st[4 * ((c + r) % 4) + r] = row[c]


def _mix_columns(st):
    for c in range(4):
        i = 4 * c
        s0, s1, s2, s3 = st[i], st[i + 1], st[i + 2], st[i + 3]
        st[i] = _GM2[s0] ^ _GM3[s1] ^ s2 ^ s3
        st[i + 1] = s0 ^ _GM2[s1] ^ _GM3[s2] ^ s3
        st[i + 2] = s0 ^ s1 ^ _GM2[s2] ^ _GM3[s3]
        st[i + 3] = _GM3[s0] ^ s1 ^ s2 ^ _GM2[s3]


def _inv_mix_columns(st):
    for c in range(4):
        i = 4 * c
        s0, s1, s2, s3 = st[i], st[i + 1], st[i + 2], st[i + 3]
        st[i] = _GM14[s0] ^ _GM11[s1] ^ _GM13[s2] ^ _GM9[s3]
        st[i + 1] = _GM9[s0] ^ _GM14[s1] ^ _GM11[s2] ^ _GM13[s3]
        st[i + 2] = _GM13[s0] ^ _GM9[s1] ^ _GM14[s2] ^ _GM11[s3]
        st[i + 3] = _GM11[s0] ^ _GM13[s1] ^ _GM9[s2] ^ _GM14[s3]


def _encrypt_block(block, w, nr):
    st = list(block)
    _add_round_key(st, w, 0)
    for rnd in range(1, nr):
        for i in range(16):
            st[i] = _SBOX[st[i]]
        _shift_rows(st)
        _mix_columns(st)
        _add_round_key(st, w, rnd)
    for i in range(16):
        st[i] = _SBOX[st[i]]
    _shift_rows(st)
    _add_round_key(st, w, nr)
    return bytes(st)


def _decrypt_block(block, w, nr):
    st = list(block)
    _add_round_key(st, w, nr)
    for rnd in range(nr - 1, 0, -1):
        _inv_shift_rows(st)
        for i in range(16):
            st[i] = _RSBOX[st[i]]
        _add_round_key(st, w, rnd)
        _inv_mix_columns(st)
    _inv_shift_rows(st)
    for i in range(16):
        st[i] = _RSBOX[st[i]]
    _add_round_key(st, w, 0)
    return bytes(st)


# ---- 模式实现 ---------------------------------------------------------

class _AesBase(object):
    """所有模式共用的加解密骨架。"""

    mode = None
    iv = b""

    def __init__(self, key, w, nr):
        self._w = w
        self._nr = nr
        self.key = bytes(key)

    def _keystream_block(self, block):
        return _encrypt_block(block, self._w, self._nr)

    # 各模式覆盖这两个方法
    def encrypt(self, data):
        raise NotImplementedError

    def decrypt(self, data):
        raise NotImplementedError

    def _require_block_multiple(self, data):
        if len(data) % 16:
            raise ValueError(
                "Data must be padded to 16 byte boundary in %s mode"
                % self.mode)


class _EcbMode(_AesBase):
    mode = 'ECB'

    def encrypt(self, data):
        self._require_block_multiple(data)
        out = []
        for i in range(0, len(data), 16):
            out.append(_encrypt_block(data[i:i + 16], self._w, self._nr))
        return b"".join(out)

    def decrypt(self, data):
        self._require_block_multiple(data)
        out = []
        for i in range(0, len(data), 16):
            out.append(_decrypt_block(data[i:i + 16], self._w, self._nr))
        return b"".join(out)


class _CbcMode(_AesBase):
    mode = 'CBC'

    def __init__(self, key, w, nr, iv):
        _AesBase.__init__(self, key, w, nr)
        if len(iv) != 16:
            raise ValueError("Incorrect IV length (it must be 16 bytes long)")
        self.iv = bytes(iv)

    def encrypt(self, data):
        self._require_block_multiple(data)
        prev = self.iv
        out = []
        for i in range(0, len(data), 16):
            blk = bytes(a ^ b for a, b in zip(data[i:i + 16], prev))
            prev = _encrypt_block(blk, self._w, self._nr)
            out.append(prev)
        self.iv = prev          # 与 pycryptodome 一致：IV 随加密滚动
        return b"".join(out)

    def decrypt(self, data):
        self._require_block_multiple(data)
        prev = self.iv
        out = []
        for i in range(0, len(data), 16):
            ct = data[i:i + 16]
            pt = _decrypt_block(ct, self._w, self._nr)
            out.append(bytes(a ^ b for a, b in zip(pt, prev)))
            prev = ct
        self.iv = prev
        return b"".join(out)


class _CfbMode(_AesBase):
    mode = 'CFB'

    def __init__(self, key, w, nr, iv, segment_size=8):
        _AesBase.__init__(self, key, w, nr)
        if len(iv) != 16:
            raise ValueError("Incorrect IV length (it must be 16 bytes long)")
        if segment_size not in (8, 128):
            raise ValueError("segment_size must be 8 or 128")
        self.iv = bytes(iv)
        self._seg = segment_size // 8
        # CFB-8 的反馈寄存器需要按字节滚动，单独存一份
        self._fb = self.iv

    def encrypt(self, data):
        seg = self._seg
        out = bytearray()
        for i in range(0, len(data), seg):
            chunk = data[i:i + seg]
            ks = _encrypt_block(self._fb, self._w, self._nr)[:len(chunk)]
            ct = bytes(a ^ b for a, b in zip(chunk, ks))
            out += ct
            if seg == 16:
                self._fb = ct
            else:
                self._fb = self._fb[seg:] + ct
        self.iv = self._fb
        return bytes(out)

    def decrypt(self, data):
        seg = self._seg
        out = bytearray()
        for i in range(0, len(data), seg):
            chunk = data[i:i + seg]
            ks = _encrypt_block(self._fb, self._w, self._nr)[:len(chunk)]
            out += bytes(a ^ b for a, b in zip(chunk, ks))
            if seg == 16:
                self._fb = chunk
            else:
                self._fb = self._fb[seg:] + chunk
        self.iv = self._fb
        return bytes(out)


class _OfbMode(_AesBase):
    mode = 'OFB'

    def __init__(self, key, w, nr, iv):
        _AesBase.__init__(self, key, w, nr)
        if len(iv) != 16:
            raise ValueError("Incorrect IV length (it must be 16 bytes long)")
        self.iv = bytes(iv)
        self._fb = self.iv

    def _xor_stream(self, data):
        out = bytearray()
        for i in range(0, len(data), 16):
            ks = _encrypt_block(self._fb, self._w, self._nr)
            self._fb = ks
            chunk = data[i:i + 16]
            out += bytes(a ^ b for a, b in zip(chunk, ks))
        self.iv = self._fb
        return bytes(out)

    encrypt = _xor_stream
    decrypt = _xor_stream


class _CtrMode(_AesBase):
    mode = 'CTR'

    def __init__(self, key, w, nr, nonce, initial_value=None, counter=None):
        _AesBase.__init__(self, key, w, nr)
        if counter is not None:
            # 源里极少自己造 counter，但支持一下：每次调用返回 16 字节计数器块
            self._counter = counter
        else:
            if nonce is None:
                raise TypeError("CTR mode requires a nonce or a counter")
            nonce = bytes(nonce)
            if initial_value:
                iv = bytes(initial_value)
                width = 16 - len(nonce) - len(iv)
                value = int.from_bytes(iv, 'big')
            else:
                # pycryptodome 语义：不传 initial_value 时，剩余字节全部当计数器
                # （nonce 8 字节 → 低 8 字节从 0 开始递增），计数器块固定 16 字节。
                width = 16 - len(nonce)
                value = 0
            if width < 0:
                raise ValueError("Incorrect nonce/initial_value length")
            self._prefix = nonce
            self._width = width
            self._value = value

            def _next_block():
                if self._width == 0:
                    return self._prefix[:16]
                blk = self._prefix + self._value.to_bytes(self._width, 'big')
                self._value += 1
                return blk[:16]

            self._counter = _next_block
        self.iv = b""

    def _xor_stream(self, data):
        out = bytearray()
        for i in range(0, len(data), 16):
            ks = self._keystream_block(self._counter())
            chunk = data[i:i + 16]
            out += bytes(a ^ b for a, b in zip(chunk, ks))
        return bytes(out)

    encrypt = _xor_stream
    decrypt = _xor_stream


# ---- GCM（SP 800-38D）---------------------------------------------------
#
# 为什么必须补：**封面签名 / 播放地址加密**里 GCM 是最常见的一种（腾讯/爱奇艺系的
# 私有接口、不少猫源都用它）。以前 MODE_GCM 只有常量没有实现，源一调用就报错，
# 表现就是"封面或视频解密不出来"。
#
# 结构：AES 块加密复用上面的 _encrypt_block；认证走 GHASH（GF(2^128) 乘法）；
# 数据加密用 GCTR（只对低 32 位做 inc32）。与 pycryptodome 双向对拍验证过。

def _gcm_inc32(x):
    """GCTR 的计数器步进：**只对最低 32 位加 1**（SP 800-38D 的 inc32）。

    ⚠️ 这里原来写成 `x & 0xFFFFFFFF00000000` —— 那是 **64 位**掩码，
      会把 128 位计数器的**高 64 位抹掉**。用全零 IV 的 NIST 向量时高 64 位
       本来就是 0，所以侥幸通过；一旦 IV 非零（源里几乎必然），从**第一块**
       开始计数块就错，表现为"解出来是乱码/封面地址拿不到"。
       正确写法是只保留低 32 位以外的全部高位：`x & ~0xFFFFFFFF`。
    """
    return (x & ~0xFFFFFFFF) | ((x + 1) & 0xFFFFFFFF)


def _gcm_blocks(data):
    """按 16 字节切块（末尾按需零补齐）。"""
    if len(data) % 16:
        data = data + b"\x00" * (16 - len(data) % 16)
    return [data[i:i + 16] for i in range(0, len(data), 16)]


def _gcm_mul(x, y):
    """GF(2^128) 乘法（SP 800-38D 的位序：左起高位，右移 + 0xE1 归约）。"""
    z = 0
    v = y
    for i in range(128):
        if (x >> (127 - i)) & 1:
            z ^= v
        if v & 1:
            v = (v >> 1) ^ 0xE1000000000000000000000000000000
        else:
            v >>= 1
    return z


def _gcm_ghash(h, blocks):
    x = 0
    for b in blocks:
        x = _gcm_mul(x ^ int.from_bytes(b, "big"), h)
    return x


def _tags_equal(a, b):
    """定长比较（不早退，避免 tag 比较被计时侧信道——与实际安全无关，但照惯例做）。"""
    if len(a) != len(b):
        return False
    diff = 0
    for x, y in zip(bytearray(a), bytearray(b)):
        diff |= x ^ y
    return diff == 0


class _GcmMode(_AesBase):
    """AES-GCM，方法面严格对齐 pycryptodome：

        update(aad) / encrypt / decrypt / digest / hexdigest
        verify / hexverify / encrypt_and_digest / decrypt_and_verify
        nonce / block_size
    """

    block_size = 16
    mode = "GCM"

    def __init__(self, key, w, nr, nonce=None, mac_len=16):
        _AesBase.__init__(self, key, w, nr)
        if mac_len not in (4, 8, 12, 13, 14, 15, 16):
            raise ValueError(
                "MAC length must be 4, 8, 12, 13, 14, 15 or 16 bytes")
        self.mac_len = mac_len
        # 不传 nonce 时与 pycryptodome 一样随机 16 字节（注意：此时走的是
        # "非 12 字节 IV" 那条 J0 计算路径，必须算对）
        self.nonce = os.urandom(16) if nonce is None else bytes(nonce)
        self._h = int.from_bytes(_encrypt_block(b"\x00" * 16, w, nr), "big")
        if len(self.nonce) == 12:
            # 推荐路径：J0 = IV || 0x00000001
            self._j0 = int.from_bytes(self.nonce + b"\x00\x00\x00\x01", "big")
        else:
            # J0 = GHASH_H(IV || 0^(s+64) || [len(IV)]_64)（长度是**位**数）
            pad = b"\x00" * ((16 - len(self.nonce) % 16) % 16)
            tail = b"\x00" * 8 + (len(self.nonce) * 8).to_bytes(8, "big")
            self._j0 = _gcm_ghash(self._h, _gcm_blocks(self.nonce + pad + tail))
        self._aad = bytearray()
        self._ct = bytearray()
        self._started = False
        # 最近一次是加密还是解密 —— pycryptodome 在"加密态"下调 verify() 会抛
        # TypeError("verify() cannot be called when encrypting a message")，这里对齐
        self._mode = None

    # -- GCTR：从 [icb] 开始逐块加密，只对低 32 位 inc32 --
    def _gctr(self, icb, data):
        out = bytearray()
        counter = icb
        for i in range(0, len(data), 16):
            ks = _encrypt_block(counter.to_bytes(16, "big"), self._w, self._nr)
            out += bytes(a ^ b for a, b in zip(data[i:i + 16], ks))
            counter = _gcm_inc32(counter)
        return bytes(out)

    def _data_ctr(self):
        # 数据部分从 inc32(J0) 开始（tag 才用 J0 本身）
        return _gcm_inc32(self._j0)

    # -- pycryptodome 的公开方法面 --
    def update(self, aad):
        if self._started:
            raise TypeError(
                "You cannot call update() after encrypt() or decrypt()")
        self._aad += bytes(aad)

    def encrypt(self, plaintext):
        self._started = True
        self._mode = "enc"
        ct = self._gctr(self._data_ctr(), bytes(plaintext))
        self._ct += ct
        return ct

    def decrypt(self, ciphertext):
        self._started = True
        self._mode = "dec"
        self._ct += bytes(ciphertext)
        return self._gctr(self._data_ctr(), bytes(ciphertext))

    def digest(self):
        aad = bytes(self._aad)
        ct = bytes(self._ct)
        a_pad = b"\x00" * ((16 - len(aad) % 16) % 16)
        c_pad = b"\x00" * ((16 - len(ct) % 16) % 16)
        blob = (aad + a_pad + ct + c_pad
                + (len(aad) * 8).to_bytes(8, "big")
                + (len(ct) * 8).to_bytes(8, "big"))
        s = _gcm_ghash(self._h, _gcm_blocks(blob))
        return self._gctr(self._j0, s.to_bytes(16, "big"))[:self.mac_len]

    def hexdigest(self):
        # ⚠️ pycryptodome 这里是 `binascii.hexlify(...).decode()` ⇒ 返回 **str**
        #    （不是 bytes）。源脚本常直接拿它拼进 URL，返回 bytes 会拼出
        #    "b'...'" 这种垃圾串，所以必须同类型。
        return binascii.hexlify(self.digest()).decode()

    def verify(self, received_mac_tag):
        if self._mode == "enc":
            raise TypeError("verify() cannot be called when encrypting a message")
        if not _tags_equal(self.digest(), bytes(received_mac_tag)):
            raise ValueError("MAC check failed")

    def hexverify(self, hex_mac_tag):
        # 真库这里对 str 会崩（内部按 bytes 处理）；垫片**兼容两种**输入，
        # 比真库宽松一点，不会因此算错。
        if isinstance(hex_mac_tag, str):
            hex_mac_tag = hex_mac_tag.encode("ascii")
        self.verify(binascii.unhexlify(hex_mac_tag))

    def encrypt_and_digest(self, plaintext):
        return self.encrypt(plaintext), self.digest()

    def decrypt_and_verify(self, ciphertext, received_mac_tag):
        plaintext = self.decrypt(ciphertext)
        self.verify(received_mac_tag)
        return plaintext


# ---- 工厂 -------------------------------------------------------------

def new(key, mode, *args, **kwargs):
    """对齐 pycryptodome 的 AES.new。IV 既支持位置参数也支持 iv=/IV= 关键字。"""
    key = bytes(key)
    w, nr = _expand_key(key)

    if mode == MODE_ECB:
        return _EcbMode(key, w, nr)

    # CBC / CFB / OFB：第三个位置参数就是 IV
    if mode in (MODE_CBC, MODE_CFB, MODE_OFB):
        iv = None
        if args:
            iv = args[0]
        for k in ('iv', 'IV'):
            if kwargs.get(k) is not None:
                iv = kwargs[k]
        if iv is None:
            raise TypeError("%s mode requires an IV" % {
                MODE_CBC: 'CBC', MODE_CFB: 'CFB', MODE_OFB: 'OFB'}[mode])
        if mode == MODE_CBC:
            return _CbcMode(key, w, nr, bytes(iv))
        if mode == MODE_OFB:
            return _OfbMode(key, w, nr, bytes(iv))
        return _CfbMode(key, w, nr, bytes(iv),
                        segment_size=kwargs.get('segment_size', 8))

    if mode == MODE_CTR:
        return _CtrMode(key, w, nr, kwargs.get('nonce'),
                        kwargs.get('initial_value'), kwargs.get('counter'))

    if mode == MODE_GCM:
        # nonce 支持位置参数（AES.new(key, MODE_GCM, nonce_bytes)）与关键字
        nonce = kwargs.get('nonce')
        if nonce is None and args:
            nonce = args[0]
        return _GcmMode(key, w, nr, nonce=nonce,
                        mac_len=kwargs.get('mac_len', 16))

    if mode in (MODE_CCM, MODE_EAX, MODE_SIV, MODE_OCB):
        raise NotImplementedError(
            "AES %s 模式尚未在纯 Python 垫片中实现；电视源里通常用 CBC/ECB/GCM"
            % {MODE_CCM: 'CCM', MODE_EAX: 'EAX',
               MODE_SIV: 'SIV', MODE_OCB: 'OCB'}[mode])

    raise ValueError("Unknown AES mode %r" % (mode,))
