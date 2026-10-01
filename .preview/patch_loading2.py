# -*- coding: utf-8 -*-
"""第二批 A1b：阅读 douban_ranking_page 整页加载 → AppPageLoading(color: JellyTheme.primary)。"""
import io

path = r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\reading\pages\douban_ranking_page.dart'
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    lines = f.readlines()
text = ''.join(lines)

old = '      return const Center(child: CircularProgressIndicator());'
new = '      return AppPageLoading(color: JellyTheme.primary);'
assert text.count(old) == 1, text.count(old)
text = text.replace(old, new)

# 加 import（最后一行 import 后）
lines = text.splitlines(keepends=True)
last_import = -1
for i, ln in enumerate(lines):
    if ln.startswith('import '):
        last_import = i
assert last_import != -1
eol = '\r\n' if lines[last_import].endswith('\r\n') else '\n'
lines.insert(last_import + 1, "import '../../widgets/app_page_loading.dart';" + eol)
text = ''.join(lines)

with io.open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(text)
print('patched douban_ranking_page.dart')
