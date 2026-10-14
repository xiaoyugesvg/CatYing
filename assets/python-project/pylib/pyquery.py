# -*- coding: utf-8 -*-
"""pylib/pyquery.py —— PyQuery 纯 Python 垫片。

为什么需要：真 pyquery 依赖 lxml（C 扩展），iOS 端 pip --target 装不了。
本垫片基于 BeautifulSoup + soupsieve（纯 Python，bs4 自带）实现爬虫源常用 API：

    from pyquery import PyQuery as pq
    doc = pq(html)                      # 也支持 pq(url='http://...')
    doc('.list li').items()             # 迭代（每个元素仍是 PyQuery）
    x.text() / x.html() / x.attr('href')
    x.find('a') / x('a')                # __call__ = find
    x.eq(0) / x.first() / x.last()
    x.parent() / x.parents(s) / x.children(s) / x.siblings(s)
    x.next() / x.prev() / x.closest(s)
    x.filter(s) / x.not_(s) / x.is_(s)
    x.remove() / x.empty() / x.clone()
    x.each(fn) / x.map(fn)              # fn(i, el) / fn(el) / fn() 均可
    x.hasClass(c) / x.addClass(c) / x.removeClass(c) / x.val()

解析器固定用标准库 html.parser（iOS 没有 lxml）。
"""
import re as _re

import soupsieve as _sv
from bs4 import BeautifulSoup as _BS
from bs4 import Tag as _Tag

__all__ = ['PyQuery', 'pq']

_PARSER = 'html.parser'


def _norm_attr(v):
    """bs4 多值属性（class 等）返回 list，pyquery 一律是字符串。"""
    if isinstance(v, (list, tuple)):
        return ' '.join(str(x) for x in v)
    return v


