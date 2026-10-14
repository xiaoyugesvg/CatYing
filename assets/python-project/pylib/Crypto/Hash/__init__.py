# -*- coding: utf-8 -*-
"""pylib/Crypto/Hash —— 摘要算法垫片包（对齐 `from Crypto.Hash import SHA256` 写法）"""

from . import MD5
from . import SHA1
from . import SHA256
from . import SHA512

__all__ = ['MD5', 'SHA1', 'SHA256', 'SHA512']
