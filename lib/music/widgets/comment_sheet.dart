import 'package:flutter/material.dart';
import 'package:tvbox/music/widgets/music_sheet.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/common/theme.dart';

/// 歌曲评论弹层。
///
/// ── 复用既有能力，不重复造 ────────────────────────────────────
/// 音乐模块**本来就有** `MusicApi.comments()` 与 `SongComment` 模型
/// （只是没有 UI 入口）。所以这里只做展示与分页，不再另建一套解析。
///
/// ⚠️ 既有 `comments()` **没有 `source` 参数**、只走网易云：
/// 酷狗的歌传进去会拿酷狗的 id 去查网易云 → 必然取不到。
/// 因此调用方必须**先判断平台**（见 `music_components.dart` 的「评论」入口）。
Future<void> showCommentSheet(BuildContext context, Song song) {
  return showMusicSheet<void>(
    context: context,
    backgroundColor: MusicTheme.card,
    isScrollControlled: true,
    builder: (_) => _CommentSheet(song: song),
  );
}

class _CommentSheet extends StatefulWidget {
  const _CommentSheet({required this.song});
  final Song song;

  @override
  State<_CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<_CommentSheet> {
  static const _pageSize = 20;

  final _items = <SongComment>[];
  final _scroll = ScrollController();

  bool _loading = true; // 首屏
  bool _loadingMore = false; // 追加
  bool _hasMore = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final p = _scroll.position;
      if (p.pixels >= p.maxScrollExtent - 160) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      if (_items.isEmpty) _loading = true;
      _loadingMore = true;
    });
    try {
      // ⚠️ 改用带 `ok` 的变体：原来调 `comments()`，它**把失败完全吞掉** ✗ →
      // 接口失败时返回空列表 → 于是显示「还没有评论」✗
      //（把"请求失败"说成了"没有评论" ✓）。现在能分清：
      //   · `ok:false`  → 失败 → 显示错误 + 重试（重试按钮**已经存在**于下面 ✓）
      //   · 空列表      → 真的没有评论 ✓
      final r = await MusicApi.instance.commentsResult(
        widget.song.id,
        limit: _pageSize,
        offset: _items.length,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (!r.ok) {
          _error = r.error.isEmpty ? '评论加载失败' : r.error;
          // ⚠️ **刻意不动 `_hasMore`、也不清空 `_items`** ✓
          //   · 不动 `_hasMore` → 下面的「重试」按钮点了能真的重来 ✓
          //   · 不清 `_items` → 翻页失败时**已加载的评论不会消失** ✓
          //     （原来 `_hasMore = false` + 错误页整页替换 → 翻页一失败，前面
          //      已看到的评论全被换成一张错误页 ✗）
          return;
        }
        _error = ''; // 成功就清掉上一次的错误
        final list = r.list;
        if (list.isEmpty) {
          _hasMore = false;
          return;
        }
        _items.addAll(list);
        if (list.length < _pageSize) _hasMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '$e';
        _hasMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: h * 0.72,
        child: Column(
          children: [
            // 拖拽条
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 34,
              height: 4,
              decoration: BoxDecoration(
                color: MusicTheme.secondary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.mode_comment_outlined,
                      size: 18, color: MusicTheme.tint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '评论 · ${widget.song.name}',
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
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
              strokeWidth: 2.4, color: MusicTheme.tint),
        ),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: MusicTheme.secondary, size: 30),
              const SizedBox(height: 10),
              Text(
                _error,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: MusicTheme.secondary, fontSize: AppTheme.fontBody),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: () {
                  setState(() {
                    _error = '';
                    _hasMore = true;
                  });
                  _load();
                },
                child: Text('重试', style: TextStyle(color: MusicTheme.tint)),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text('还没有评论',
            style: TextStyle(
                color: MusicTheme.secondary, fontSize: AppTheme.fontBody)),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: _items.length + (_loadingMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (_, i) {
        if (i >= _items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: MusicTheme.tint),
              ),
            ),
          );
        }
        return _CommentTile(c: _items[i]);
      },
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.c});
  final SongComment c;

  @override
  Widget build(BuildContext context) {
    final avatar = (c.avatarUrl ?? '').trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipOval(
          child: SizedBox(
            width: 34,
            height: 34,
            child: avatar.isEmpty
                // 没头像就用首字占位，不留空白格（与封面占位同一原则）
                ? Container(
                    color: MusicTheme.fill,
                    alignment: Alignment.center,
                    child: Text(
                      c.user.isEmpty ? '?' : c.user.characters.first,
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontFootnote),
                    ),
                  )
                // ✅ 改用共用的 `CoverImage`（和封面同一条链路）：
                //   · 走 App 的**磁盘缓存 + 浏览器 UA 头** → 不再每次滚动都重新下载 ✗
                //   · 自带占位与失败降级（下面手写的那一套 Hero/占位可以退休了 ✓）
                : CoverImage(url: avatar, size: 34, circle: true),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.user.isEmpty ? '匿名用户' : c.user,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote),
              ),
              const SizedBox(height: 3),
              Text(
                c.content,
                style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontBody,
                    height: 1.35),
              ),
              if (c.likedCount > 0) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.thumb_up_alt_outlined,
                        size: 13, color: MusicTheme.secondary),
                    const SizedBox(width: 4),
                    Text('${c.likedCount}',
                        style: TextStyle(
                            color: MusicTheme.secondary,
                            fontSize: AppTheme.fontFootnote)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
