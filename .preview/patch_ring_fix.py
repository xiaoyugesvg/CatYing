# -*- coding: utf-8 -*-
"""收尾修复：
① book_search_page：菜单分类行/已下载行复用 _buildCategoryButton/_buildCircleIcon，删 jelly_sliding_actions import；
② search_page：菜单分类行复用 _buildCategoryButton；
③ jelly_ring_button：删未用变量 sub。"""
import io

def patch(path, pairs):
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        s = f.read()
    for old, new in pairs:
        n = s.count(old)
        assert n == 1, (path, old[:60], n)
        s = s.replace(old, new)
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(s)

# ① book_search_page
patch(r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\reading\pages\book_search_page.dart', [
    # 删 unused import
    ("import '../widgets/jelly_sliding_actions.dart';\n", ""),
    # 菜单分类行：复用 _buildCategoryButton
    (
        "                              // 分类筛选（年份/语言/格式）\n"
        "                              JellyRingMenuRow(\n"
        "                                isDark: isDark,\n"
        "                                label: '分类筛选',\n"
        "                                child: Builder(\n"
        "                                  builder: (ctx2) => InkWell(\n"
        "                                    onTap: () {\n"
        "                                      Navigator.pop(ctx);\n"
        "                                      _openCategorySheet(isDark);\n"
        "                                    },\n"
        "                                    borderRadius: BorderRadius.circular(10),\n"
        "                                    child: Container(\n"
        "                                      padding: const EdgeInsets.symmetric(\n"
        "                                          horizontal: 10, vertical: 6),\n"
        "                                      decoration: BoxDecoration(\n"
        "                                        color: isDark\n"
        "                                            ? Colors.white\n"
        "                                                .withValues(alpha: 0.08)\n"
        "                                            : Colors.black\n"
        "                                                .withValues(alpha: 0.05),\n"
        "                                        borderRadius:\n"
        "                                            BorderRadius.circular(10),\n"
        "                                      ),\n"
        "                                      child: Icon(\n"
        "                                        Icons.tune_rounded,\n"
        "                                        size: 18,\n"
        "                                        color: isDark\n"
        "                                            ? Colors.white70\n"
        "                                            : JellyTheme.textSecondary,\n"
        "                                      ),\n"
        "                                    ),\n"
        "                                  ),\n"
        "                                ),\n"
        "                              ),\n",
        "                              // 分类筛选（年份/语言/格式）\n"
        "                              JellyRingMenuRow(\n"
        "                                isDark: isDark,\n"
        "                                label: '分类筛选',\n"
        "                                child: _buildCategoryButton(isDark),\n"
        "                              ),\n",
    ),
    # 已下载的图书行：复用 _buildCircleIcon
    (
        "                              // 已下载的图书（跳书架）\n"
        "                              JellyRingMenuRow(\n"
        "                                isDark: isDark,\n"
        "                                label: '已下载的图书',\n"
        "                                child: Builder(\n"
        "                                  builder: (ctx2) => InkWell(\n"
        "                                    onTap: () {\n"
        "                                      Navigator.pop(ctx);\n"
        "                                      MainTabController.instance.select(\n"
        "                                        MainTabController.bookshelfTabIndex,\n"
        "                                      );\n"
        "                                    },\n"
        "                                    borderRadius: BorderRadius.circular(10),\n"
        "                                    child: Container(\n"
        "                                      padding: const EdgeInsets.symmetric(\n"
        "                                          horizontal: 10, vertical: 6),\n"
        "                                      decoration: BoxDecoration(\n"
        "                                        color: isDark\n"
        "                                            ? Colors.white\n"
        "                                                .withValues(alpha: 0.08)\n"
        "                                            : Colors.black\n"
        "                                                .withValues(alpha: 0.05),\n"
        "                                        borderRadius:\n"
        "                                            BorderRadius.circular(10),\n"
        "                                      ),\n"
        "                                      child: Icon(\n"
        "                                        Icons.file_download_outlined,\n"
        "                                        size: 18,\n"
        "                                        color: isDark\n"
        "                                            ? Colors.white70\n"
        "                                            : JellyTheme.textSecondary,\n"
        "                                      ),\n"
        "                                    ),\n"
        "                                  ),\n"
        "                                ),\n"
        "                              ),\n",
        "                              // 已下载的图书（跳书架）\n"
        "                              JellyRingMenuRow(\n"
        "                                isDark: isDark,\n"
        "                                label: '已下载的图书',\n"
        "                                child: _buildCircleIcon(\n"
        "                                  isDark: isDark,\n"
        "                                  icon: Icons.file_download_outlined,\n"
        "                                  tooltip: '已下载的图书',\n"
        "                                  onTap: () {\n"
        "                                    Navigator.pop(ctx);\n"
        "                                    MainTabController.instance.select(\n"
        "                                      MainTabController.bookshelfTabIndex,\n"
        "                                    );\n"
        "                                  },\n"
        "                                ),\n"
        "                              ),\n",
    ),
])

