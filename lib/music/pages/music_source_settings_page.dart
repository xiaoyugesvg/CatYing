import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/models.dart';
import '../models/third_party_source.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../widgets/music_sheet.dart';

/// 音乐 → 我的 → 按平台固定源（网易/QQ 等平台各绑几个第三方源）。
///
/// 一个平台可绑**多个**源：播放该平台的歌时按绑定顺序逐个先试，
/// 第一个出地址的直接用（不弹窗）；全失败再回退内置接口 → 全部启用源。
///
/// 绑定关系存 `SettingsStore.platformSourceBindings`（平台 key → 源 id 列表），
/// 播放链路每次都现读，这里改完即刻生效。
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

    final saved = await showMusicSheet<bool>(
      context: context,
      backgroundColor: MusicTheme.card,
      builder: (ctx) => StatefulBuilder(
        // ⚠️ 必须用 StatefulBuilder 的 setSheet 刷新勾选态 ——
        // 调外层页面的 setState 弹层不会重建（复选框"点不动"的坑）。
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('「${p.displayName}」固定源',
                      style: TextStyle(
                          color: MusicTheme.label,
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
                          ? '还没有启用中的第三方源，先去「音乐源管理」导入'
                          : '可勾多个：播放该平台歌曲时按下方顺序逐个先试，全失败回退其它源',
                      style: TextStyle(
                          color: MusicTheme.secondary,
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
                        activeColor: MusicTheme.tint,
                        title: Text(s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: MusicTheme.label,
                                fontSize: AppTheme.fontSubhead)),
                        subtitle: Text(
                            '${s.kindLabel}·${s.quality}',
                            style: TextStyle(
                                color: MusicTheme.secondary,
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
                    style: FilledButton.styleFrom(
                      backgroundColor: MusicTheme.tint,
                      foregroundColor: Colors.white,
                    ),
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
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        // 实底背景（不透明）——透明底会透出下层内容，看起来像"没顶栏、被遮住"
        backgroundColor: MusicTheme.background,
        appBar: AppBar(
          backgroundColor: MusicTheme.background,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text('按平台固定源',
              style: TextStyle(
                  color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
        ),
        // 源管理页增删/启停源后回来要刷新副标题
        body: ValueListenableBuilder<int>(
          valueListenable: ThirdPartySourceStore.instance.revision,
          builder: (context, _, __) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: Text(
                    '绑定后播放该平台的歌会优先用固定源（按顺序逐个试，第一个能播的直接用，不弹窗）；'
                    '不绑定则先走内置接口，拿不到地址再试全部启用源。',
                    style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote)),
              ),
              Material(
                color: MusicTheme.card,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (final p in SongSource.values)
                      ListTile(
                        leading: Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: MusicTheme.tint.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(_iconFor(p),
                              size: 17, color: MusicTheme.tint),
                        ),
                        title: Text(p.displayName,
                            style: TextStyle(
                                color: MusicTheme.label,
                                fontSize: AppTheme.fontHeadline)),
                        subtitle: Text(_boundNames(p),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: MusicTheme.secondary,
                                fontSize: AppTheme.fontFootnote)),
                        trailing: Icon(Icons.chevron_right,
                            size: 18, color: MusicTheme.secondary),
                        onTap: () => _editBindings(p),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
