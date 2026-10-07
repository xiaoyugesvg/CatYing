import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import 'music_sheet.dart';

/// 听书分类内容页的视图切换按钮。
///
/// 点击弹出「列表 / 宫格·2列 / 3列 / 4列 / 5列」选项（中间弹出），
/// 选择写入 [SettingsStore.listenGrid]，按钮图标随当前视图变化。
class ListenViewToggle extends StatelessWidget {
  const ListenViewToggle({super.key});

  static const _options = <(int, String, IconData)>[
    (0, '列表', Icons.view_list_rounded),
    (2, '宫格 · 2 列', Icons.grid_view_rounded),
    (3, '宫格 · 3 列', Icons.grid_on_rounded),
    (4, '宫格 · 4 列', Icons.grid_4x4_rounded),
    (5, '宫格 · 5 列', Icons.apps_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: SettingsStore.instance.listenGrid,
      builder: (_, grid, __) {
        return IconButton(
          tooltip: '视图',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            grid == 0 ? Icons.view_list_rounded : Icons.grid_view_rounded,
            size: 20,
            color: MusicTheme.label,
          ),
          onPressed: () async {
            final picked = await showMusicSheet<int>(
              context: context,
              backgroundColor: MusicTheme.card,
              builder: (ctx) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                      child: Text(
                        '内容视图',
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final (v, label, icon) in _options)
                      ListTile(
                        dense: true,
                        leading: Icon(icon,
                            size: 20,
                            color:
                                grid == v ? MusicTheme.tint : MusicTheme.secondary),
                        title: Text(label,
                            style: TextStyle(color: MusicTheme.label)),
                        trailing: grid == v
                            ? Icon(Icons.check_rounded,
                                color: MusicTheme.tint, size: 20)
                            : null,
                        onTap: () => Navigator.pop(ctx, v),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
            if (picked != null) {
              await SettingsStore.instance.setListenGrid(picked);
            }
          },
        );
      },
    );
  }
}

/// 听书专辑单集列表的视图切换按钮（列表 / 2 列宫格）。
class AlbumViewToggle extends StatelessWidget {
  const AlbumViewToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: SettingsStore.instance.albumGrid,
      builder: (_, grid, __) {
        return IconButton(
          tooltip: '视图',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            grid == 0 ? Icons.view_list_rounded : Icons.grid_view_rounded,
            size: 20,
            color: MusicTheme.label,
          ),
          onPressed: () async {
            final picked = await showMusicSheet<int>(
              context: context,
              backgroundColor: MusicTheme.card,
              builder: (ctx) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                      child: Text(
                        '单集视图',
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final (v, label, icon) in const [
                      (0, '列表', Icons.view_list_rounded),
                      (2, '宫格 · 2 列', Icons.grid_view_rounded),
                    ])
                      ListTile(
                        dense: true,
                        leading: Icon(icon,
                            size: 20,
                            color:
                                grid == v ? MusicTheme.tint : MusicTheme.secondary),
                        title: Text(label,
                            style: TextStyle(color: MusicTheme.label)),
                        trailing: grid == v
                            ? Icon(Icons.check_rounded,
                                color: MusicTheme.tint, size: 20)
                            : null,
                        onTap: () => Navigator.pop(ctx, v),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
            if (picked != null) {
              await SettingsStore.instance.setAlbumGrid(picked);
            }
          },
        );
      },
    );
  }
}

/// 听书专辑单集列表的排序切换按钮（正序 / 倒序）。
class AlbumSortToggle extends StatelessWidget {
  const AlbumSortToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: SettingsStore.instance.albumSortDesc,
      builder: (_, desc, __) {
        return IconButton(
          tooltip: desc ? '倒序（点击切正序）' : '正序（点击切倒序）',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            desc ? Icons.sort_rounded : Icons.swap_vert_rounded,
            size: 20,
            color: desc ? MusicTheme.tint : MusicTheme.label,
          ),
          onPressed: () => SettingsStore.instance
              .setAlbumSortDesc(!desc),
        );
      },
    );
  }
}

/// 定位到当前播放集按钮。
///
/// [enabled] 为 false（没有正在播放的这一集）时置灰不可点。
class AlbumLocateButton extends StatelessWidget {
  const AlbumLocateButton({super.key, required this.onLocate, this.enabled = true});

  final VoidCallback onLocate;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '定位到当前播放集',
      visualDensity: VisualDensity.compact,
      icon: Icon(
        Icons.my_location_rounded,
        size: 20,
        color: enabled ? MusicTheme.label : MusicTheme.secondary.withValues(alpha: 0.4),
      ),
      onPressed: enabled ? onLocate : null,
    );
  }
}
