import 'package:flutter/material.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/library_store.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/common/theme.dart';

/// 播放队列管理页（#11）。
///
/// ── 为什么要这一页 ────────────────────────────────────────────
/// 原来 `MusicPlayerManager` **内部有队列**（`_queue`）也有"下一首"，
/// 但用户**看不到完整队列、也不能调整顺序** ——
/// 想知道"接下来播什么"只能一首首听过去。
///
/// ── 交互 ──────────────────────────────────────────────────────
///   · 点某首 → 从这首开始播
///   · 右侧拖动手柄 → 长按拖动调整顺序（`ReorderableListView`）
///   · 左滑 → 删除单首
///   · 右上角 → 清空（**保留正在播的那首**）
///
/// ⚠️ 拖动排序调用 `moveInQueue(from, to)`，它内部按**对象**
/// 重新定位当前下标 —— 否则拖一下"正在播的歌"就会跟丢。
class MusicQueuePage extends StatelessWidget {
  const MusicQueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final player = MusicPlayerManager.instance;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: ListenableBuilder(
          listenable: player,
          builder: (context, _) => Text(
            '播放队列 (${player.queue.length})',
            style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontTitle3),
          ),
        ),
        iconTheme: IconThemeData(color: MusicTheme.label),
        actions: [
          ListenableBuilder(
            listenable: player,
            builder: (context, _) => IconButton(
              tooltip: '清空队列（保留当前播放）',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: player.queue.length <= 1
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: MusicTheme.card,
                          title: Text('清空队列',
                              style: TextStyle(color: MusicTheme.label)),
                          content: Text(
                            '会移除队列里的其它歌曲，'
                            '**正在播放的这首歌会保留**。',
                            style: TextStyle(color: MusicTheme.secondary),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('清空'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) await player.clearQueue();
                    },
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final queue = player.queue;
          if (queue.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.queue_music_rounded,
                      size: 44,
                      color: MusicTheme.secondary.withValues(alpha: 0.5)),
                  const SizedBox(height: 12),
                  Text('队列是空的',
                      style:
                          TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontBody)),
                ],
              ),
            );
          }
          return ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
            itemCount: queue.length,
            // `onReorderItem` 替代已废弃的 `onReorder`。
            //
            // ⚠️ 语义变了：官方说明 onReorderItem **已经**把"被移除项"的下标
            // 修正过（"adjusts the newIndex parameter for a removed item at the
            // oldIndex"），所以这里**不能再手动 -1** ——
            // 否则往下拖会少移一位（旧 onReorder 才需要那个经典 workaround）。
            onReorderItem: (oldIndex, newIndex) {
              player.moveInQueue(oldIndex, newIndex);
            },
            itemBuilder: (context, i) {
              final s = queue[i];
              final playing = i == player.currentIndex;
              return _QueueTile(
                key: ValueKey('q-${s.identityKey}-$i'),
                song: s,
                index: i,
                playing: playing,
                onTap: () => player.playAt(i),
                onRemove: () => player.removeAt(i),
              );
            },
          );
        },
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    super.key,
    required this.song,
    required this.index,
    required this.playing,
    required this.onTap,
    required this.onRemove,
  });

  final Song song;
  final int index;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final fav = MusicLibraryStore.instance.isFavorite(song);
    return Dismissible(
      key: ValueKey('dis-${song.identityKey}-$index'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onRemove(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 18),
        decoration: BoxDecoration(
          // 用调色板的 error 色（MusicTheme 本身没有暴露 error）
          color: MusicTheme.palette.error.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              // 正在播的那首给一层淡色底，一眼能找到
              color: playing
                  ? MusicTheme.tint.withValues(alpha: 0.14)
                  : Colors.transparent,
            ),
            child: Row(
              children: [
                // 播放中显示小喇叭，否则显示序号
                SizedBox(
                  width: 22,
                  child: playing
                      ? Icon(Icons.volume_up_rounded,
                          size: 15, color: MusicTheme.tint)
                      : Text('${index + 1}',
                          style: TextStyle(
                              color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              song.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: playing
                                    ? MusicTheme.tint
                                    : MusicTheme.label,
                                fontSize: AppTheme.fontBody,
                                fontWeight: playing
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (fav)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(Icons.favorite_rounded,
                                  size: 11, color: MusicTheme.tint),
                            ),
                        ],
                      ),
                      Text(
                        song.artists,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote),
                      ),
                    ],
                  ),
                ),
                Text(song.formattedDuration,
                    style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontCaption)),
                // 拖动排序手柄
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(Icons.drag_handle_rounded,
                        size: 20, color: MusicTheme.secondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
