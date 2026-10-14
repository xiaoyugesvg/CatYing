# -*- coding: utf-8 -*-
"""src.spider.img —— 图源 / 漫画源包。

与 `book` 平级，按需注册：源脚本地址经 `psrc_<md5前12位>` 映射后注册为
`src.spider.img.<key>`，调用入口是 `PythonManager.call('img.<key>', method, args)`
（见 `PythonSourcesService.ensureInstalled`）。

源脚本需实现的接口（极简三条）：
    search(keyword, key=None, page=1) -> {"list": [{"id","name","cover"}, ...]}
    detail(id)                        -> {"data": {"name","author","cover","intro"}}
    images(id, index=0)               -> {"list": ["<图片URL>", ...]}

约定：
  · 只返回**纯数据**，不要做排版/分页 UI；
  · 失败就抛异常（spider_runner 会包成 {ok:false,error}，上层会记日志）。
"""
