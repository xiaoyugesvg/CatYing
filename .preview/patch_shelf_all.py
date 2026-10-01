# -*- coding: utf-8 -*-
"""书架页（bookshelf_page.dart）：加「全部」汇总 chip（聚合所有可见书架条目，仅浏览）。"""
import io

path = r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\reading\pages\bookshelf_page.dart'
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    s = f.read()
eol = '\r\n' if '\r\n' in s else '\n'

def rep(old, new):
    global s
    n = s.count(old)
    assert n == 1, (old[:60], n)
    s = s.replace(old, new)

# A. 顶层：常量 + 条目解析 helper（插在类定义前）
rep(
    "/// 书架页面\nclass BookshelfPage extends StatefulWidget {",
    "/// \"全部\"虚拟书架 id：聚合当前 tab 可见的所有书架条目（仅浏览，不参与移出等管理操作）\n"
    "const String kAllShelfId = '__all__';\n\n"
    "/// 解析书架条目：普通书架直接取；\"全部\"聚合所有书架（漫画 tab 排除本地图书）。\n"
    "/// 供书架页正文两个子组件与选择/移除逻辑共用。\n"
    "List<BookshelfItem> resolveShelfItems(\n"
    "  String shelfId,\n"
    "  BookshelfItemType type, {\n"
    "  bool excludeLocal = false,\n"
    "}) {\n"
    "  final svc = BookshelfService();\n"
    "  if (shelfId != kAllShelfId) return svc.getItemsInShelf(shelfId, type);\n"
    "  final seen = <String>{};\n"
    "  final result = <BookshelfItem>[];\n"
    "  for (final shelf in svc.bookshelves) {\n"
    "    if (excludeLocal && shelf.id == BookshelfService.presetLocal) continue;\n"
    "    for (final item in svc.getItemsInShelf(shelf.id, type)) {\n"
    "      if (seen.add(item.itemId)) result.add(item);\n"
    "    }\n"
    "  }\n"
    "  return result;\n"
    "}\n\n"
    "/// 书架页面\nclass BookshelfPage extends StatefulWidget {",
)

# B. chips 首位插「全部」
rep(
    "        final chips = <Widget>[\n"
    "          for (int i = 0; i < shelves.length; i++)\n"
    "            _buildShelfChip(shelves[i], currentType, isDark),\n"
    "          _buildAddChip(isDark),\n"
    "        ];",
    "        final chips = <Widget>[\n"
    "          _buildAllShelfChip(currentType, isDark),\n"
    "          for (int i = 0; i < shelves.length; i++)\n"
    "            _buildShelfChip(shelves[i], currentType, isDark),\n"
    "          _buildAddChip(isDark),\n"
    "        ];",
)

# B2. 宽度估算：把「全部」chip 计入
rep(
    "              double totalWidth = 0;\n"
    "              for (int i = 0; i < shelves.length; i++) {",
    "              double totalWidth = 0;\n"
    "              {\n"
    "                final allCount = _visibleShelves(_currentTab).fold<int>(\n"
    "                  0,\n"
    "                  (sum, sh) => sum +\n"
    "                      BookshelfService().countInShelf(sh.id, currentType),\n"
    "                );\n"
    "                final allPainter = TextPainter(\n"
    "                  text: const TextSpan(text: '全部', style: textStyle),\n"
    "                  textDirection: TextDirection.ltr,\n"
    "                )..layout();\n"
    "                final numPainter = TextPainter(\n"
    "                  text: TextSpan(text: '$allCount', style: textStyle),\n"
    "                  textDirection: TextDirection.ltr,\n"
    "                )..layout();\n"
    "                totalWidth +=\n"
    "                    chipPadding + allPainter.width + 4 + numPainter.width + spacing;\n"
    "              }\n"
    "              for (int i = 0; i < shelves.length; i++) {",
)

