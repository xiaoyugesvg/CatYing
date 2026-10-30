import 'package:flutter/material.dart';
import 'package:tvbox/music/widgets/music_sheet.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/library_store.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_skeleton.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 歌单编辑（本地歌单，**不需要账号**）。
///
/// ── 为什么这里 import 的是 `music_skeleton.dart` 而不是 components ──
/// `music_components.dart` 要 import 本文件来挂「添加到歌单」入口；
/// 若本文件反过来 import 它取骨架组件，就形成**循环依赖**。
/// 所以纯展示的骨架组件放在 `music_skeleton.dart`（不依赖任何页面），
/// 依赖方向保持单向：components → pages → skeleton ✓
///
/// 数据层在 `MusicLibraryStore`（`createPlaylist` / `renamePlaylist` /
/// `deletePlaylist` / `addToPlaylist` / `removeFromPlaylist`），
/// 全部按 `identityKey`(`source-key`) 判重，避免跨平台 id 撞车。

// ============================================================
// 「添加到歌单」弹层（歌曲三点菜单里调用）
// ============================================================

Future<void> showAddToPlaylistSheet(BuildContext context, Song song) async {
  final store = MusicLibraryStore.instance;
  await store.init();
  if (!context.mounted) return;
  return showMusicSheet<void>(
    context: context,
    backgroundColor: MusicTheme.card,
    builder: (ctx) => SafeArea(
      top: false,
      child: ValueListenableBuilder<int>(
        valueListenable: store.revisionProxy,
        builder: (_, __, ___) {
          final lists = store.playlists;
          final inIds = store.playlistIdsContaining(song);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.playlist_add_rounded,
                      size: 18,
                      color: MusicTheme.tint,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '添加到歌单 · ${song.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.add_rounded, color: MusicTheme.tint),
                title: Text('新建歌单', style: TextStyle(color: MusicTheme.label)),
                onTap: () async {
                  final name = await _promptName(ctx, title: '新建歌单');
                  if (name == null) return;
                  final p = await store.createPlaylist(name);
                  await store.addToPlaylist(p.id, song);
                  if (ctx.mounted) Navigator.pop(ctx);
                  AppToast.show('已添加到「${p.name}」', '');
                },
              ),
              if (lists.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                  child: Text(
                    '还没有歌单，点上面「新建歌单」',
                    style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontBody,
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in lists)
                        ListTile(
                          leading: Icon(
                            inIds.contains(p.id)
                                ? Icons.check_circle_rounded
                                : Icons.queue_music_rounded,
                            color: inIds.contains(p.id)
                                ? MusicTheme.tint
                                : MusicTheme.secondary,
                          ),
                          title: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: MusicTheme.label),
                          ),
                          subtitle: Text(
                            '${p.length} 首',
                            style: TextStyle(
                              color: MusicTheme.secondary,
                              fontSize: AppTheme.fontFootnote,
                            ),
                          ),
                          onTap: () async {
                            await store.addToPlaylist(p.id, song);
                            if (!ctx.mounted) return;
                            AppToast.show('已添加到「${p.name}」', '');
                          },
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    ),
  );
}

/// 输入名称对话框（新建/改名共用）。返回去空格后的名字；取消返回 null。
Future<String?> _promptName(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '歌单名称',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  ).whenComplete(ctrl.dispose);
}

// ============================================================
// 歌单列表页
// ============================================================

class PlaylistListPage extends StatefulWidget {
  const PlaylistListPage({super.key});

  @override
  State<PlaylistListPage> createState() => _PlaylistListPageState();
}

class _PlaylistListPageState extends State<PlaylistListPage> {
  final _store = MusicLibraryStore.instance;

