# -*- coding: utf-8 -*-
"""pylib/jsonx.py —— 源脚本常用的 JSON 工具（对齐 drpy json 全局形态）。"""

import json
import re


def loads(text, default=None):
    """容错 JSON 解析：失败返回 default（不抛异常，便于源脚本容错）。"""
    if text is None:
        return default
    if isinstance(text, (dict, list)):
        return text
    try:
        return json.loads(text)
    except Exception:
        # 常见脏数据：前导注释 / 尾逗号 / 单引号 / 控制字符
        cleaned = re.sub(r"^\s*//.*?$", "", text, flags=re.M)
        cleaned = re.sub(r",\s*([}\]])", r"\1", cleaned)
        try:
            return json.loads(cleaned)
        except Exception:
            return default


def dumps(obj, **kwargs):
    """JSON 序列化（默认中文不转义）。"""
    kwargs.setdefault("ensure_ascii", False)
    return json.dumps(obj, **kwargs)