# C. _buildAllShelfChip 方法（插在 _buildShelfChip 前）
rep(
    "  Widget _buildShelfChip(\n"
    "    Bookshelf shelf,\n"
    "    BookshelfItemType currentType,\n"
    "    bool isDark,\n"
    "  ) {",
    "  /// 「全部」书架 chip：聚合所有可见书架条目（仅浏览，样式同普通书架 chip）\n"
    "  Widget _buildAllShelfChip(BookshelfItemType currentType, bool isDark) {\n"
    "    final selected = _currentShelfId == kAllShelfId;\n"
    "    final count = _visibleShelves(_currentTab).fold<int>(\n"
    "      0,\n"
    "      (sum, sh) =>\n"
    "          sum + BookshelfService().countInShelf(sh.id, currentType),\n"
    "    );\n"
    "    return Padding(\n"
    "      key: _shelfChipKey(kAllShelfId),\n"
    "      padding: const EdgeInsets.only(right: 8),\n"
    "      child: GestureDetector(\n"
    "        onTap: () => _switchShelf(kAllShelfId),\n"
    "        child: AnimatedContainer(\n"
    "          duration: const Duration(milliseconds: 200),\n"
    "          curve: Curves.easeOutCubic,\n"
    "          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),\n"
    "          decoration: BoxDecoration(\n"
    "            color: selected\n"
    "                ? JellyTheme.primary\n"
    "                : (isDark ? JellyTheme.cardDark : Colors.white),\n"
    "            borderRadius: BorderRadius.circular(16),\n"
    "            boxShadow: [\n"
    "              BoxShadow(\n"
    "                color: Colors.black.withValues(alpha: 0.05),\n"
    "                blurRadius: 6,\n"
    "                offset: const Offset(0, 2),\n"
    "              ),\n"
    "            ],\n"
    "          ),\n"
    "          alignment: Alignment.center,\n"
    "          child: Row(\n"
    "            mainAxisSize: MainAxisSize.min,\n"
    "            children: [\n"
    "              Text(\n"
    "                '全部',\n"
    "                style: TextStyle(\n"
    "                  fontSize: AppTheme.fontFootnote,\n"
    "                  fontWeight: FontWeight.w600,\n"
    "                  color: selected\n"
    "                      ? Colors.white\n"
    "                      : (isDark ? Colors.white70 : JellyTheme.textSecondary),\n"
    "                ),\n"
    "              ),\n"
    "              const SizedBox(width: 4),\n"
    "              Text(\n"
    "                '$count',\n"
    "                style: TextStyle(\n"
    "                  fontSize: AppTheme.fontCaption,\n"
    "                  color: selected\n"
    "                      ? Colors.white.withValues(alpha: 0.7)\n"
    "                      : (isDark\n"
    "                            ? Colors.white38\n"
    "                            : JellyTheme.textSecondary.withValues(alpha: 0.7)),\n"
    "                  fontWeight: FontWeight.w600,\n"
    "                ),\n"
    "              ),\n"
    "            ],\n"
    "          ),\n"
    "        ),\n"
    "      ),\n"
    "    );\n"
    "  }\n\n"
    "  Widget _buildShelfChip(\n"
    "    Bookshelf shelf,\n"
    "    BookshelfItemType currentType,\n"
    "    bool isDark,\n"
    "  ) {",
)

# D. 切 tab 空书架跳首书架：全部态不跳
rep(
    "    if (BookshelfService().countInShelf(_currentShelfId, newType) == 0) {\n"
    "      _switchShelf(shelves.first.id);\n"
    "    }",
    "    if (_currentShelfId != kAllShelfId &&\n"
    "        BookshelfService().countInShelf(_currentShelfId, newType) == 0) {\n"
    "      _switchShelf(shelves.first.id);\n"
    "    }",
)

# E1. 漫画子组件解析
rep(
    "        final items = BookshelfService().getItemsInShelf(\n"
    "          shelfId,\n"
    "          BookshelfItemType.comic,\n"
    "        );",
    "        final items = resolveShelfItems(\n"
    "          shelfId,\n"
    "          BookshelfItemType.comic,\n"
    "          excludeLocal: true,\n"
    "        );",
)

# E2. 图书子组件解析
rep(
    "        final items = BookshelfService().getItemsInShelf(\n"
    "          shelfId,\n"
    "          BookshelfItemType.book,\n"
    "        );",
    "        final items = resolveShelfItems(\n"
    "          shelfId,\n"
    "          BookshelfItemType.book,\n"
    "        );",
)

# F. 全选：全部态合并
rep(
    "      _selectedItemIds\n"
    "        ..clear()\n"
    "        ..addAll(\n"
    "          BookshelfService()\n"
    "              .getItemsInShelf(_currentShelfId, type)\n"
    "              .map((i) => i.itemId),\n"
    "        );",
    "      _selectedItemIds\n"
    "        ..clear()\n"
    "        ..addAll(\n"
    "          resolveShelfItems(\n"
    "            _currentShelfId,\n"
    "            type,\n"
    "            excludeLocal: _isComicTab,\n"
    "          ).map((i) => i.itemId),\n"
    "        );",
)

# G. 移出：全部态提示
rep(
    "    if (confirmed != true) return;\n"
    "    for (final itemId in _selectedItemIds.toList()) {",
    "    if (confirmed != true) return;\n"
    "    if (_currentShelfId == kAllShelfId) {\n"
    "      ScaffoldMessenger.of(context)\n"
    "        ..hideCurrentSnackBar()\n"
    "        ..showSnackBar(\n"
    "          const SnackBar(\n"
    "            content: Text('「全部」为汇总视图，请进入具体书架后管理'),\n"
    "            duration: Duration(seconds: 2),\n"
    "            behavior: SnackBarBehavior.floating,\n"
    "          ),\n"
    "        );\n"
    "      return;\n"
    "    }\n"
    "    for (final itemId in _selectedItemIds.toList()) {",
)

with io.open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(s)
print('DONE')
