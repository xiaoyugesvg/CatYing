# -*- coding: utf-8 -*-
"""收藏页（favorites_page.dart）：搜索按钮去掉 tab 数条件，始终显示。"""
import io

path = r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\reading\pages\favorites_page.dart'
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    s = f.read()

def rep(old, new):
    global s
    n = s.count(old)
    assert n == 1, (old[:60], n)
    s = s.replace(old, new)

rep(
    "                                // 右侧只有 1 个搜索按钮（浅灰圆 + 近黑图标）\n"
    "                                if (contentTabs.length >= 2)\n"
    "                                  _buildCircleIcon(\n"
    "                                    isDark: isDark,\n"
    "                                    icon: Icons.search_rounded,\n"
    "                                    tooltip: '搜索',\n"
    "                                    onTap: _openSearch,\n"
    "                                  ),",
    "                                // 右侧只有 1 个搜索按钮（浅灰圆 + 近黑图标）\n"
    "                                _buildCircleIcon(\n"
    "                                  isDark: isDark,\n"
    "                                  icon: Icons.search_rounded,\n"
    "                                  tooltip: '搜索',\n"
    "                                  onTap: _openSearch,\n"
    "                                ),",
)

with io.open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(s)
print('DONE')