class PyQuery(object):
    def __init__(self, data=None, selector=None, **kw):
        url = kw.get('url')
        if url:
            import requests
            r = requests.get(url, headers=kw.get('headers'),
                             timeout=kw.get('timeout', 15))
            r.encoding = r.apparent_encoding or 'utf-8'
            data = r.text
        if isinstance(data, PyQuery):
            self._els = list(data._els)
        elif isinstance(data, (list, tuple)):
            self._els = [e for e in data if isinstance(e, _Tag)]
        elif isinstance(data, _Tag):
            self._els = [data]
        else:
            self._els = [_BS('' if data is None else str(data), _PARSER)]
        if selector is not None:
            self._els = self._select(selector, self._els)

    # ── 内部工具 ──────────────────────────────────────────────
    @staticmethod
    def _select(selector, els):
        out = []
        seen = set()
        for el in els:
            try:
                for hit in el.select(selector):
                    if id(hit) not in seen:
                        seen.add(id(hit))
                        out.append(hit)
            except Exception:
                continue
        return out

    @staticmethod
    def _call_user(fn, i, el):
        """each/map 回调参数个数自适应：fn(i, el) / fn(el) / fn()。"""
        try:
            return fn(i, el)
        except TypeError:
            try:
                return fn(el)
            except TypeError:
                return fn()

    # ── 选择 ─────────────────────────────────────────────────
    def __call__(self, selector):
        return self.find(selector)

    def find(self, selector):
        return PyQuery(self._select(selector, self._els))

    def filter(self, selector):
        if callable(selector):
            return PyQuery([e for i, e in enumerate(self._els)
                            if self._call_user(selector, i, PyQuery(e))])
        return PyQuery([e for e in self._els if self._match(e, selector)])

    @staticmethod
    def _match(el, selector):
        try:
            return _sv.match(selector, el)
        except Exception:
            return False

    def not_(self, selector):
        return PyQuery([e for e in self._els if not self._match(e, selector)])

    def is_(self, selector):
        return any(self._match(e, selector) for e in self._els)

    def eq(self, index):
        try:
            return PyQuery([self._els[index]])
        except IndexError:
            return PyQuery([])

    def first(self):
        return self.eq(0)

    def last(self):
        return self.eq(-1)

    def slice(self, start, end=None):
        return PyQuery(self._els[start:end])

    # ── 遍历 ─────────────────────────────────────────────────
    def items(self):
        for e in self._els:
            yield PyQuery([e])

    def each(self, fn):
        for i, e in enumerate(self._els):
            self._call_user(fn, i, PyQuery([e]))
        return self

    def map(self, fn):
        out = []
        for i, e in enumerate(self._els):
            out.append(self._call_user(fn, i, PyQuery([e])))
        return out

    def __iter__(self):
        return self.items()

    def __len__(self):
        return len(self._els)

    def size(self):
        return len(self._els)

    def __getitem__(self, i):
        if isinstance(i, slice):
            return PyQuery(self._els[i])
        return PyQuery([self._els[i]])

    def __bool__(self):
        return bool(self._els)

    def __eq__(self, other):
        return isinstance(other, PyQuery) and self._els == other._els

    def __repr__(self):
        return '<PyQuery[%d]>' % len(self._els)

    # ── 内容 / 属性 ──────────────────────────────────────────
    def text(self):
        return ''.join(e.get_text() for e in self._els)

    def html(self):
        if not self._els:
            return None
        return self._els[0].decode_contents()

    def outerHtml(self):
        if not self._els:
            return None
        return str(self._els[0])

    def val(self):
        return self.attr('value')

    def attr(self, name, value=None, **_kw):
        if value is None:
            if not self._els:
                return None
            return _norm_attr(self._els[0].get(name))
        for e in self._els:
            e[name] = value
        return self

    def removeAttr(self, name):
        for e in self._els:
            if e.has_attr(name):
                del e[name]
        return self

    def hasClass(self, name):
        if not self._els:
            return False
        cls = self._els[0].get('class') or []
        return name in cls

    def addClass(self, name):
        for e in self._els:
            cls = e.get('class') or []
            if name not in cls:
                e['class'] = cls + [name]
        return self

    def removeClass(self, name):
        for e in self._els:
            cls = [c for c in (e.get('class') or []) if c != name]
            e['class'] = cls
        return self

    def toggleClass(self, name):
        return self.removeClass(name) if self.hasClass(name) else self.addClass(name)

    # ── 树操作 ───────────────────────────────────────────────
    def remove(self, selector=None):
        targets = self._els if selector is None else self._select(selector, self._els)
        for e in targets:
            try:
                e.decompose()
            except Exception:
                pass
        return self

    def empty(self):
        for e in self._els:
            e.clear()
        return self

    def clone(self):
        import copy
        return PyQuery([copy.deepcopy(e) for e in self._els])

    # ── 亲属遍历 ─────────────────────────────────────────────
    def parent(self, selector=None):
        out, seen = [], set()
        for e in self._els:
            p = e.parent
            if isinstance(p, _Tag) and id(p) not in seen:
                if selector is None or self._match(p, selector):
                    seen.add(id(p))
                    out.append(p)
        return PyQuery(out)

    def parents(self, selector=None):
        out, seen = [], set()
        for e in self._els:
            for p in e.parents:
                if not isinstance(p, _Tag) or id(p) in seen:
                    continue
                if p.name in ('[document]',):
                    continue
                if selector is None or self._match(p, selector):
                    seen.add(id(p))
                    out.append(p)
        return PyQuery(out)

    def closest(self, selector):
        for e in self._els:
            p = e.parent
            while isinstance(p, _Tag) and p.name != '[document]':
                if self._match(p, selector):
                    return PyQuery([p])
                p = p.parent
        return PyQuery([])

    def children(self, selector=None):
        out = []
        for e in self._els:
            for c in e.children:
                if isinstance(c, _Tag) and (selector is None or self._match(c, selector)):
                    out.append(c)
        return PyQuery(out)

    def siblings(self, selector=None):
        out, seen = [], set()
        for e in self._els:
            for s in list(e.previous_siblings) + list(e.next_siblings):
                if isinstance(s, _Tag) and id(s) not in seen:
                    if selector is None or self._match(s, selector):
                        seen.add(id(s))
                        out.append(s)
        return PyQuery(out)

    def next(self, selector=None):
        out = []
        for e in self._els:
            s = e.find_next_sibling()
            if s is not None and (selector is None or self._match(s, selector)):
                out.append(s)
        return PyQuery(out)

    def nextAll(self, selector=None):
        out = []
        for e in self._els:
            for s in e.find_next_siblings():
                if selector is None or self._match(s, selector):
                    out.append(s)
        return PyQuery(out)

    def prev(self, selector=None):
        out = []
        for e in self._els:
            s = e.find_previous_sibling()
            if s is not None and (selector is None or self._match(s, selector)):
                out.append(s)
        return PyQuery(out)

    def prevAll(self, selector=None):
        out = []
        for e in self._els:
            for s in e.find_previous_siblings():
                if selector is None or self._match(s, selector):
                    out.append(s)
        return PyQuery(out)


pq = PyQuery
