# -*- coding: utf-8 -*-
"""修正 THEME_UNIFY.md 音乐/阅读两行的表格分隔符。"""
import io

path = r'C:\Users\24647\AppData\Local\Temp\New-Tv\THEME_UNIFY.md'
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    lines = f.readlines()

out = []
fixed = 0
for ln in lines:
    if ln.startswith('| 音乐 |') and '散落文字提示' in ln and '| 待盘点' not in ln:
        ln = ('| 音乐 | `CircularProgressIndicator(color: MusicTheme.tint)`'
              '（5 处：search/library/playlist_detail/discover×2） | '
              '**散落文字提示**（搜索无结果 `discover_page.dart:390-392`、'
              '收藏空 `library_page.dart:143-154`），无统一 EmptyView | '
              '`lastError` ValueNotifier（`player_manager.dart:77`）+ 播放器内友好文案 |\n')
        fixed += 1
    elif ln.startswith('| 阅读 |') and '_buildEmpty' in ln and '| 待盘点' not in ln:
        ln = ('| 阅读 | `CircularProgressIndicator(strokeWidth: 2)`（若干） | '
              '**`_buildEmpty` 私有方法**（`bookshelf_page.dart:2635` 漫画、'
              '`:2982` 图书，图标+文字），其余散落 Text | '
              '`AppToast.show(...)`（download_service 等）+ 部分 SnackBar 混用 |\n')
        fixed += 1
    out.append(ln)

assert fixed == 2, fixed
with io.open(path, 'w', encoding='utf-8', newline='') as f:
    f.writelines(out)
print('FIXED 2 rows')
