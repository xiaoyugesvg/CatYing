# -*- coding: utf-8 -*-
"""
spider_runner.py —— Python spider 源适配层标准入口
=====================================================
被 iOS 侧 PythonBridge 以 `PyImport_ImportModule("spider_runner")` 导入，
随后 Dart 端所有调用都走 `call(module, method, args_json)`。

模块路由（相对本文件所在根目录）：
  - src.spider.video.<源名>    T3 视频源（TVBox/drpy 风格）
  - src.spider.book.<源名>     书源（search/bookInfo/toc/content）
  - src.spider.img.<源名>      图源/漫画源（search/detail/images）

返回值约定：
  - 成功：可 JSON 序列化对象（dict/list/str/int…）→ json.dumps(ensure_ascii=False)
  - 失败：抛异常，由 Swift 侧捕获转 {ok:false, error}
"""

import importlib
import json
import os
import sys
import traceback

# pylib 目录直接挂进 sys.path：源脚本写 `from pyquery import PyQuery` /
# `from lxml import etree`（不带 pylib 前缀）时，命中 pylib 里的纯 Python 垫片
# （真 pyquery/lxml 依赖 C 扩展，iOS 装不了）。pylib 与本文件同级。
_PYLIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pylib')
if os.path.isdir(_PYLIB) and _PYLIB not in sys.path:
    sys.path.insert(0, _PYLIB)


# ---- 全局网络兜底：给没写 timeout 的请求补一个默认超时 -------------------
#
# 🔴 为什么必须（用户 2026-10-14 报「Python 引擎已卡死…请重启 App」的**根因**）：
#   源脚本大量写 `requests.get(url)`（**不带 timeout**）。此时 requests 会构造
#   `Timeout(connect=None, read=None)`，urllib3 接着 `socket.create_connection(..., None)`
#   → `sock.settimeout(None)` ⇒ socket read **永久阻塞**。
#   而原生 watchdog 的 `PyThreadState_SetAsyncExc` **只在字节码边界生效**：
#   线程卡在 C 的 socket read 里永远不会回到字节码 ⇒ 中断永远不触发 ⇒
#   Swift 那条串行 `workQueue` 被**永久占住** ⇒ 之后所有 Python 调用
#   （连 `ensureStarted` / `dispose` 都排在它后面）全部无响应 ⇒ "卡死"。
#
#   ⚠️ `socket.setdefaulttimeout()` **治不了** requests：urllib3 会显式
#      `settimeout(None)` 把它覆盖掉。所以直接给 `Session.request` 补默认 timeout
#      —— 这才是真正管用的那一层（`requests.get/post` 内部都走 Session.request）。
#
#   默认值 8s 是**刻意**选的：App 侧 watchdog 预算是 10s、Dart 硬超时 13s，
#   8s 让"没写 timeout 的请求"在 watchdog 之前自己返回 ⇒ 脚本的 try/except
#   接住报错 → 正常返回 → 原生队列解开，用户**不用重启 App**。
#   源脚本自己显式传了 timeout 的，一律尊重它（这里只在没写时补）。
_PY_DEFAULT_TIMEOUT = 8.0
try:
    import requests as _requests

    _orig_session_request = _requests.sessions.Session.request

    def _request_with_default_timeout(self, method, url, **kwargs):
        if kwargs.get('timeout') is None:
            kwargs['timeout'] = _PY_DEFAULT_TIMEOUT
        return _orig_session_request(self, method, url, **kwargs)

    _requests.sessions.Session.request = _request_with_default_timeout
except Exception as _e:  # pragma: no cover - 没有 requests 时静默跳过
    print('[spider_runner] requests 超时兜底未生效: {}'.format(_e))

# 二级兜底：裸 socket / urllib 等没显式设超时的路径。
#
# ⚠️ 这里**必须 ≤ 8s、与上面 requests 同一个数**（原来是 20s，是个坑）：
#   原生 watchdog 预算 10s，若二级兜底给 20s，走 urllib/裸 socket 的源就会
#   "活过"看门狗 —— 看门狗 10s 时标记卡死并把这次调用判失败，但**原生串行队列
#   还被它占着**，要等它 20s 才返回。App 侧若在那之后不再重试，就表现成
#   "永久卡死、必须重启"。现在 8s < 10s，任何网络路径都会在看门狗之前返回。
try:
    import socket as _socket
    _socket.setdefaulttimeout(_PY_DEFAULT_TIMEOUT)
except Exception:  # pragma: no cover
    pass

