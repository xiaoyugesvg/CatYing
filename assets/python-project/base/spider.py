# -*- coding: utf-8 -*-
"""base.spider —— catvod 风格 Python 蜘蛛基类（兼容层）。

大量现成的 TVBox `.py` 源以这种写法开头：
    from base.spider import Spider as BaseSpider
    class Spider(BaseSpider): ...
并依赖基类提供：
    · self.fetch(url, headers=...) -> 带 .text 的响应对象
    · 实例化时自动调用子类的 init(extend)（很多源把站点地址写在 init 里）

本模块只补这层**最小可用面**，让这类源能直接跑起来。
"""


class Response(object):
    """极简响应对象：只暴露源脚本常用的 .text / .content / .status_code / .headers / .url。"""

    def __init__(self, text='', status_code=200, headers=None, url=''):
        self.text = text
        self.content = text.encode('utf-8') if isinstance(text, str) else text
        self.status_code = status_code
        self.headers = headers or {}
        self.url = url
        self.ok = 200 <= status_code < 400

    def json(self):
        import json as _json
        return _json.loads(self.text)


class Spider(object):
    """源脚本继承的基类。"""

    host = ''
    headers = {}

    def __init__(self, *args, **kwargs):
        # 子类常把站点初始化写在 init() 里 —— 这里自动调用一次，
        # 与 catvod 框架行为一致（它们的 init 一般带默认参数，无参可调）。
        try:
            self.init()
        except TypeError:
            try:
                self.init('')
            except Exception:
                pass
        except Exception:
            pass

    # ── 网络 ────────────────────────────────────────────────
    def fetch(self, url, headers=None, timeout=15, **kwargs):
        try:
            import requests
            h = dict(getattr(self, 'headers', None) or {})
            if headers:
                h.update(headers)
            r = requests.get(url, headers=h, timeout=timeout, **kwargs)
            return Response(r.text, r.status_code, dict(r.headers), r.url)
        except Exception:
            return None

    def post(self, url, data=None, headers=None, timeout=15, **kwargs):
        try:
            import requests
            h = dict(getattr(self, 'headers', None) or {})
            if headers:
                h.update(headers)
            r = requests.post(url, data=data, headers=h, timeout=timeout, **kwargs)
            return Response(r.text, r.status_code, dict(r.headers), r.url)
        except Exception:
            return None

    # ── 子类可覆写 ──────────────────────────────────────────
    def init(self, extend=''):
        return None

    def getName(self):
        return getattr(self, '__class__', type(self)).__name__

    def localProxy(self, param=''):
        return {}

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False


# catvod 生态里 `BaseSpider` 和 `Spider` 两种名字都有人用
#   from base.spider import Spider as BaseSpider   （剧迷那种）
#   from base.spider import BaseSpider             （肉漫屋这种）
# 统一导出两个名字，指向同一个基类。
BaseSpider = Spider
