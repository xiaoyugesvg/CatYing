// lib/music/widgets/plugin_source_sheet.dart
//
// 「切换插件源」弹窗 —— 2026-10-21。
//
// 用户 2026-10-21 调整：
//   · 从底部弹窗改成**中间弹窗**
//   · 一行**四列**卡片，图标与文字都居中
//   · 配色/图标样式对齐音乐模块（MusicTheme），不用影视那套 AppTheme
//   · 保留「定位到当前源」和搜索

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

  /// 居中的选择弹窗：返回选中的源 id（取消 → null）
  static Future<String?> show({
    required BuildContext context,
    required List<ThirdPartySource> items,
    required String selectedId,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _locate(scroll: true));
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

  /// 定位：清空搜索词（可选）并滚到当前选中项
  void _locate({bool scroll = false}) {
    if (!scroll) {
      setState(() {
        _keyword = '';
        _searchCtrl.clear();
      });
    }
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
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 60),
      child: Container(
        constraints: BoxConstraints(maxHeight: h * 0.62),
        decoration: BoxDecoration(
          color: MusicTheme.background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题 + 定位 + 关闭
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 6, 6),
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
                    onPressed: () => _locate(),
                    icon: Icon(
                      Icons.my_location_rounded,
                      size: 19,
                      color: MusicTheme.tint,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: MusicTheme.secondary,
                    ),
                  ),
                ],
              ),
            ),
            // 搜索
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 38,
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
                        onChanged: (v) => setState(() => _keyword = v.trim()),
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
            // 插件：一行四列
            Flexible(
              child: list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Text(
                        _keyword.isNotEmpty ? '未找到匹配的插件' : '还没有已启用的插件',
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontSubhead,
                        ),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        mainAxisExtent: 88,
                      ),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _card(list[i]),
                    ),
            ),
          ],
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
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
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
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 图标：与音乐模块的 icon badge 同款（圆角方块 + 主色淡底）
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: MusicTheme.tint.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.extension_rounded,
                size: 18,
                color: MusicTheme.tint,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? MusicTheme.tint : MusicTheme.label,
                fontSize: AppTheme.fontCaption,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