# 三级兜底：urllib 显式注入 timeout。
#   urllib 默认走 socket 的全局默认（上面已设），但显式注入更稳、语义也更清楚；
#   源自己传了 timeout 的仍然尊重它。
try:
    import urllib.request as _urlreq

    _orig_urlopen = _urlreq.urlopen

    def _urlopen_with_timeout(url, data=None, timeout=None, *a, **kw):
        if timeout is None or timeout is _socket._GLOBAL_DEFAULT_TIMEOUT:
            timeout = _PY_DEFAULT_TIMEOUT
        return _orig_urlopen(url, data=data, timeout=timeout, *a, **kw)

    _urlreq.urlopen = _urlopen_with_timeout
except Exception:  # pragma: no cover
    pass

# ---- 安全基线 ------------------------------------------------------
# iOS 无 fork/exec；把危险通道直接禁用，避免源脚本误用
try:
    os.system = lambda *a, **k: (_ for _ in ()).throw(
        RuntimeError("os.system disabled on iOS"))
    for _name in ("spawnl", "spawnle", "spawnv", "spawnve", "popen",
                  "system", "execl", "execle", "execlp", "execv",
                  "execve", "execvp", "fork", "kill"):
        if hasattr(os, _name):
            setattr(os, _name, None)
except Exception:  # pragma: no cover
    pass

# 黑名单模块：即使源脚本 import 也直接失败
_BLOCKED = {"subprocess", "ctypes", "multiprocessing", "fcntl", "pty",
            "resource", "mmap", "tkinter"}


class _ImportGuard:
    """导入守卫：拦截黑名单模块，给出明确中文错误。

    用 find_spec（Python 3.4+ 标准 meta_path 接口）实现；
    Python 3.12 已移除旧式 find_module/imp，不能用旧接口。
    """

    def find_spec(self, name, path=None, target=None):
        top = name.split(".")[0]
        if top in _BLOCKED:
            raise ImportError(
                "[python-spider] 模块被禁用: {}（iOS 安全限制）".format(top))
        return None


sys.meta_path.insert(0, _ImportGuard())


# ---- 源对象解析 -----------------------------------------------------
# 兼容三种形态：
#   1. 模块级函数（def home(...)/search(...)）
#   2. drpy 风格类（class Spider: 实例方法同名）
#   3. catvod 风格类（class Spider(BaseSpider): homeContent / categoryContent /
#      detailContent / playerContent / searchContent，构造时自动 init(extend)）
_CATVOD_ALIAS = {
    "home": "homeContent",
    "category": "categoryContent",
    "detail": "detailContent",
    "play": "playerContent",
    "search": "searchContent",
}


def _catvod_args(method, args):
    """把统一的 action 参数适配成 catvod 风格方法的形参。"""
    a = dict(args or {})
    if method == "home":
        return {"filter": bool(a.get("filter"))}
    if method == "category":
        return {
            "tid": a.get("tid", ""),
            "pg": a.get("pg", 1),
            "filter": bool(a.get("filter")),
            "extend": a.get("extend", {}) or {},
        }
    if method == "detail":
        ids = a.get("ids")
        if isinstance(ids, str):
            ids = [ids]
        return {"ids": ids or []}
    if method == "play":
        return {
            "flag": a.get("flag", ""),
            "id": a.get("id", ""),
            "vipFlags": a.get("vipFlags", []) or [],
        }
    if method == "search":
        return {
            "key": a.get("wd") or a.get("key") or "",
            "quick": bool(a.get("quick")),
            "pg": a.get("pg", 1),
        }
    return a


def _resolve_target(mod, method):
    if hasattr(mod, "Spider"):
        try:
            inst = mod.Spider()
            if callable(getattr(inst, method, None)):
                return inst
            # catvod 风格：方法名带 Content 后缀，也算可路由
            alias = _CATVOD_ALIAS.get(method)
            if alias and callable(getattr(inst, alias, None)):
                return inst
        except Exception:
            pass
    fn = getattr(mod, method, None)
    if callable(fn):
        return mod
    raise AttributeError("{} 中没有可调用的 {}".format(
        getattr(mod, "__name__", "?"), method))


