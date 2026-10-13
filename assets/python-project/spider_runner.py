# -*- coding: utf-8 -*-
"""
spider_runner.py —— Python spider 源适配层标准入口
=====================================================
被 iOS 侧 PythonBridge 以 `PyImport_ImportModule("spider_runner")` 导入，
随后 Dart 端所有调用都走 `call(module, method, args_json)`。

模块路由（相对本文件所在根目录）：
  - src.spider.video.<源名>    T3 视频源（TVBox/drpy 风格）
  - src.spider.book.<源名>     书源（search/bookInfo/toc/content）

返回值约定：
  - 成功：可 JSON 序列化对象（dict/list/str/int…）→ json.dumps(ensure_ascii=False)
  - 失败：抛异常，由 Swift 侧捕获转 {ok:false, error}
"""

import importlib
import json
import os
import sys
import traceback

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
        return json.dumps({
            "ok": False,
            "error": "{}: {}".format(type(e).__name__, e),
            "trace": traceback.format_exc(),
        }, ensure_ascii=False)


def list_sources():
    """列出已安装的 Python 源（仓库页/调试用）。"""
    import pkgutil
    out = {"video": [], "book": []}
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
    if kind not in ("video", "book"):
        return json.dumps({"ok": False, "error": "kind 必须是 video/book"})
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
