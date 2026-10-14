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


# 最近一次 fetch/post 失败的**真实原因**。
#
# 为什么需要（用户 2026-10-14 实测：`AttributeError: 'NoneType' object has
# no attribute 'json'`）：
#   `fetch()` 以前把任何网络异常都吞成 `return None`，源脚本紧接着写
#   `res.json()` 就抛上面那句 —— 用户看到的是一句完全没信息量的废话，
#   真正的原因（域名解析失败 / 超时 / 连接被拒 / 404）一个都没留下。
#   这里把原因记在模块级变量上，由 `spider_runner` 在拼错误时附到消息后面。
LAST_ERROR = ''


def _remember_error(url, exc):
    """记下并打印 fetch 失败的真实原因（不改变返回 None 的兼容行为）。"""
    global LAST_ERROR
    try:
        LAST_ERROR = '{} 请求失败 → {}: {}'.format(
            url, type(exc).__name__, exc)
        print('[base.spider] ' + LAST_ERROR)
    except Exception:  # pragma: no cover - 打印失败也不能影响源脚本
        pass


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
        except Exception as e:
            # 仍然返回 None（大量源脚本靠"判空"做兜底），但**原因不再丢**
            _remember_error(url, e)
            return None

    def post(self, url, data=None, headers=None, timeout=15, **kwargs):
        try:
            import requests
            h = dict(getattr(self, 'headers', None) or {})
            if headers:
                h.update(headers)
            r = requests.post(url, data=data, headers=h, timeout=timeout, **kwargs)
            return Response(r.text, r.status_code, dict(r.headers), r.url)
        except Exception as e:
            _remember_error(url, e)
            return None

    # ── 子类可覆写 ──────────────────────────────────────────
    def init(self, extend=''):
        return None

    def getName(self):
        return getattr(self, '__class__', type(self)).__name__

    def cleanText(self, text):
        """HTML 清洗钩子 —— catvod 基类提供，源脚本常写成
        `pq(self.cleanText(rsp.text))`（如 腾讯视频.py 的 `gethtml()`）。

        ⚠️ **必须保留标签**：`pq()` 靠标签选择器取数据，把标签删掉源就什么都抓不到。
        所以这里只做"对解析无影响"的安全清洗：去 HTML 注释、去零宽/空字符、
        把连续空白压成一个空格（HTML 里空白本来不敏感）。
        没有这个方法时，源会直接挂
        `AttributeError: 'Spider' object has no attribute 'cleanText'`
        （用户 2026-10-14 给的腾讯视频源就卡在这一步）。
        """
        if not text:
            return ''
        try:
            import re
            t = re.sub(r'<!--.*?-->', ' ', text, flags=re.S)
            t = t.replace('\x00', '')
            t = re.sub(r'[\r\n\t\f\v]+', ' ', t)
            t = re.sub(r' {2,}', ' ', t)
            return t
        except Exception:
            # 清洗只是优化，绝不能因为它让源报错
            return text

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
