# -*- coding: utf-8 -*-
"""
pylib/Crypto/PublicKey/RSA.py —— RSA 纯 Python 垫片
----------------------------------------------------
对齐 pycryptodome 里视频/书源最常打交道的几个入口：

    from Crypto.PublicKey import RSA
    key = RSA.import_key(pem_text)          # PEM / DER，PKCS#1 / PKCS#8 / SPKI
    key = RSA.construct((n, e))             # 源里常见：只有模数和指数
    key = RSA.construct((n, e, d))
    key = RSA.generate(1024)                # 造密钥（很少用但补齐）
    pt  = key._decrypt(ct)                  # 原始 RSA 解密 pow(c, d, n)

RSA 的加解密本体是模幂运算，Python 内置 pow(a, b, m) 走的就是 C 层大整数，
速度与原生实现同一量级；真正麻烦的只是 PEM/DER 解析（这里手搓了一个最小
ASN.1 解析器）。
不支持：带口令的加密私钥（PBES2/PKCS#5），遇到会抛出明确的 NotImplementedError。
"""

import base64
import os

from ..Util.number import inverse, long_to_bytes

# ---- 最小 ASN.1（DER）工具 --------------------------------------------

_INT = 0x02
_SEQ = 0x30
_BIT_STR = 0x03
_OCT_STR = 0x04
_NULL = 0x05
_OID = 0x06

_OID_RSA_ENCRYPTION = bytes.fromhex('2a864886f70d010101')


def _read_tlv(buf, pos):
    """读一个 TLV，返回 (tag, value, 下一个位置)。"""
    if pos >= len(buf):
        raise ValueError("DER 数据被截断")
    tag = buf[pos]
    pos += 1
    if tag & 0x1F == 0x1F:                      # 多字节 tag（本场景用不到但兼容）
        while pos < len(buf) and (buf[pos] & 0x80):
            pos += 1
        pos += 1
    if pos >= len(buf):
        raise ValueError("DER 数据被截断")
    ln = buf[pos]
    pos += 1
    if ln & 0x80:                               # 长长度域
        n = ln & 0x7F
        if n == 0 or pos + n > len(buf):
            raise ValueError("DER 长度域非法")
        ln = int.from_bytes(buf[pos:pos + n], 'big')
        pos += n
    end = pos + ln
    if end > len(buf):
        raise ValueError("DER 数据被截断")
    return tag, buf[pos:end], end


def _walk(seq_body):
    """遍历一个 SEQUENCE 的直接子项。"""
    pos = 0
    while pos < len(seq_body):
        tag, value, pos = _read_tlv(seq_body, pos)
        yield tag, value


def _ints_of(seq_body):
    return [int.from_bytes(v, 'big') for t, v in _walk(seq_body) if t == _INT]


def _seq_body_of(der):
    tag, body, _ = _read_tlv(der, 0)
    if tag != _SEQ:
        raise ValueError("不是 ASN.1 SEQUENCE，无法识别为 RSA 密钥")
    return body


def _parse_pkcs1_private(der):
    """PKCS#1 RSAPrivateKey：SEQUENCE { version, n, e, d, p, q, ... }"""
    vals = _ints_of(_seq_body_of(der))
    if len(vals) < 6:
        raise ValueError("PKCS#1 私钥字段不足（少于 6 个 INTEGER）")
    return {'n': vals[1], 'e': vals[2], 'd': vals[3], 'p': vals[4], 'q': vals[5]}


def _parse_pkcs1_public(der):
    """PKCS#1 RSAPublicKey：SEQUENCE { n, e }"""
    vals = _ints_of(_seq_body_of(der))
    if len(vals) < 2:
        raise ValueError("PKCS#1 公钥字段不足")
    return {'n': vals[0], 'e': vals[1]}


