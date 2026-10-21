// lib/music/pages/plugin_explore_page.dart
//
// 「插件发现页」—— 2026-10-21。
//
// 内容本体已抽到 `widgets/plugin_explore_view.dart`（发现页「推荐」Tab 复用），
// 这里只保留独立的页面外壳（AppBar + 刷新）。
//
//   插件 → 榜单分组 + 推荐歌单（按标签） → 点进去看歌曲 → 整列表播放

import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/third_party_source.dart';
import '../theme/music_theme.dart';
import '../widgets/plugin_explore_view.dart';

class PluginExplorePage extends StatefulWidget {
  const PluginExplorePage({super.key, required this.source});

  final ThirdPartySource source;

  @override
  State<PluginExplorePage> createState() => _PluginExplorePageState();
}

class _PluginExplorePageState extends State<PluginExplorePage> {
  /// 刷新时换 key 强制重建内容视图（复用同一份加载逻辑）
  int _generation = 0;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text(
            widget.source.name,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '刷新',
              icon: Icon(Icons.refresh_rounded, color: MusicTheme.tint),
              onPressed: () => setState(() => _generation++),
            ),
          ],
        ),
        body: PluginExploreView(
          key: ValueKey('${widget.source.id}#$_generation'),
          source: widget.source,
        ),
      ),
    );
  }
}
