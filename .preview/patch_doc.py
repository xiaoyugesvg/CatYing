# -*- coding: utf-8 -*-
"""更新 THEME_UNIFY.md：填空态盘点 + 加统一边界（按行替换，行尾保留）。"""
import io

path = r'C:\Users\24647\AppData\Local\Temp\New-Tv\THEME_UNIFY.md'
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    lines = f.readlines()

out = []
music_row_new = None
reading_row_new = None

for i, ln in enumerate(lines):
    # 音乐行：加载态列已确认，空态待盘点 → 填
    if ln.startswith('| 音乐 |') and '待盘点' in ln:
        ln = ln.replace('| 待盘点 |',
            '**散落文字提示**（搜索无结果 `discover_page.dart:390-392`、收藏空 `library_page.dart:143-154`），无统一 EmptyView |')
        music_row_new = i
    # 阅读行
    elif ln.startswith('| 阅读 |') and '待盘点' in ln:
        ln = ln.replace('| 待盘点 |',
            '**`_buildEmpty` 私有方法**（`bookshelf_page.dart:2635` 漫画、`:2982` 图书，图标+文字），其余散落 Text |')
        reading_row_new = i
    # 建议路径前插入统一边界
    elif ln.startswith('**建议路径**（将来做）：'):
        out.append('**统一边界（用户确认）**：只统一**通用整页级**的加载 / 空态 / 错误提示；各模块**独特加载态保留各自实现**——\n')
        out.append('- 音乐：播放器音源切换加载（`lastError` 展示）、封面/歌曲行占位（`CoverImage._placeholder`）\n')
        out.append('- 阅读：阅读器翻页/章节加载、书源仓库 spinner、封面占位\n')
        out.append('- 影视：播放器缓冲 spinner、海报图占位\n')
        out.append('这些有模块专属语义与视觉，**不并入统一组件**。\n\n')
    out.append(ln)

assert music_row_new is not None, 'music row not found'
assert reading_row_new is not None, 'reading row not found'
print('music row updated:', music_row_new)
print('reading row updated:', reading_row_new)

with io.open(path, 'w', encoding='utf-8', newline='') as f:
    f.writelines(out)
print('DONE')
