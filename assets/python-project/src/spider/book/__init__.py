# -*- coding: utf-8 -*-
"""src/spider/book —— Python 书源目录。

源文件规范：
  1. 模块级 `spider_name`；
  2. 四个方法（模块级函数或 class Spider 实例方法）：
       search(keyword, page=1) -> [book...]
       bookInfo(url) -> book dict
       toc(url) -> [chapter...]
       content(url) -> str（正文文本）
  3. book dict 建议字段：name/author/intro/coverUrl/bookUrl/lastChapter/kind
"""
