# -*- coding: utf-8 -*-
"""
示例 Python 影视源：demo
--------------------------
验证链路用：搜索走 httpbin 回显（不依赖任何影视站点，纯测网络/桥接/超时）。
真实源按 src/spider/video/__init__.py 的规范写即可，替换本文件或新增文件。
"""

spider_name = "DemoPython源"
spider_type = 1


def home(filter=False):
    return {
        "class": [{"type_id": "1", "type_name": "测试分类"}],
        "list": [],
    }


def category(tid, pg=1, filter=False, extend=None):
    return {"page": pg, "pagecount": 1, "list": []}


def search(wd, quick=False, pg=1):
    # 真实请求一次，验证 requests + 网络 + 编码全链路
    from pylib.req import req
    text = req("https://httpbin.org/get?wd={}".format(wd), timeout=15)
    found = "wd" in text and wd in text
    return {
        "list": [{
            "vod_id": "1",
            "vod_name": "搜索结果:{}({})".format(wd, "ok" if found else "no"),
            "vod_pic": "",
            "vod_remarks": "demo",
            "vod_year": "2026",
            "vod_area": "测试",
            "vod_content": "Python 源搜索链路验证：{}".format(text[:80]),
        }],
    }


def detail(ids):
    return {
        "list": [{
            "vod_id": ids,
            "vod_name": "Demo 详情",
            "vod_pic": "",
            "vod_play_from": "demo",
            "vod_play_url": "第1集$https://demo.example.com/1.m3u8",
        }],
    }


def play(flag, id, flags=None):
    return {"parse": 0, "playUrl": id, "header": {}}
