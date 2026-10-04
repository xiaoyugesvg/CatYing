import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/library_store.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';
import '../../widgets/app_toast.dart';

/// 歌单编辑（本地歌单，**不需要账号**）。
///
/// ── 为什么单独一个文件、且不 import `music_components.dart` ──────
/// `music_components.dart` 要 import 本文件来挂「添加到歌单」入口；
/// 若本文件反过来 import 它取封面组件，就形成**循环依赖**（能用，但很脏）。
/// 所以这里只用一个轻量封面占位，保持方向单一：components → playlist。
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
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: MusicTheme.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
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
                    Icon(Icons.playlist_add_rounded,
                        size: 18, color: MusicTheme.tint),
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
                title: Text('新建歌单',
                    style: TextStyle(color: MusicTheme.label)),
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
                  child: Text('还没有歌单，点上面「新建歌单」',
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontBody)),
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
                          title: Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: MusicTheme.label)),
                          subtitle: Text('${p.length} 首',
                              style: TextStyle(
                                  color: MusicTheme.secondary,
                                  fontSize: AppTheme.fontFootnote)),
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
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定')),
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
      // 包整棵 Theme 要动到 Scaffold 的右括号，风险大；这里按最小改动
      // 先把**底色**拉到音乐主题 ✓（同一批次里其余页面用同样做法 ✓）。
      backgroundColor: MusicTheme.background,
      appBar: AppBar(
        title: const Text('我的歌单'),
        actions: [
          IconButton(
            tooltip: '新建歌单',
            icon: const Icon(Icons.add_rounded),
            onPressed: _create,
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _store.revisionProxy,
        builder: (_, __, ___) {
          final lists = _store.playlists;
          if (lists.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.queue_music_rounded,
                        size: 40, color: MusicTheme.secondary),
                    const SizedBox(height: 12),
                    Text(
                      '还没有歌单\n在歌曲右侧菜单里选「添加到歌单」即可新建',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontBody,
                          height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _create,
                      child: const Text('新建歌单'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: lists.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = lists[i];
              return ListTile(
                leading: _PlaylistThumb(count: p.length),
                title: Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: MusicTheme.label)),
                subtitle: Text('${p.length} 首',
                    style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote)),
                onTap: () async {
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PlaylistDetailPage(playlistId: p.id),
                    ),
                  );
                  if (mounted) setState(() {});
                },
                trailing: PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, color: MusicTheme.secondary),
                  onSelected: (v) async {
                    if (v == 'rename') {
                      final name = await _promptName(context,
                          title: '重命名歌单', initial: p.name);
                      if (name == null) return;
                      await _store.renamePlaylist(p.id, name);
                    } else if (v == 'delete') {
                      final ok = await _confirmDelete(context, p.name);
                      if (ok != true) return;
                      await _store.deletePlaylist(p.id);
                      AppToast.show('已删除「${p.name}」', '');
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'delete', child: Text('删除歌单')),
                  ],
                ),
              );
            },
          );
        },
      ),
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
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除')),
      ],
    ),
  );
}

/// 歌单缩略图占位：不引封面组件（见文件头说明），用"曲目数"做成一个小方块。
class _PlaylistThumb extends StatelessWidget {
  const _PlaylistThumb({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: MusicTheme.fill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.queue_music_rounded,
              size: 16, color: MusicTheme.secondary),
          const SizedBox(height: 1),
          Text('$count',
              style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
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
    return ValueListenableBuilder<int>(
      valueListenable: _store.revisionProxy,
      builder: (_, __, ___) {
        final p = _store.playlistById(widget.playlistId);
        if (p == null) {
          // 歌单可能在别处被删了 —— 给明确提示，不要空白页
          return Scaffold(
            appBar: AppBar(title: const Text('歌单')),
            body: Center(
              child: Text('歌单已删除',
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontBody)),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              if (p.songs.isNotEmpty)
                IconButton(
                  tooltip: '播放全部',
                  icon: const Icon(Icons.play_arrow_rounded),
                  onPressed: () => _player.playQueue(p.songs, index: 0),
                ),
            ],
          ),
          body: p.songs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      '这个歌单还没有歌\n在歌曲右侧菜单里选「添加到歌单」',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontBody,
                          height: 1.5),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: p.songs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final s = p.songs[i];
                    final playing =
                        _player.currentSong?.identityKey == s.identityKey;
                    return ListTile(
                      leading: SizedBox(
                        width: 28,
                        child: Text('${i + 1}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: playing
                                    ? MusicTheme.tint
                                    : MusicTheme.secondary,
                                fontSize: AppTheme.fontFootnote)),
                      ),
                      title: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: playing ? MusicTheme.tint : MusicTheme.label,
                          fontWeight:
                              playing ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      subtitle: Text(s.artists,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: MusicTheme.secondary,
                              fontSize: AppTheme.fontFootnote)),
                      onTap: () => _player.playQueue(p.songs, index: i),
                      trailing: IconButton(
                        tooltip: '移出歌单',
                        icon: Icon(Icons.remove_circle_outline,
                            size: 20, color: MusicTheme.secondary),
                        onPressed: () async {
                          await _store.removeFromPlaylist(p.id, s);
                          if (!mounted) return;
                          AppToast.show('已移出「${s.name}」', '');
                        },
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