  @override
  void initState() {
    super.initState();
    _store.init().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _create() async {
    final name = await _promptName(context, title: '新建歌单');
    if (name == null) return;
    await _store.createPlaylist(name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 🔴 「我的歌单」是 push 到 root Navigator 的 → **不在**
      // `MusicRootView` 的 `Theme(MusicTheme.themeData())` 作用域里 ✗ →
      // 不显式指定的话，页面底色会取**影视侧** AppTheme 的 `scaffoldBackgroundColor`
      //（音乐与影视选不同调色板时一眼就能看出不对 ✗）。
      backgroundColor: MusicTheme.background,
      body: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<int>(
          valueListenable: _store.revisionProxy,
          builder: (_, __, ___) {
            final lists = _store.playlists;
            return Column(
              children: [
                MusicPageHeader(
                  leading: const MusicBackButton(),
                  title: '我的歌单',
                  subtitle: lists.isEmpty
                      ? '本地歌单 · 不需要账号'
                      : '共 ${lists.length} 个歌单 · '
                            '${lists.fold<int>(0, (a, p) => a + p.length)} 首歌',
                  action: MusicRoundAction(
                    icon: Icons.add_rounded,
                    tooltip: '新建歌单',
                    onTap: _create,
                  ),
                ),
                if (lists.isEmpty)
                  Expanded(child: _empty())
                else
                  Expanded(
                    child: ListView.builder(
                      // 底部留白：悬浮播放球会盖住最后一行
                      padding: const EdgeInsets.fromLTRB(0, 6, 0, 120),
                      itemCount: lists.length,
                      itemBuilder: (_, i) => _row(lists[i]),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: MusicTheme.tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.queue_music_rounded,
                size: 30,
                color: MusicTheme.tint,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '还没有歌单',
              style: TextStyle(
                color: MusicTheme.label,
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '在歌曲右侧菜单里选「添加到歌单」即可新建，\n也可以点右上角的 + 直接建一个空歌单。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontFootnote,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(onPressed: _create, child: const Text('新建歌单')),
          ],
        ),
      ),
    );
  }

  Widget _row(MusicPlaylist p) {
    final name = p.name;
    final count = p.length;
    final id = p.id;
    return MusicNavTile(
      icon: Icons.queue_music_rounded,
      title: name,
      subtitle: '$count 首',
      trailing: PopupMenuButton<String>(
        icon: Icon(Icons.more_horiz, size: 20, color: MusicTheme.secondary),
        onSelected: (v) async {
          if (v == 'rename') {
            final next = await _promptName(
              context,
              title: '重命名歌单',
              initial: name,
            );
            if (next == null) return;
            await _store.renamePlaylist(id, next);
          } else if (v == 'delete') {
            final ok = await _confirmDelete(context, name);
            if (ok != true) return;
            await _store.deletePlaylist(id);
            AppToast.show('已删除「$name」', '');
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('重命名')),
          PopupMenuItem(value: 'delete', child: Text('删除歌单')),
        ],
      ),
      onTap: () async {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            settings: const RouteSettings(name: 'music:page'),
            builder: (_) => PlaylistDetailPage(playlistId: id),
          ),
        );
        if (mounted) setState(() {});
      },
    );
  }
}

Future<bool?> _confirmDelete(BuildContext context, String name) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除歌单'),
      content: Text('确定删除「$name」？歌单里的歌不会被删，只是这个歌单没了。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
}

// ============================================================
// 歌单详情页
// ============================================================

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  final _store = MusicLibraryStore.instance;
  final _player = MusicPlayerManager.instance;

  @override
  void initState() {
    super.initState();
    _store.init().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MusicTheme.background,
      body: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<int>(
          valueListenable: _store.revisionProxy,
          builder: (_, __, ___) {
            final p = _store.playlistById(widget.playlistId);
            if (p == null) {
              // 歌单可能在别处被删了 —— 给明确提示，不要空白页
              return Column(
                children: [
                  const MusicPageHeader(
                    leading: MusicBackButton(),
                    title: '歌单',
                    subtitle: '这个歌单已经不存在了',
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '歌单已删除',
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontBody,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                MusicPageHeader(
                  leading: const MusicBackButton(),
                  title: p.name,
                  subtitle: '${p.length} 首 · 本地歌单',
                  action: p.songs.isEmpty
                      ? null
                      : MusicRoundAction(
                          icon: Icons.play_arrow_rounded,
                          tooltip: '播放全部',
                          onTap: () => _player.playQueue(p.songs, index: 0),
                        ),
                ),
                if (p.songs.isEmpty)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          '这个歌单还没有歌\n在歌曲右侧菜单里选「添加到歌单」',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: MusicTheme.secondary,
                            fontSize: AppTheme.fontBody,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  // ── 🔴 必须监听 player（同 ximalaya_album_page 的说明）────
                  // 外层只监听了 `_store.revisionProxy`，而下面 `playing` 读的是
                  // `_player.currentSong` → 点歌后**高亮不刷新** ✗
                  Expanded(
                    child: ListenableBuilder(
                      listenable: _player,
                      builder: (context, _) => ListView.builder(
                        padding: const EdgeInsets.fromLTRB(0, 6, 0, 120),
                        itemCount: p.songs.length,
                        itemBuilder: (_, i) => _row(p, i),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(MusicPlaylist p, int i) {
    final songs = p.songs;
    final s = songs[i];
    final playing = _player.currentSong?.identityKey == s.identityKey;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
      child: Material(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _player.playQueue(songs, index: i),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: playing ? MusicTheme.tint : MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote,
                      fontWeight: playing ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: playing ? MusicTheme.tint : MusicTheme.label,
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: playing
                              ? FontWeight.w600
                              : FontWeight.w500,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        s.artists,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '移出歌单',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.remove_circle_outline,
                    size: 19,
                    color: MusicTheme.secondary,
                  ),
                  onPressed: () async {
                    await _store.removeFromPlaylist(p.id, s);
                    if (!mounted) return;
                    AppToast.show('已移出「${s.name}」', '');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
