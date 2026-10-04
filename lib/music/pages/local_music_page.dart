import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';
import '../../widgets/app_toast.dart';

/// 本地音乐 —— 已下载的歌（App 沙盒 `Documents/music/`）。
///
/// ── 这个页面为什么和"下载进度"是同一个页面 ─────────────────────
/// 下载的三种状态（排队/下载中/失败）和"已完成"对用户来说就是**一个列表**：
/// 他在意的只是"这几首好了没"。分成"下载管理页 + 本地音乐页"反而要来回切。
///
/// 播放走的是 `player_manager` 的**本地优先**分支：已下载的歌直接播文件，
/// 不走网络解析（所以离线也能听）。
class LocalMusicPage extends StatefulWidget {
  const LocalMusicPage({super.key});

  @override
  State<LocalMusicPage> createState() => _LocalMusicPageState();
}

class _LocalMusicPageState extends State<LocalMusicPage> {
  final _svc = MusicDownloadService.instance;
  final _player = MusicPlayerManager.instance;

  @override
  void initState() {
    super.initState();
    _svc.init();
  }

  static String _fmtBytes(int b) {
    if (b <= 0) return '0 B';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空下载'),
        content: Text('确定删除全部已下载的 ${_svc.items.length} 首？文件会被删除。'),
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
    if (ok != true) return;
    await _svc.clearAll();
    if (mounted) AppToast.show('已清空下载', '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地音乐'),
        actions: [
          AnimatedBuilder(
            animation: _svc,
            builder: (_, __) => _svc.items.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: '清空全部',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: _confirmClear,
                  ),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _svc,
        builder: (_, __) {
          final items = _svc.items;
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.download_done_rounded,
                        size: 40, color: MusicTheme.secondary),
                    const SizedBox(height: 12),
                    Text(
                      '还没有下载\n在歌曲右侧菜单里选「下载」',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontBody,
                          height: 1.5),
                    ),
                  ],
                ),
              ),
            );
          }

          final done = _svc.localSongs;
          return Column(
            children: [
              // 汇总：首数 + 占用
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                color: MusicTheme.fill,
                child: Text(
                  '已完成 ${done.length} 首 · 共 ${items.length} 条记录 · '
                  '占用 ${_fmtBytes(_svc.totalBytes)}',
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final d = items[i];
                    final s = d.song;
                    final isDone = d.status == MusicDownloadStatus.done;
                    final playing =
                        isDone && _player.currentSong?.identityKey == s.identityKey;
                    final doneIndex =
                        isDone ? done.indexOf(d.song) : -1;
                    return ListTile(
                      leading: SizedBox(
                        width: 30,
                        child: Icon(
                          isDone
                              ? (playing
                                  ? Icons.volume_up_rounded
                                  : Icons.music_note_rounded)
                              : d.status == MusicDownloadStatus.failed
                                  ? Icons.error_outline
                                  : Icons.downloading_rounded,
                          size: 20,
                          color: isDone
                              ? (playing ? MusicTheme.tint : MusicTheme.secondary)
                              : d.status == MusicDownloadStatus.failed
                                  ? Colors.redAccent
                                  : MusicTheme.tint,
                        ),
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
                      subtitle: _subtitle(d),
                      onTap: isDone && doneIndex >= 0
                          ? () => _player.playQueue(done, index: doneIndex)
                          : null,
                      trailing: IconButton(
                        tooltip: '删除',
                        icon: Icon(Icons.delete_outline,
                            size: 20, color: MusicTheme.secondary),
                        onPressed: () async {
                          await _svc.remove(s);
                          if (!mounted) return;
                          AppToast.show('已删除「${s.name}」', '');
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _subtitle(MusicDownload d) {
    final style = TextStyle(
        color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote);
    switch (d.status) {
      case MusicDownloadStatus.done:
        return Text('${d.song.artists.isEmpty ? '' : '${d.song.artists} · '}'
            '${_fmtBytes(d.bytes)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
      case MusicDownloadStatus.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            LinearProgressIndicator(
              // progress < 0 表示服务端没给总长 → 用不确定态
              value: d.progress >= 0 ? d.progress : null,
              minHeight: 3,
              color: MusicTheme.tint,
              backgroundColor: MusicTheme.fill,
            ),
            const SizedBox(height: 4),
            Text(
              d.progress >= 0
                  ? '下载中 ${(d.progress * 100).toStringAsFixed(0)}%'
                  : '下载中 ${_fmtBytes(d.bytes)}',
              style: style,
            ),
          ],
        );
      case MusicDownloadStatus.queued:
        return Text('等待下载…', style: style);
      case MusicDownloadStatus.failed:
        return Text(d.error.isEmpty ? '下载失败' : d.error,
            maxLines: 2, overflow: TextOverflow.ellipsis, style: style);
    }
  }
}
