# -*- coding: utf-8 -*-
"""第二批 A1：音乐 5 处整页加载 → AppPageLoading(color: MusicTheme.tint) + 加 import。"""
import io

def process(path, replacements, imp):
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        lines = f.readlines()
    text = ''.join(lines)

    # 1) 替换加载代码
    for old, new in replacements:
        assert text.count(old) == 1, (path, old, text.count(old))
        text = text.replace(old, new)

    # 2) 加 import（最后一个 import 行后）
    lines = text.splitlines(keepends=True)
    last_import = -1
    for i, ln in enumerate(lines):
        if ln.startswith('import '):
            last_import = i
    assert last_import != -1, path
    eol = '\r\n' if lines[last_import].endswith('\r\n') else '\n'
    lines.insert(last_import + 1, imp + eol)
    text = ''.join(lines)

    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text)
    print('patched', path)

L = r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\music\pages'

# 1) library_page.dart
process(
    L + r'\library_page.dart',
    [('return Center(child: CircularProgressIndicator(color: MusicTheme.tint));',
      'return AppPageLoading(color: MusicTheme.tint);')],
    "import '../../widgets/app_page_loading.dart';",
)

# 2) search_page.dart
process(
    L + r'\search_page.dart',
    [('return Center(child: CircularProgressIndicator(color: MusicTheme.tint));',
      'return AppPageLoading(color: MusicTheme.tint);')],
    "import '../../widgets/app_page_loading.dart';",
)

# 3) playlist_detail_page.dart
process(
    L + r'\playlist_detail_page.dart',
    [('? Center(child: CircularProgressIndicator(color: MusicTheme.tint))',
      '? AppPageLoading(color: MusicTheme.tint)')],
    "import '../../widgets/app_page_loading.dart';",
)

# 4) discover_page.dart 两处
process(
    L + r'\discover_page.dart',
    [('      return Center(\n        child: CircularProgressIndicator(color: MusicTheme.tint),\n      );',
      '      return AppPageLoading(color: MusicTheme.tint);'),
     ('          return Center(\n              child: CircularProgressIndicator(color: MusicTheme.tint));',
      '          return AppPageLoading(color: MusicTheme.tint);')],
    "import '../../widgets/app_page_loading.dart';",
)

print('ALL DONE')