def call(module, method, args_json):
    """标准入口。module 形如 video.demo / book.demo / runner。"""
    try:
        args = json.loads(args_json) if args_json else {}
        if module == "runner":
            # 运行时管理函数（install/remove/list），直接调 spider_runner 的函数
            fn = globals().get(method)
            if fn is None:
                raise AttributeError("runner 中没有方法 {}".format(method))
            result = fn(**args)
            return result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
        mod = importlib.import_module("src.spider." + module)
        target = _resolve_target(mod, method)
        fn = getattr(target, method, None)
        call_args = args
        if fn is None:
            # catvod 风格：走 xxxContent 别名 + 参数适配
            alias = _CATVOD_ALIAS.get(method)
            fn = getattr(target, alias, None) if alias else None
            if fn is not None:
                call_args = _catvod_args(method, args)
        if not callable(fn):
            raise AttributeError("{} 中没有可调用的 {}".format(
                getattr(mod, "__name__", "?"), method))
        result = fn(**call_args)
        return json.dumps(result, ensure_ascii=False)
    except Exception as e:
        # 返回错误 JSON（Swift 侧拿不到 traceback，拼进 error 方便排查）
        msg = "{}: {}".format(type(e).__name__, e)
        # 附上 base.spider 记下的**真实网络失败原因**。
        # 为什么必须附（用户 2026-10-14）：`fetch()` 失败时返回 None，
        # 源脚本接着 `.json()` 只会抛 "AttributeError: 'NoneType' object has
        # no attribute 'json'" —— 光看这句根本不知道是域名解析失败还是超时还是 404。
        # base.spider 会把原因记在模块级 LAST_ERROR 上，这里取出来拼在末尾。
        try:
            from base import spider as _base_spider
            if getattr(_base_spider, "LAST_ERROR", ""):
                msg += "（真实原因：{}）".format(_base_spider.LAST_ERROR)
        except Exception:
            pass
        return json.dumps({
            "ok": False,
            "error": msg,
            "trace": traceback.format_exc(),
        }, ensure_ascii=False)


def list_sources():
    """列出已安装的 Python 源（仓库页/调试用）。"""
    import pkgutil
    out = {"video": [], "book": [], "img": []}
    for kind in out:
        pkg = importlib.import_module("src.spider." + kind)
        for m in pkgutil.iter_modules(pkg.__path__):
            try:
                mod = importlib.import_module("src.spider.{}.{}".format(kind, m.name))
                name = getattr(mod, "spider_name", None) or m.name
                out[kind].append({"key": m.name, "name": name})
            except Exception:
                continue
    return out


# ---- 运行时源注册（用户从仓库导入的 .py，Dart 侧写入 Documents 后内存注册）----

_import_lock = False


def _load_module(kind, key, code):
    """把源代码编译并注册进 src.spider.<kind>.<key>。

    返回 (ok, message)。已有同名模块会先替换（reload 语义），
    避免 import 缓存导致新代码不生效。
    """
    global _import_lock
    try:
        _import_lock = True
        full = "src.spider.{}.{}".format(kind, key)
        # 校验 key 只含安全字符，防止路径穿越 / 注入
        import re
        if not re.fullmatch(r"[A-Za-z0-9_\-]+", key or ""):
            return (False, "源 key 含非法字符: {}".format(key))
        pkg = importlib.import_module("src.spider." + kind)
        # 从源码构建模块对象（绕过 import 缓存，支持同 key 更新）
        import types
        mod = types.ModuleType(full)
        mod.__package__ = "src.spider." + kind
        mod.__file__ = "<installed-{}>".format(key)
        code_obj = compile(code, "<spider:{}/{}>".format(kind, key), "exec")
        exec(code_obj, mod.__dict__)
        sys.modules[full] = mod
        # 保证包属性可见（pkgutil.iter_modules 依赖 __path__ 文件系统，
        # 内存模块不会出现在文件列表里，但 importlib.import_module 可直接用）
        setattr(pkg, key, mod)
        return (True, "ok")
    except Exception as e:
        return (False, "{}: {}".format(type(e).__name__, e))
    finally:
        _import_lock = False


def install_source(kind, key, code):
    """对外入口：注册/更新一个 Python 源。kind=video|book。"""
    if kind not in ("video", "book", "img"):
        return json.dumps({"ok": False, "error": "kind 必须是 video/book/img"})
    ok, msg = _load_module(kind, key, code)
    return json.dumps({"ok": ok, "message": msg}, ensure_ascii=False)


def remove_source(kind, key):
    """卸载一个源（从 sys.modules 与包属性摘除）。"""
    try:
        import re
        if not re.fullmatch(r"[A-Za-z0-9_\-]+", key or ""):
            return json.dumps({"ok": False, "error": "源 key 含非法字符"})
        full = "src.spider.{}.{}".format(kind, key)
        if full in sys.modules:
            del sys.modules[full]
        pkg = sys.modules.get("src.spider." + kind)
        if pkg is not None and hasattr(pkg, key):
            delattr(pkg, key)
        return json.dumps({"ok": True}, ensure_ascii=False)
    except Exception as e:
        return json.dumps({"ok": False, "error": "{}: {}".format(type(e).__name__, e)},
                          ensure_ascii=False)
