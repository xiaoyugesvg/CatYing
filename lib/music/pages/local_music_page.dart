import 'package:flutter/material.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/download_service.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/file_export_service.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 本地音乐 —— 已下载的歌（App 沙盒 `Documents/music/`）。
///
/// ── 这个页面为什么和"下载进度"是同一个页面 ─────────────────────
/// 下载的三种状态（排队/下载中/失败）和"已完成"对用户来说就是**一个列表**：
/// 他在意的只是"这几首好了没"。分成"下载管理页 + 本地音乐页"反而要来回切。
///
/// 播放走的是 `player_manager` 的**本地优先**分支：已下载的歌直接播文件，
/// 不走网络解析（所以离线也能听）。
///
/// ── 2026-10-30 视觉改造（对齐设计稿「墨律」）────────────────────
/// 原来：AppBar 小标题 + 一条灰底汇总条 + 裸 `ListTile` 密列表。
/// 现在：**大标题 + 一行说明**（`MusicPageHeader`）、
///       **三个等分统计格**（`MusicStatRow`）、
///       **圆角卡片行**（和乐库「我的内容」同一套长相）。
/// 为什么去掉 AppBar：它会和下面的大标题**同一个字重复两遍**，
/// 而且高度白占一行；返回入口移到标题左边（`MusicBackButton`），
/// iOS 的侧滑返回仍然可用（`MaterialPageRoute` 自带，不依赖 AppBar）。
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
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
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
      // push 到 root Navigator → 不在 MusicRootView 的 Theme 作用域里，
      // 底色必须显式给音乐主题（同 playlist_page 的说明）。
      backgroundColor: MusicTheme.background,
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          // 🔴 还要监听 **player**：列表里高亮"正在播放"读的是 `_player.currentSong`
          // ✗ → 只监听下载服务的话，**点歌后高亮不会刷新** ✗
          //（`root_view.dart:100` 用的是同一招 `Listenable.merge` ✓）
          animation: Listenable.merge([_svc, _player]),
          builder: (_, __) {
            final items = _svc.items;
            final done = _svc.localSongs;
            final empty = items.isEmpty;
            final busy = items.length - done.length;

            return Column(
              children: [
                MusicPageHeader(
                  leading: const MusicBackButton(),
                  title: '本地音乐',
                  subtitle: empty
                      ? '下载好的歌存在本机 · 离线也能听'
                      : '已下载 ${done.length} 首 · 占用 ${_fmtBytes(_svc.totalBytes)}',
                  action: empty
                      ? null
                      : IconButton(
                          tooltip: '清空全部',
                          icon: Icon(
                            Icons.delete_sweep_outlined,
                            size: 20,
                            color: MusicTheme.secondary,
                          ),
                          onPressed: _confirmClear,
                        ),
                ),
                if (empty)
                  Expanded(child: _emptyState())
                else ...[
                  // 三个等分统计格（设计稿的「数字在上、说明在下」）
                  MusicStatRow(
                    stats: [
                      MusicStat(value: '${done.length}', label: '已完成'),
                      MusicStat(value: '$busy', label: '进行中'),
                      MusicStat(value: _fmtBytes(_svc.totalBytes), label: '占用'),
                    ],
                  ),
                  // 文件位置提示：下载都在 App 沙盒 Documents/music，
                  // Info.plist 已开 UIFileSharingEnabled → 「文件」App 里能直接看到
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.folder_outlined,
                            size: 13,
                            color: MusicTheme.secondary.withValues(alpha: 0.8),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '文件位置：我的 iPhone → 猫影 → music'
                            '（可在「文件」App 查看/导出）',
                            style: TextStyle(
                              color: MusicTheme.secondary.withValues(
                                alpha: 0.75,
                              ),
                              fontSize: AppTheme.fontCaption,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      // 底部留白：悬浮播放球会盖住最后一两行
                      padding: const EdgeInsets.fromLTRB(0, 6, 0, 120),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _row(items[i], done),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _emptyState() {
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
                Icons.download_done_rounded,
                size: 30,
                color: MusicTheme.tint,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '还没有下载',
              style: TextStyle(
                color: MusicTheme.label,
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '在任意歌曲右侧菜单里选「下载」，\n下好的歌会出现在这里，离线也能听。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontFootnote,
                height: 1.55,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行下载记录（圆角卡片）。
  ///
  /// 和乐库的 `MusicNavTile` 同一套长相：图标装在淡色圆角方块里、
  /// 卡片底、右侧动作。区别只在「右侧动作是两个按钮」和「副标题带进度」。
  Widget _row(MusicDownload d, List<Song> done) {
    final s = d.song;
    final isDone = d.status == MusicDownloadStatus.done;
    final failed = d.status == MusicDownloadStatus.failed;
    final playing = isDone && _player.currentSong?.identityKey == s.identityKey;
    // 用 identityKey 找（不用 `indexOf`：Song 的 == 未必按 identityKey 实现）
    final doneIndex = isDone
        ? done.indexWhere((x) => x.identityKey == s.identityKey)
        : -1;

    final icon = isDone
        ? (playing ? Icons.volume_up_rounded : Icons.music_note_rounded)
        : failed
        ? Icons.error_outline_rounded
        : Icons.downloading_rounded;
    final iconColor = isDone
        ? (playing ? MusicTheme.tint : MusicTheme.secondary)
        : failed
        ? const Color(0xFFE05B4A)
        : MusicTheme.tint;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
      child: Material(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: isDone && doneIndex >= 0
              ? () => _player.playQueue(done, index: doneIndex)
              : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 18, color: iconColor),
                ),
                const SizedBox(width: 12),
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
                      _subtitle(d),
                    ],
                  ),
                ),
                if (isDone)
                  IconButton(
                    tooltip: '导出',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.ios_share_rounded,
                      size: 18,
                      color: MusicTheme.secondary,
                    ),
                    onPressed: () => _exportFile(d),
                  ),
                IconButton(
                  tooltip: '删除',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 19,
                    color: MusicTheme.secondary,
                  ),
                  onPressed: () async {
                    await _svc.remove(s);
                    if (!mounted) return;
                    AppToast.show('已删除「${s.name}」', '');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 导出单首已下载歌曲：交给系统分享面板（存到「文件」/ AirDrop 等）。
  Future<void> _exportFile(MusicDownload d) async {
    final ok = await FileExportService.shareFiles([d.path]);
    if (!mounted || ok) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出失败'),
        content: Text(
          '找不到本地文件：\n${d.path}\n\n'
          '也可以直接在「文件」App → 我的 iPhone → 猫影 → music 中查看。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _subtitle(MusicDownload d) {
    final style = TextStyle(
      color: MusicTheme.secondary,
      fontSize: AppTheme.fontCaption,
      height: 1.3,
    );
    switch (d.status) {
      case MusicDownloadStatus.done:
        return Text(
          '${d.song.artists.isEmpty ? '' : '${d.song.artists} · '}'
          '${_fmtBytes(d.bytes)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      case MusicDownloadStatus.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                // progress < 0 表示服务端没给总长 → 用不确定态
                value: d.progress >= 0 ? d.progress : null,
                minHeight: 3,
                color: MusicTheme.tint,
                backgroundColor: MusicTheme.fill,
              ),
            ),
            const SizedBox(height: 3),
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
        return Text(
          d.error.isEmpty ? '下载失败' : d.error,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
    }
  }
}
