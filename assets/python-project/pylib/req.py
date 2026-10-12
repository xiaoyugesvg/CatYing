# -*- coding: utf-8 -*-
"""
pylib/req.py —— Python 源通用请求工具
--------------------------------------
给源脚本提供与 TVBox drpy 生态接近的 `req()` 能力：
  - 纯 Python 三件套（requests/httpx）实现，无 C 扩展依赖；
  - 自动按响应 charset 转 UTF-8（与项目网络层口径一致）；
  - 透传 UA/Cookie/Referer/超时。
"""

import requests

DEFAULT_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
              "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
              "Mobile/15E148 Safari/604.1")

_default_session = None


def _session():
    global _default_session
    if _default_session is None:
        s = requests.Session()
        s.headers.update({"User-Agent": DEFAULT_UA})
        _default_session = s
    return _default_session


def req(url, method="GET", timeout=15, headers=None, cookies=None,
        data=None, params=None, referer=None, encoding=None, **kwargs):
    """通用请求，返回响应文本（按 charset 转 UTF-8）。

    参数对齐 drpy 常用形态：url/method/headers/cookies/data/params。
    referer 单独拆出便于防盗链源写起来直观。
    """
    sess = _session()
    hdrs = dict(sess.headers)
    if headers:
        hdrs.update(headers)
    if referer:
        hdrs["Referer"] = referer
    resp = sess.request(
        method=method.upper(),
        url=url,
        timeout=timeout,
        headers=hdrs,
        cookies=cookies,
        data=data,
        params=params,
        **kwargs,
    )
    resp.raise_for_status()
    if encoding:
        resp.encoding = encoding
    elif resp.encoding is None or resp.encoding.lower() in ("iso-8859-1", "ascii"):
        resp.encoding = resp.apparent_encoding or "utf-8"
    return resp.text


def req_json(url, method="GET", timeout=15, headers=None, **kwargs):
    """请求并解析 JSON（解析失败抛异常）。"""
    import json
    text = req(url, method=method, timeout=timeout, headers=headers, **kwargs)
    return json.loads(text)


def req_bytes(url, timeout=15, headers=None, **kwargs):
    """请求原始字节（图片/二进制），返回 bytes。"""
    sess = _session()
    hdrs = dict(sess.headers)
    if headers:
        hdrs.update(headers)
    resp = sess.get(url, timeout=timeout, headers=hdrs, **kwargs)
    resp.raise_for_status()
    return resp.content


def post(url, data=None, json=None, timeout=15, headers=None, **kwargs):
    """POST 快捷方式。"""
    return req(url, method="POST", data=data, json=json,
               timeout=timeout, headers=headers, **kwargs)