def _parse_spki(der):
    """X.509 SubjectPublicKeyInfo：SEQUENCE { AlgorithmIdentifier, BIT STRING }"""
    items = list(_walk(_seq_body_of(der)))
    if len(items) < 2 or items[1][0] != _BIT_STR:
        raise ValueError("不是 SubjectPublicKeyInfo 公钥")
    algo_tag, algo_body = items[0]
    if algo_tag == _SEQ:
        subs = list(_walk(algo_body))
        if subs and subs[0][0] == _OID and subs[0][1] != _OID_RSA_ENCRYPTION:
            raise ValueError("OID 不是 rsaEncryption，本垫片只支持 RSA")
    bits = items[1][1]
    if bits and bits[0] == 0:                   # BIT STRING 的 unused-bits 计数
        bits = bits[1:]
    return _parse_pkcs1_public(bits)


def _parse_pkcs8(der):
    """PKCS#8 PrivateKeyInfo：SEQUENCE { version, AlgorithmIdentifier, OCTET STRING }"""
    for tag, value in _walk(_seq_body_of(der)):
        if tag == _OCT_STR:
            return _parse_pkcs1_private(value)
    raise ValueError("PKCS#8 里没有找到 OCTET STRING 私钥体")


def _import_der(der):
    """按结构逐个试：PKCS#8 → PKCS#1 私钥 → SPKI 公钥 → PKCS#1 公钥。

    顺序不能颠倒：PKCS#1 公钥解析（只看前两个 INTEGER）对私钥也能"成功"，
    放在最后兜底才不会把私钥错认成公钥。
    """
    errors = []
    for parser in (_parse_pkcs8, _parse_pkcs1_private, _parse_spki,
                   _parse_pkcs1_public):
        try:
            return RsaKey(**parser(der))
        except Exception as e:                  # noqa: BLE001 - 逐个回退是设计
            errors.append('%s: %s' % (parser.__name__, e))
    raise ValueError("RSA key format is not supported（%s）" % '; '.join(errors))


# ---- DER 编码（export_key 用）----------------------------------------

def _enc_len(n):
    if n < 0x80:
        return bytes([n])
    b = long_to_bytes(n)
    return bytes([0x80 | len(b)]) + b


def _enc_tlv(tag, payload):
    return bytes([tag]) + _enc_len(len(payload)) + payload


def _enc_int(n):
    b = long_to_bytes(n)
    if b[0] & 0x80:
        b = b'\x00' + b
    return _enc_tlv(_INT, b)


def _pem_wrap(label, der):
    b64 = base64.encodebytes(der).decode().replace('\n', '')
    body = '\n'.join(b64[i:i + 64] for i in range(0, len(b64), 64))
    return ('-----BEGIN %s-----\n%s\n-----END %s-----\n'
            % (label, body, label)).encode()


# ---- 素性与密钥生成 ---------------------------------------------------

_SMALL_PRIMES = (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47)


