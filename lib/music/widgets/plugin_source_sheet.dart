// lib/music/widgets/plugin_source_sheet.dart
//
// 「切换插件源」弹窗 —— 2026-10-21。
//
// 与影视的源切换面板同款交互：一行两列卡片 + 搜索 + 定位到当前源。
// 配色走音乐模块自己的 MusicTheme（不用影视的 AppTheme 色值）。

import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/third_party_source.dart';
import '../theme/music_theme.dart';

class PluginSourceSheet extends StatefulWidget {
  const PluginSourceSheet({
    super.key,
    required this.items,
    required this.selectedId,
  });

  final List<ThirdPartySource> items;
  final String selectedId;

  /// 便捷弹出：返回选中的源 id（用户没选 / 直接关掉 → null）
  static Future<String?> show({
    required BuildContext context,
    required List<ThirdPartySource> items,
    required String selectedId,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PluginSourceSheet(
        items: items,
        selectedId: selectedId,
      ),
    );
  }

  @override
  State<PluginSourceSheet> createState() => _PluginSourceSheetState();
}

class _PluginSourceSheetState extends State<PluginSourceSheet> {
  final _searchCtrl = TextEditingController();
  String _keyword = '';

  /// 当前选中项的 key：打开时自动滚到它（「定位」）
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.3,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<ThirdPartySource> get _list {
    if (_keyword.isEmpty) return widget.items;
    final kw = _keyword.toLowerCase();
    return widget.items
        .where((e) => e.name.toLowerCase().contains(kw))
        .toList();
  }

  /// 右上角「定位」：清掉搜索词，再滚到当前选中的源。
  void _locateSelected() {
    setState(() {
      _keyword = '';
      _searchCtrl.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.3,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final list = _list;
    return Container(
      decoration: BoxDecoration(
        color: MusicTheme.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: true,
        bottom: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: h * 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖拽指示条
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: MusicTheme.secondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 标题 + 定位
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '切换插件源',
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '定位到当前源',
                      visualDensity: VisualDensity.compact,
                      onPressed: _locateSelected,
                      icon: Icon(
                        Icons.my_location_rounded,
                        size: 19,
                        color: MusicTheme.tint,
                      ),
                    ),
                  ],
                ),
              ),
              // 搜索
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: MusicTheme.fill,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded,
                          size: 18, color: MusicTheme.secondary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          style: TextStyle(
                            color: MusicTheme.label,
                            fontSize: AppTheme.fontHeadline,
                          ),
                          cursorColor: MusicTheme.tint,
                          onChanged: (v) =>
                              setState(() => _keyword = v.trim()),
                          decoration: InputDecoration(
                            isDense: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            hintText: '搜索插件',
                            hintStyle: TextStyle(
                              color: MusicTheme.secondary,
                              fontSize: AppTheme.fontBody,
                            ),
                          ),
                        ),
                      ),
                      if (_keyword.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _searchCtrl.clear();
                            setState(() => _keyword = '');
                          },
                          child: Icon(Icons.cancel,
                              size: 16, color: MusicTheme.secondary),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // 插件卡片：一行两个
              Flexible(
                child: list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            _keyword.isNotEmpty ? '未找到匹配的插件' : '还没有已启用的插件',
                            style: TextStyle(
                              color: MusicTheme.secondary,
                              fontSize: AppTheme.fontSubhead,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        itemCount: (list.length + 1) ~/ 2,
                        itemBuilder: (_, row) {
                          final left = list[row * 2];
                          final right =
                              row * 2 + 1 < list.length ? list[row * 2 + 1] : null;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              children: [
                                Expanded(child: _card(left)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: right == null
                                      ? const SizedBox.shrink()
                                      : _card(right),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(ThirdPartySource s) {
    final selected = s.id == widget.selectedId;
    return GestureDetector(
      key: selected ? _selectedKey : null,
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(s.id),
      child: Container(
        height: 92,
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: selected
              ? MusicTheme.tint.withValues(alpha: 0.12)
              : MusicTheme.card,
          borderRadius: BorderRadius.circular(14),
          border: selected
              ? Border.all(color: MusicTheme.tint, width: 1.2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: MusicTheme.tint.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.extension_rounded,
                      size: 15, color: MusicTheme.tint),
                ),
                const Spacer(),
                if (selected)
                  Icon(Icons.check_circle_rounded,
                      size: 16, color: MusicTheme.tint),
              ],
            ),
            const Spacer(),
            Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: MusicTheme.label,
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '榜单 · 歌单',
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
