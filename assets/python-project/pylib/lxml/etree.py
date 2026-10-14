# -*- coding: utf-8 -*-
"""pylib/lxml/etree.py —— lxml.etree 纯 Python 垫片。

真 lxml 是 C 扩展，iOS 端装不了。这里用 BeautifulSoup（html.parser）+ 一个
迷你 XPath 求值器实现源脚本最常用的形态：

    from lxml import etree
    tree = etree.HTML(html)
    tree.xpath('//div[contains(@class,"pic")]//img/@src')   → [str, ...]
    tree.xpath('//h1/text()')                               → [str, ...]
    tree.xpath('//a[@class="x"]')                           → [Element, ...]
    el.get('href', '') / el.text / el.text_content() / el.tag / el.xpath(...)

支持的 XPath 子集：
  · // 后代、/ 子代、.// 当前后代、* 通配
  · 谓词：[@attr='v'] / [@attr="v"] / [contains(@attr,'v')] / [contains(@attr,"v")] / [n]
  · 尾步：/@attr、/text()
不支持的写法（遇到会返回空而不是炸）：position() 函数、last()、| 联合、//text() 中间步骤。
"""
import re

from bs4 import BeautifulSoup as _BS
from bs4 import Tag as _Tag

__all__ = ['HTML', 'fromstring', 'tostring', 'Element', '_Element']

_ATTR_EQ = re.compile(r"^@([\w:-]+)\s*=\s*'([^']*)'$")
_ATTR_EQ2 = re.compile(r'^@([\w:-]+)\s*=\s*"([^"]*)"$')
_CONTAINS = re.compile(r"^contains\(\s*@([\w:-]+)\s*,\s*'([^']*)'\s*\)$")
_CONTAINS2 = re.compile(r'^contains\(\s*@([\w:-]+)\s*,\s*"([^"]*)"\s*\)$')
_INDEX = re.compile(r'^\d+$')
_STEP = re.compile(r'^([\w*:-]+)((?:\[[^\]]*\])*)$')


class _Element(object):
    """对 bs4 Tag 的薄包装，对齐 lxml Element 的常用接口。"""

    __slots__ = ('_t',)

    def __init__(self, tag):
        self._t = tag

    # lxml 风格属性读取
    def get(self, key, default=None):
        v = self._t.get(key)
        if isinstance(v, (list, tuple)):
            v = ' '.join(str(x) for x in v)
        return default if v is None else v

    @property
    def text(self):
        # lxml 的 .text 是「第一个文本子节点」，爬虫场景一般想要全文本
        return self._t.get_text()

    def text_content(self):
        return self._t.get_text()

    @property
    def tag(self):
        return self._t.name

    @property
    def attrib(self):
        return {k: (' '.join(v) if isinstance(v, list) else v)
                for k, v in self._t.attrs.items()}

    def xpath(self, path, **_kw):
        return _xpath(self._t, path)

    def findall(self, path):
        return self.xpath(path)

    def find(self, path):
        r = self.xpath(path)
        return r[0] if r else None

    def __iter__(self):
        for c in self._t.children:
            if isinstance(c, _Tag):
                yield _Element(c)

    def __repr__(self):
        return '<Element %s>' % self._t.name


Element = _Element  # 兼容 type hint 写法


def _tokenize(path):
    """'.//div[@class="a"]//img/@src' → [('//','div[@class="a"]'),('//','img'),('/','@src')]"""
    path = path.strip()
    if path.startswith('.'):
        path = path[1:]
    toks = []
    i, n = 0, len(path)
    axis = '//'
    while i < n:
        if path.startswith('//', i):
            axis, i = '//', i + 2
        elif path[i] == '/':
            axis, i = '/', i + 1
        j, depth = i, 0
        while j < n:
            c = path[j]
            if c == '[':
                depth += 1
            elif c == ']':
                depth -= 1
            elif c == '/' and depth == 0:
                break
            j += 1
        step = path[i:j].strip()
        if step:
            toks.append((axis, step))
        i = j
    return toks


def _pred_ok(tag, pred):
    pred = pred.strip()
    m = _ATTR_EQ.match(pred) or _ATTR_EQ2.match(pred)
    if m:
        v = tag.get(m.group(1))
        if isinstance(v, list):
            v = ' '.join(v)
        return v == m.group(2)
    m = _CONTAINS.match(pred) or _CONTAINS2.match(pred)
    if m:
        v = tag.get(m.group(1))
        if v is None:
            return False
        if isinstance(v, list):
            v = ' '.join(v)
        return m.group(2) in v
    # 不认识的谓词（last()/position() 等）：宽松放行，宁可多匹配不可空
    return True


def _step(ctx, axis, step):
    m = _STEP.match(step)
    if not m:
        return []
    name = m.group(1)
    preds = re.findall(r'\[([^\]]*)\]', m.group(2))
    idx = None
    real = []
    for p in preds:
        p = p.strip()
        if _INDEX.match(p):
            idx = int(p)
        else:
            real.append(p)
    want = True if name == '*' else name
    out = []
    for el in ctx:
        cands = (el.find_all(want) if axis == '//'
                 else el.find_all(want, recursive=False))
        for c in cands:
            if all(_pred_ok(c, p) for p in real):
                out.append(c)
    if idx is not None:
        # xpath [n] 语义：同一父元素下的第 n 个匹配（1 起）
        groups = {}
        for c in out:
            groups.setdefault(id(c.parent), []).append(c)
        out = [g[idx - 1] for g in groups.values() if len(g) >= idx]
    return out


def _xpath(root, path):
    toks = _tokenize(path)
    ctx = [root]
    for axis, step in toks:
        if step == 'text()':
            return [el.get_text() for el in ctx]
        if step.startswith('@'):
            out = []
            for el in ctx:
                v = el.get(step[1:])
                if isinstance(v, list):
                    v = ' '.join(v)
                if v is not None:
                    out.append(v)
            return out
        ctx = _step(ctx, axis, step)
    return [_Element(c) for c in ctx]


def HTML(text, parser=None, **_kw):  # noqa: N802（对齐 lxml 命名）
    return _Element(_BS('' if text is None else str(text), 'html.parser'))


def fromstring(text, parser=None, **kw):
    return HTML(text, parser=parser, **kw)


def tostring(el, encoding='unicode', **_kw):
    s = str(el._t if isinstance(el, _Element) else el)
    if encoding in (None, 'unicode', 'unicode', str):
        return s
    return s.encode(str(encoding), errors='replace')


def fromstringlist(seq, parser=None):
    return HTML(''.join(str(x) for x in seq), parser=parser)