# ② search_page：菜单分类行复用 _buildCategoryButton
patch(r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\reading\pages\search_page.dart', [
    (
        "                                // 分类筛选（不支持分类的源置灰）\n"
        "                                JellyRingMenuRow(\n"
        "                                  isDark: isDark,\n"
        "                                  label: '分类筛选',\n"
        "                                  child: Builder(\n"
        "                                    builder: (ctx2) {\n"
        "                                      final source = SourceManager().current;\n"
        "                                      final enabled = source.supportsCategories;\n"
        "                                      final active = _categoryMode;\n"
        "                                      return InkWell(\n"
        "                                        onTap: enabled\n"
        "                                            ? () {\n"
        "                                                Navigator.pop(ctx);\n"
        "                                                _openCategorySheet(isDark);\n"
        "                                              }\n"
        "                                            : () => _toast('该源暂不支持分类筛选'),\n"
        "                                        borderRadius: BorderRadius.circular(10),\n"
        "                                        child: Container(\n"
        "                                          padding: const EdgeInsets.symmetric(\n"
        "                                              horizontal: 10, vertical: 6),\n"
        "                                          decoration: BoxDecoration(\n"
        "                                            color: active\n"
        "                                                ? JellyTheme.primary\n"
        "                                                : (isDark\n"
        "                                                    ? Colors.white\n"
        "                                                        .withValues(alpha: 0.08)\n"
        "                                                    : Colors.black\n"
        "                                                        .withValues(alpha: 0.05)),\n"
        "                                            borderRadius:\n"
        "                                                BorderRadius.circular(10),\n"
        "                                          ),\n"
        "                                          child: Icon(\n"
        "                                            Icons.tune_rounded,\n"
        "                                            size: 18,\n"
        "                                            color: enabled\n"
        "                                                ? (active\n"
        "                                                      ? Colors.white\n"
        "                                                      : (isDark\n"
        "                                                          ? Colors.white70\n"
        "                                                          : JellyTheme\n"
        "                                                              .textSecondary))\n"
        "                                                : (isDark\n"
        "                                                    ? Colors.white24\n"
        "                                                    : Colors.black26),\n"
        "                                          ),\n"
        "                                        ),\n"
        "                                      );\n"
        "                                    },\n"
        "                                  ),\n"
        "                                ),\n",
        "                                // 分类筛选（不支持分类的源置灰）\n"
        "                                JellyRingMenuRow(\n"
        "                                  isDark: isDark,\n"
        "                                  label: '分类筛选',\n"
        "                                  child: _buildCategoryButton(isDark),\n"
        "                                ),\n",
    ),
])

# ③ jelly_ring_button：删未用变量
patch(r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\reading\widgets\jelly_ring_button.dart', [
    (
        "    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;\n"
        "    final sub = isDark\n"
        "        ? Colors.white.withValues(alpha: 0.55)\n"
        "        : JellyTheme.textSecondary;\n"
        "    return Padding(\n"
        "      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),\n",
        "    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;\n"
        "    return Padding(\n"
        "      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),\n",
    ),
])

print('DONE')
