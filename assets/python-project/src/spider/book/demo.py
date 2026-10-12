# -*- coding: utf-8 -*-
"""
示例 Python 书源：demo
-----------------------
验证链路用（搜索回显 + 固定目录/正文）。真实源替换本文件或新增文件。
"""

spider_name = "Demo书源"


def search(keyword, page=1):
    return [{
        "name": "Python书源:{}".format(keyword),
        "author": "demo",
        "intro": "Python 书源链路验证",
        "coverUrl": "",
        "bookUrl": "book://demo/1",
        "lastChapter": "第1章",
        "kind": "测试",
    }]


def bookInfo(url):
    return {
        "name": "Demo 书籍",
        "author": "demo",
        "intro": "Python 书源详情验证",
        "coverUrl": "",
        "bookUrl": url,
        "lastChapter": "第1章",
        "kind": "测试",
    }


def toc(url):
    return [{"name": "第1章", "url": "content://demo/1"},
            {"name": "第2章", "url": "content://demo/2"}]


def content(url):
    return "这是 Python 书源正文。\n\n来自 {} 的内容。".format(url)
