# -*- coding: utf-8 -*-
"""
pylib/Crypto —— pycryptodome 的纯 Python 垫片
==============================================
iOS 上真 pycryptodome 是 C 扩展，交叉编译不了（与 lxml 同一个坑），
但视频/书源里真正用到的只是少数几个符号。这里按需复刻：

    Crypto.Cipher.AES            纯 Python AES（ECB/CBC/CFB/OFB/CTR/**GCM**）
    Crypto.Cipher.DES            纯 Python DES（ECB/CBC/CFB/OFB）
    Crypto.Cipher.DES3           纯 Python 3DES/EDE（16 或 24 字节 key）
    Crypto.Cipher.PKCS1_v1_5     RSA PKCS#1 v1.5 加解密
    Crypto.Cipher.PKCS1_OAEP     RSA-OAEP 加解密
    Crypto.PublicKey.RSA         PEM/DER 导入、construct、(n,e,d) 原始解密
    Crypto.Util.Padding          pad/unpad（pkcs7/iso7816/x923）
    Crypto.Util.number           long_to_bytes / bytes_to_long / inverse
    Crypto.Hash.*                MD5/SHA1/SHA256/SHA512（hashlib 实现）
    Crypto.Random                get_random_bytes

**正确性怎么保证的**（scratch/verify_des_gcm.py，1285 项断言）：
  ① 先对**官方测试向量**（GCM 用 McGrew-Viega case 1~5，含非 96 位 IV；
     DES 用 FIPS 81 标准向量）—— 这一层是"规范怎么说"，不依赖任何实现；
  ② 再与**真 pycryptodome 3.21.0** 同进程双向对拍（随机 key/IV/明文长度/AAD/mac_len）；
  ③ 最后比错误路径与 API 形状（异常类型与文案、block_size/key_size、
     缺实现的模式必须**明确报错**而不是静默算错）。
实测性能（纯 Python）：AES-GCM 256B ≈ 2.2ms、3DES 64B ≈ 6.1ms —— 解密钥串/签名无感。

未覆盖的（遇到再补）：
  · AES 的 CCM / EAX / SIV / OCB（AEAD 家族里剩下的）
  · DES / 3DES 的 CTR / EAX / OPENPGP 模式
  · 其它算法：ChaCha20 / RC4 / Blowfish / CAST 等
  · 带口令的加密私钥（PEM + passphrase）
  · RSA 签名/验签（`Crypto.Signature.pkcs1_15` / `pss`）
刻意不预铺没人用的 API，避免"看着有、其实算错"。
"""

__version__ = '3.21.0'