def _is_probable_prime(n, rounds=20):
    """Miller-Rabin 概率素性检验（RSA.generate 与 Util.number.getPrime 共用）。"""
    if n < 2:
        return False
    for p in _SMALL_PRIMES:
        if n == p:
            return True
        if n % p == 0:
            return False

    d = n - 1
    r = 0
    while d % 2 == 0:
        d //= 2
        r += 1

    for _ in range(rounds):
        a = 2 + int.from_bytes(os.urandom(4), 'big') % (n - 3)
        x = pow(a, d, n)
        if x == 1 or x == n - 1:
            continue
        for _ in range(r - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def _gen_prime(nbits):
    while True:
        candidate = int.from_bytes(os.urandom((nbits + 7) // 8), 'big')
        candidate |= (1 << (nbits - 1)) | 1        # 保证位数 + 奇数
        bad = False
        for p in _SMALL_PRIMES:
            if candidate % p == 0:
                bad = True
                break
        if bad:
            continue
        if _is_probable_prime(candidate):
            return candidate


# ---- 密钥对象 ---------------------------------------------------------

class RsaKey(object):
    """对齐 pycryptodome RsaKey 的属性与方法（覆盖源里用得到的那部分）。"""

    def __init__(self, n=None, e=None, d=None, p=None, q=None, u=None):
        if n is None or e is None:
            raise ValueError("RSA key 缺少模数 n 或公开指数 e")
        self.n = int(n)
        self.e = int(e)
        self.d = int(d) if d is not None else None
        self.p = int(p) if p is not None else None
        self.q = int(q) if q is not None else None
        if u is not None:
            self.u = int(u)
        elif self.p is not None and self.q is not None:
            try:
                self.u = inverse(self.p, self.q)
            except Exception:                       # noqa: BLE001
                self.u = None
        else:
            self.u = None

    # -- 基本信息 --
    def has_private(self):
        return self.d is not None

    def size_in_bits(self):
        return self.n.bit_length()

    def size_in_bytes(self):
        return (self.size_in_bits() + 7) // 8

    def publickey(self):
        return RsaKey(n=self.n, e=self.e)

    # -- 原始加解密（Cipher.PKCS1_v1_5 / PKCS1_OAEP 都建在这两个之上）--
    # 名字与 pycryptodome 的 RsaKey._decrypt / _encrypt 一致：
    # 源里确实有人直接 `key._decrypt(ct)` 拿裸明文。
    def _decrypt(self, ciphertext):
        if not self.has_private():
            raise TypeError("This is not a private key")
        k = self.size_in_bytes()
        c = int.from_bytes(bytes(ciphertext), 'big')
        if c >= self.n:
            raise ValueError("Ciphertext too large")
        m = pow(c, self.d, self.n)
        return m.to_bytes(k, 'big')

    def _encrypt(self, plaintext):
        k = self.size_in_bytes()
        m = int.from_bytes(bytes(plaintext), 'big')
        if m >= self.n:
            raise ValueError("Plaintext too large")
        c = pow(m, self.e, self.n)
        return c.to_bytes(k, 'big')

    # -- 导出 --
    def export_key(self, format='PEM', passphrase=None, pkcs=1, **kwargs):
        if passphrase is not None:
            raise NotImplementedError(
                "纯 Python 垫片暂不支持导出口令加密的 RSA 私钥")
        if self.has_private():
            if pkcs == 8:
                der = _enc_tlv(_SEQ, _enc_int(0)
                               + _enc_tlv(_SEQ, _enc_tlv(_OID, _OID_RSA_ENCRYPTION)
                                          + _enc_tlv(_NULL, b''))
                               + _enc_tlv(_OCT_STR, self._pkcs1_private_der()))
                label = 'PRIVATE KEY'
            else:
                der = self._pkcs1_private_der()
                label = 'RSA PRIVATE KEY'
        else:
            # 公钥：pycryptodome 无论 pkcs=1 还是 8，导出的一律是
            # X.509 SubjectPublicKeyInfo（标签 "PUBLIC KEY"），
            # 不会产出 PKCS#1 的 "RSA PUBLIC KEY"（已与真库逐字节对拍过）。
            der = _enc_tlv(
                _SEQ,
                _enc_tlv(_SEQ, _enc_tlv(_OID, _OID_RSA_ENCRYPTION)
                         + _enc_tlv(_NULL, b''))
                + _enc_tlv(_BIT_STR, b'\x00' + _enc_tlv(
                    _SEQ, _enc_int(self.n) + _enc_int(self.e))))
            label = 'PUBLIC KEY'
        if str(format).upper() == 'DER':
            return der
        return _pem_wrap(label, der)

    def _pkcs1_private_der(self):
        if self.p is None or self.q is None:
            raise ValueError("导出 PKCS#1 私钥需要 p/q 分量（可用 construct 传入）")
        dp = self.d % (self.p - 1)
        dq = self.d % (self.q - 1)
        qinv = inverse(self.q, self.p)
        return _enc_tlv(_SEQ,
                        _enc_int(0) + _enc_int(self.n) + _enc_int(self.e)
                        + _enc_int(self.d) + _enc_int(self.p) + _enc_int(self.q)
                        + _enc_int(dp) + _enc_int(dq) + _enc_int(qinv))

    def __repr__(self):
        state = 'private' if self.has_private() else 'public'
        return '<RsaKey %s %d bits>' % (state, self.size_in_bits())


# ---- 对外入口 ---------------------------------------------------------

def _decode_pem(text):
    """返回 (label, der)。"""
    label = ''
    body = []
    for line in text.strip().splitlines():
        line = line.strip()
        if line.startswith('-----BEGIN') and line.endswith('-----'):
            label = line[11:-5].strip()
        elif line.startswith('-----END'):
            continue
        elif ':' in line:                        # Proc-Type / DEK-Info 等头部
            continue
        elif line:
            body.append(line)
    if not body:
        raise ValueError("PEM 内容为空或无法识别")
    return label, base64.b64decode(''.join(body))


def import_key(extern_key, passphrase=None):
    """导入 RSA 密钥：PEM 字符串 / PEM 字节串 / DER 字节串 / 裸 base64。"""
    if passphrase is not None:
        raise NotImplementedError("纯 Python 垫片暂不支持带口令的加密 RSA 私钥")

    if isinstance(extern_key, (bytes, bytearray)):
        raw = bytes(extern_key)
        if b'-----BEGIN' in raw:                 # PEM 也能按字节传（真库支持）
            extern_key = raw.decode('utf-8', 'ignore')
        else:
            return _import_der(raw)

    if isinstance(extern_key, str):
        text = extern_key.strip()
        if '-----BEGIN' in text:
            if 'ENCRYPTED' in text.upper():
                raise NotImplementedError(
                    "暂不支持加密私钥（ENCRYPTED PRIVATE KEY）")
            label, der = _decode_pem(text)
            label = label.upper()
            if label == 'RSA PRIVATE KEY':
                return RsaKey(**_parse_pkcs1_private(der))
            if label == 'PRIVATE KEY':
                return RsaKey(**_parse_pkcs8(der))
            if label == 'PUBLIC KEY':
                return RsaKey(**_parse_spki(der))
            if label == 'RSA PUBLIC KEY':
                return RsaKey(**_parse_pkcs1_public(der))
            raise ValueError("不支持的 PEM 标签: %s" % label)
        # 裸 base64
        try:
            der = base64.b64decode(''.join(text.split()))
        except Exception:
            raise ValueError("RSA key format is not supported")
        return _import_der(der)

    return _import_der(bytes(extern_key))


# 兼容旧写法（pycryptodome 保留了驼峰别名）
importKey = import_key


def construct(tup, consistency_check=True):
    """用 (n, e[, d[, p, q[, u]]]) 造 RsaKey。

    TVBox 源里很常见：接口只给模数和指数，源自己拼 key。
    consistency_check 参数仅为兼容签名，这里不做额外校验（参数本身来自源，
    错了会在解密结果上直接暴露，不必在加载期抛错）。
    """
    if not isinstance(tup, (tuple, list)):
        raise TypeError("The input must be a tuple")
    length = len(tup)
    if length == 2:
        return RsaKey(n=tup[0], e=tup[1])
    if length == 3:
        return RsaKey(n=tup[0], e=tup[1], d=tup[2])
    if length == 5:
        return RsaKey(n=tup[0], e=tup[1], d=tup[2], p=tup[3], q=tup[4])
    if length == 6:
        return RsaKey(n=tup[0], e=tup[1], d=tup[2], p=tup[3], q=tup[4],
                       u=tup[5])
    raise ValueError("Not a valid RSA key tuple (2/3/5/6 elements)")


def generate(bits, randfunc=None, e=65537):
    """生成 RSA 密钥对。"""
    if bits < 512:
        raise ValueError("RSA modulus length must be >= 512")
    if e < 3 or e % 2 == 0:
        raise ValueError("RSA public exponent must be odd and >= 3")

    while True:
        p = _gen_prime(bits // 2 + bits % 2)
        q = _gen_prime(bits // 2)
        if p == q:
            continue
        n = p * q
        if n.bit_length() != bits:
            continue
        try:
            d = inverse(e, (p - 1) * (q - 1))
        except ValueError:
            continue
        return RsaKey(n=n, e=e, d=d, p=p, q=q)
