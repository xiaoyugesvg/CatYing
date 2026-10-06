import 'package:flutter/material.dart';
import 'music_sheet.dart';

import '../models/models.dart';
import '../services/download_service.dart';
import '../services/library_store.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/video_player_pip.dart';

/// 音乐模块的**共用快捷动作**：收藏 / 下载 / 历史。
///
/// ── 为什么要抽出来 ────────────────────────────────────────────
/// 这三件事会被**多处**调用（悬浮播放球、底部迷你播放器、播放页…）。
/// 写在某个 State 里就只有那个控件能用，别处只能复制一遍 ——
/// 所以收在这里做**顶层函数**。
///
/// ⚠️ 这些函数的调用方可能挂在 `MaterialApp.builder` 那一层
/// （在 Navigator **之上**），所以凡是需要 context 的地方
/// **一律用全局 `VideoPlayerPip.navigatorKey`**，不能依赖调用方的 context。

/// 收藏 / 取消收藏。返回操作后是否已收藏。
Future<bool> musicToggleFavorite(Song song) async {
  final on = await MusicLibraryStore.instance.toggleFavorite(song);
  AppToast.show(on ? '已收藏' : '已取消收藏', song.name);
  return on;
}

/// 加入下载（去重、串行、清单持久化都在下载服务里）。
///
/// ⚠️ 提示必须**按真实结果**给：`enqueue()` 对"已在清单里"的歌是**静默忽略**的，
/// 而这里原来**无条件**弹「已加入下载」→ 对一首**已经下好**的歌再点，
/// 仍然说"已加入下载"，用户以为会下第二遍 ✗
Future<void> musicEnqueueDownload(Song song) async {
  final svc = MusicDownloadService.instance;
  await svc.init();
  if (svc.isDownloaded(song)) {
    AppToast.show('这首歌已经下载过了', song.name);
    return;
  }
  // 排队中/下载中的也不重复提示（失败的可重来）
  final exist = svc.bySong(song);
  if (exist != null && exist.status != MusicDownloadStatus.failed) {
    AppToast.show('已在下载队列里', song.name);
    return;
  }
  await svc.enqueue(song);
  AppToast.show('已加入下载', song.name);
}

/// 迷你播放器的**长按快捷条**：收藏 / 历史 / 下载。
///
/// ⚠️ **已确认全项目 0 调用** ✓（`grep showMiniPlayerActions` 只有这个定义本身 ✓）——
/// 迷你播放器的长按快捷条是用户自己实现的（见 `mini_player.dart` ✓），与它无关 ✓。
///
/// 标 `@Deprecated` 而不是直接删除：函数体有 ~120 行 ✗，删除需要**整段精确匹配**
/// （读写之间行号会漂），风险不对称 ✗。真要清掉时：**从这一行到文件末尾整段删除**即可 ✓。
///
/// 为什么走长按而不是摆在底栏：用户要求底栏要**短**（不能比悬浮菜单栏长），
/// 六个键摆不下 —— 所以三个常用键直接摆（⏮⏯⏭），这三个放长按。
@Deprecated('无调用方：迷你播放器长按已用独立实现，本函数待删除')
Future<void> showMiniPlayerActions(Song song) async {
  final ctx = VideoPlayerPip.navigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  await showMusicSheet<void>(
    context: ctx,
    backgroundColor: MusicTheme.card,
    builder: (sheetCtx) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              song.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading:
                Icon(Icons.favorite_border_rounded, color: MusicTheme.tint),
            title: Text('收藏', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              Navigator.pop(sheetCtx);
              musicToggleFavorite(song);
            },
          ),
          ListTile(
            leading: Icon(Icons.history_rounded, color: MusicTheme.tint),
            title: Text('历史', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              Navigator.pop(sheetCtx);
              showRecentSongsSheet();
            },
          ),
          ListTile(
            leading: Icon(Icons.download_rounded, color: MusicTheme.tint),
            title: Text('下载', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              Navigator.pop(sheetCtx);
              musicEnqueueDownload(song);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// 播放历史（= 最近播放）—— 底部弹层，点任意一首从该首开始播。
///
/// 不做成独立页面：一个列表而已，弹层更省一层路由。
Future<void> showRecentSongsSheet() async {
  final store = MusicLibraryStore.instance;
  await store.init();
  final list = List<Song>.of(store.recent);
  final ctx = VideoPlayerPip.navigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  if (list.isEmpty) {
    AppToast.show('还没有播放历史', '');
    return;
  }
  await showMusicSheet<void>(
    context: ctx,
    backgroundColor: MusicTheme.card,
    builder: (sheetCtx) => SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetCtx).size.height * 0.6,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('最近播放 · ${list.length} 首',
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ...list.map((s) => ListTile(
                  dense: true,
                  title: Text(s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: MusicTheme.label)),
                  subtitle: Text(s.artists,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontFootnote)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    MusicPlayerManager.instance
                        .playQueue(list, index: list.indexOf(s));
                  },
                )),
          ],
        ),
      ),
    ),
  );
}
