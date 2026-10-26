// 删掉两个"从未被使用"的 import ✓（analyze 一直报 unused_import ✗）：
// `dart:convert`（:1）· `../models/search_result.dart`（:7）
import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/reading/models/comic.dart';
import 'package:tvbox/reading/source/adapter.dart';
import 'package:tvbox/reading/source/source_manager.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/reading/widgets/jelly_comic_list_tile.dart';
import 'package:tvbox/reading/widgets/jelly_search_bar.dart';
import 'package:tvbox/reading/pages/comic_detail_page.dart';

/// ── 聚搜与复搜（跨所有漫画源聚合搜索）────────────────────────────
/// 参考 cmbok 漫画页引导：
///   · 聚搜：跨所有启用漫画源并发搜索，同一本书聚合去重，标注来源。
///   · 复搜：在聚合结果基础上，按选中源标签（多选组合）二次过滤。
///
/// 交互：顶部搜索框 + 「聚搜 / 复搜」模式切换；
/// 复搜模式结果顶部出现源标签 chips 多选，点选即过滤。
class ComicAggregateSearchPage extends StatefulWidget {
  const ComicAggregateSearchPage({super.key, this.initialKeyword = ''});

  /// 预填关键词（换源时传当前漫画名）—— 进页自动填好并立刻搜索
  final String initialKeyword;

  @override
  State<ComicAggregateSearchPage> createState() =>
      _ComicAggregateSearchPageState();
}

/// 聚合结果条目：同一本书（按书名清洗去重）聚合多个来源的条目
class _AggregateEntry {
  final String key; // 清洗后的书名（去空格/标点/小写）
  final String displayTitle;
  final String? cover;
  final String? author;
  final List<Comic> items; // 各来源条目（至少 1 条）

  _AggregateEntry({
    required this.key,
    required this.displayTitle,
    required this.cover,
    required this.author,
    required this.items,
  });
}

class _ComicAggregateSearchPageState extends State<ComicAggregateSearchPage> {
  final TextEditingController _controller = TextEditingController();

  /// 「搜索源」输入框（空态筛选源标签，参考图 IMG_8406）
  final TextEditingController _sourceSearch = TextEditingController();

  /// 空态选中的单源 id（空 = 聚搜全部源；点击源标签切换）
  String _singleSourceId = '';
  bool _isSearching = false;
  bool _hasSearched = false;
  bool _focusMode = false; // 聚搜(false) / 复搜(true)
  String _keyword = '';

  // 聚合结果
  List<_AggregateEntry> _entries = [];

  // 复搜：源标签多选（空 = 全部显示）
  final Set<String> _selectedSourceIds = {};

  // 每个源的搜索状态（聚搜并发时收集）
  final Map<String, String> _sourceErrors = {};

  static const _titleCleaner = _TitleCleaner();

