# -*- coding: utf-8 -*-
"""src/spider/video —— T3 Python 视频源目录。

源文件规范（对齐 TVBox/drpy 生态）：
  1. 模块级 `spider_name`（显示名）、`spider_type`（1=单视频，0=多视频）；
  2. 提供五个方法（模块级函数，或 `class Spider` 的实例方法，二选一均可）：
       home(filter=False) -> {"class":[{type_id,type_name}], "list":[vod...]}
       category(tid, pg=1, filter=False, extend=None) -> {"page","pagecount","list"}
       detail(ids) -> {"list":[vod...]}
       search(wd, quick=False, pg=1) -> {"list":[vod...]}
       play(flag, id, flags=None) -> {"parse":0, "playUrl":url, "header":{}}
  3. vod 字段用 TVBox 蛇形：vod_id/vod_name/vod_pic/vod_remarks/vod_play_from/vod_play_url
"""
