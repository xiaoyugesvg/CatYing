import 'package:flutter/material.dart';

import '../../../common/theme.dart';
import '../../../widgets/common_widgets.dart';
import '../../../music/models/models.dart';
import '../../../music/models/third_party_source.dart';
import '../../../music/services/settings_store.dart';
import 'settings_shared.dart';

/// 设置 → 音乐源（按平台绑定第三方源）
///
/// 用户在第三方源管理页导入音源后，到这里按**平台分类**决定：
/// 播放某个平台（网易/QQ/酷狗/…）的歌时，优先用哪几个第三方源。
/// 一个平台可绑**多个**源，播放时按列表顺序逐个先试，全失败再回退其它启用源。
///
/// 绑定关系存 `SettingsStore.platformSourceBindings`（平台 key → 源 id 列表），
/// 这里改完即刻生效（播放链路每次都现读）。
class MusicSourceSettingsPage extends StatefulWidget {
  const MusicSourceSettingsPage({super.key});

  @override
  State<MusicSourceSettingsPage> createState() =>
      _MusicSourceSettingsPageState();
}

class _MusicSourceSettingsPageState extends State<MusicSourceSettingsPage> {
  /// 各平台的展示图标（听书类平台用耳机图标区分）
  IconData _iconFor(SongSource p) => switch (p) {
        SongSource.netease => Icons.music_note_outlined,
        SongSource.qq => Icons.music_note_outlined,
        SongSource.kugou => Icons.music_note_outlined,
        SongSource.ximalaya => Icons.headphones_outlined,
        SongSource.bookan => Icons.headphones_outlined,
        SongSource.ting15 => Icons.headphones_outlined,
      };

  /// 平台已绑定源的名字（按绑定顺序拼成副标题）
  String _boundNames(SongSource p) {
    final ids = SettingsStore.instance.boundSourceIdsFor(p);
    if (ids.isEmpty) return '未绑定（用内置接口 + 全部启用源）';
    final all = ThirdPartySourceStore.instance.all;
    final names = <String>[];
    for (final id in ids) {
      final s = all.where((e) => e.id == id).firstOrNull;
      names.add(s?.name ?? '（已删除）');
    }
    return '固定：${names.join(' → ')}';
  }

  /// 平台绑定多选弹层：勾选的源按**源管理页里的顺序**保存为固定源。
  Future<void> _editBindings(SongSource p) async {
    final store = ThirdPartySourceStore.instance;
    // 只列启用中的源：绑一个被禁用的源没有意义（播放时会被跳过）
    final candidates = store.enabled;
    // 初始勾选 = 当前绑定（过滤掉已删除/已禁用的）
    final selected = SettingsStore.instance
        .boundSourceIdsFor(p)
        .where((id) => candidates.any((s) => s.id == id))
        .toSet();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        // ⚠️ 必须用 StatefulBuilder 的 setSheet 刷新勾选态 ——
        // 调外层页面的 setState 弹层不会重建（复选框"点不动"的坑）。
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('「${p.displayName}」固定源',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      candidates.isEmpty
                          ? '还没有启用中的第三方源，先去音乐 → 我的 → 音乐源导入'
                          : '可勾多个：播放该平台歌曲时按下方顺序逐个先试，全失败回退其它源',
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontFootnote)),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in candidates)
                      CheckboxListTile(
                        value: selected.contains(s.id),
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: AppTheme.accentColor,
                        title: Text(s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontSubhead)),
                        subtitle: Text(
                            '${s.kindLabel}·${s.quality}',
                            style: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: AppTheme.fontCaption)),
                        onChanged: (v) => setSheet(() {
                          if (v ?? false) {
                            selected.add(s.id);
                          } else {
                            selected.remove(s.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('保存',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;
    // 按源管理页里的顺序存（= candidates 的顺序），用户排好的优先级不被打乱
    final ordered = [
      for (final s in candidates)
        if (selected.contains(s.id)) s.id,
    ];
    await SettingsStore.instance.setPlatformSourceBindings(p, ordered);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '音乐源',
      children: [
        SettingsGroup(
          title: '按平台固定第三方源',
          hint: '绑定后播放该平台的歌会优先用固定源（按顺序逐个试）；'
              '不绑定则先走内置接口，拿不到地址再试全部启用源。',
          children: [
            for (final p in SongSource.values)
              SettingsRow(
                icon: _iconFor(p),
                title: p.displayName,
                subtitle: _boundNames(p),
                onTap: () => _editBindings(p),
              ),
          ],
        ),
      ],
    );
  }
}