  @override
  void initState() {
    super.initState();
    // 换源进页：自动填入书名并立刻跨源搜索
    final kw = widget.initialKeyword.trim();
    if (kw.isEmpty) return;
    _controller.text = kw;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search(kw);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _sourceSearch.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) {
      _toast('请输入搜索关键词');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _isSearching = true;
      _hasSearched = true;
      _keyword = kw;
      _entries = [];
      _selectedSourceIds.clear();
      _sourceErrors.clear();
    });

    final allSources = SourceManager().enabledSources.toList();
    // 空态选中单源 → 仅搜该源；否则跨全部源聚搜
    final sources = _singleSourceId.isEmpty
        ? allSources
        : allSources.where((s) => s.id == _singleSourceId).toList();
    final results = <Comic>[];
    final errors = <String, String>{};

    await Future.wait(
      sources.map((src) async {
        try {
          final page = await src.search(kw, page: 0);
          results.addAll(page.items.map(cmangaToComic));
        } catch (e) {
          errors[src.name] = '$e';
        }
      }),
    );

    if (!mounted) return;

    // 聚合去重：按清洗书名分组，保留来源
    final grouped = <String, List<Comic>>{};
    for (final c in results) {
      final key = _titleCleaner.clean(c.title);
      if (key.isEmpty) continue;
      grouped.putIfAbsent(key, () => []).add(c);
    }
    final entries = grouped.entries.map((e) {
      final first = e.value.first;
      return _AggregateEntry(
        key: e.key,
        displayTitle: first.title,
        cover: first.cover,
        author: first.author,
        items: e.value,
      );
    }).toList()
      ..sort((a, b) => a.displayTitle.compareTo(b.displayTitle));

    setState(() {
      _isSearching = false;
      _entries = entries;
      _sourceErrors.addAll(errors);
    });
  }

  /// 复搜过滤后的条目
  List<_AggregateEntry> get _filteredEntries {
    if (_selectedSourceIds.isEmpty) return _entries;
    return _entries.where((e) {
      return e.items.any((c) => _selectedSourceIds.contains(c.sourceId));
    }).toList();
  }

  /// 聚合结果涉及的所有源（复搜 chips 用）
  List<({String id, String name})> get _involvedSources {
    final map = <String, String>{};
    for (final e in _entries) {
      for (final c in e.items) {
        final id = c.sourceId;
        if (id != null && id.isNotEmpty) {
          map.putIfAbsent(
            id,
            () => SourceManager().getSource(id)?.name ?? id,
          );
        }
      }
    }
    return map.entries
        .map((e) => (id: e.key, name: e.value))
        .toList();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('聚搜'),
        actions: [
          // 重新搜索
          IconButton(
            tooltip: '重新搜索',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _isSearching ? null : () => _search(_keyword),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: JellySearchBar(
                    controller: _controller,
                    hintText: '跨所有漫画源搜索',
                    onSubmitted: _search,
                  ),
                ),
                const SizedBox(width: 8),
                // 聚搜 / 复搜 模式切换
                _buildModeToggle(isDark),
              ],
            ),
          ),
          // 复搜模式：源标签 chips 多选过滤
          if (_focusMode && _entries.isNotEmpty)
            _buildSourceFilterChips(isDark),
          // 错误提示条（部分源失败不阻塞结果）
          if (_sourceErrors.isNotEmpty && _entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Text(
                '${_sourceErrors.length} 个源搜索失败：${_sourceErrors.keys.join('、')}',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.orangeAccent : Colors.orange.shade800,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Expanded(child: _buildBody(isDark)),
        ],
      ),
    );
  }

  /// 模式切换：聚搜 / 复搜
  Widget _buildModeToggle(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _modeButton('聚搜', !_focusMode, () => setState(() => _focusMode = false)),
          _modeButton('复搜', _focusMode, () => setState(() => _focusMode = true)),
        ],
      ),
    );
  }

  Widget _modeButton(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? JellyTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : JellyTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 复搜源标签多选 chips
  Widget _buildSourceFilterChips(bool isDark) {
    final sources = _involvedSources;
    if (sources.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          for (final s in sources) ...[
            if (s.id != sources.first.id) const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                setState(() {
                  if (_selectedSourceIds.contains(s.id)) {
                    _selectedSourceIds.remove(s.id);
                  } else {
                    _selectedSourceIds.add(s.id);
                  }
                });
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _selectedSourceIds.contains(s.id)
                      ? JellyTheme.primary
                      : (isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _selectedSourceIds.contains(s.id)
                        ? JellyTheme.primary
                        : JellyTheme.primary.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  s.name,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    fontWeight: FontWeight.w600,
                    color: _selectedSourceIds.contains(s.id)
                        ? Colors.white
                        : JellyTheme.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isSearching) {
      // ⚠️ 这里不能是 `const Center(...)`：`JellyTheme.primary` 是 getter
      //（非常量表达式），放进 const 会报 invalid_constant，并且会连累
      // 整个类的声明解析失败 —— 于是 `search_page.dart` 里
      // `const ComicAggregateSearchPage()` 会跟着报 "isn't a class"。
      return Center(
        child: CircularProgressIndicator(color: JellyTheme.primary),
      );
    }
    if (!_hasSearched) {
      return _buildHint(isDark);
    }
    final entries = _focusMode ? _filteredEntries : _entries;
    if (entries.isEmpty) {
      return _buildEmpty(isDark);
    }
    return RefreshIndicator(
      color: JellyTheme.primary,
      // 结果列表顶部下拉 → 切换为「复搜」模式（参考 cmbok 引导）
      onRefresh: () async {
        if (!_focusMode) {
          setState(() => _focusMode = true);
          _toast('已切换到「复搜」模式：点选源标签组合过滤');
        }
      },
      child: ListView.separated(
        // 与书源换源页同一套间距，两个「换源/聚搜」页面观感一致
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
        final e = entries[index];
        // 展示首选条目（同书多源时选第一个，详情页可换源）
        final comic = e.items.first;
        return JellyComicListTile(
          comic: comic,
          heroTag: comicCoverHeroTag('aggregate', comic),
          showSourceBadge: true,
          onTap: () {
            // 多源条目：优先取另一源的条目进详情（详情页支持换源）
            final target = e.items.length > 1 && e.items[1].sourceId != null
                ? e.items[1]
                : comic;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ComicDetailPage(
                  comic: target,
                  heroTag: comicCoverHeroTag('aggregate', comic),
                ),
              ),
            );
          },
        );
        },
      ),
    );
  }

  /// 初始空态（参考图 IMG_8406）：「搜索源」筛选框 + 全部源标签 +
  /// 底部「输入关键词开始搜索漫画 / 下拉切换复搜」提示。
  /// 点击源标签 = 切换单源搜索（再次点击恢复聚搜全部源）。
  Widget _buildHint(bool isDark) {
    final sources = SourceManager().enabledSources.toList();
    final kw = _sourceSearch.text.trim().toLowerCase();
    final shown = kw.isEmpty
        ? sources
        : sources
            .where((s) => s.name.toLowerCase().contains(kw))
            .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // 搜索源输入框
        JellySearchBar(
          controller: _sourceSearch,
          hintText: '搜索源',
          onChanged: (_) => setState(() {}),
          onCleared: () => setState(() {}),
        ),
        const SizedBox(height: 14),
        // 源标签：点击切换单源搜索
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: shown.map((s) {
            final selected = _singleSourceId == s.id;
            return GestureDetector(
              onTap: () => setState(() {
                _singleSourceId = selected ? '' : s.id;
                _toast(
                  selected
                      ? '已恢复聚搜：跨全部源'
                      : '已切换为单源搜索：${s.name}',
                );
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: selected
                      ? JellyTheme.primary
                      : (isDark
                          ? JellyTheme.cardDark
                          : JellyTheme.primary.withValues(alpha: 0.08)),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  s.name,
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? Colors.white
                        : (isDark
                            ? Colors.white70
                            : JellyTheme.textPrimaryLight),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 48),
        // 底部提示（参考图）
        Center(
          child: Column(
            children: [
              Text(
                '输入关键词开始搜索漫画',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                  color:
                      isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '下拉切换复搜',
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: JellyTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 48,
              color: JellyTheme.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              '没有找到「$_keyword」',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '换个关键词试试，或检查各源是否可用',
              style: TextStyle(fontSize: 13, color: JellyTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书名清洗：去空白/标点/小写，用于跨源聚合去重
class _TitleCleaner {
  const _TitleCleaner();

  String clean(String title) {
    final s = title.replaceAll(RegExp(r'[\s\u3000\u3001\u3002\p{P}]+', unicode: true), '');
    return s.toLowerCase();
  }
}
