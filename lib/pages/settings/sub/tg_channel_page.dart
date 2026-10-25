import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../miniapp/pages/mini_app_player_page.dart';
import '../../../services/tg_service.dart';
import '../../../widgets/app_toast.dart';

/// 某个频道内的视频列表
///
/// 数据来自 `/tg` 的 `tgVideos`；播放地址是**本机回环**的 `/tg/stream`，
/// 由 Node 侧把 Range 请求翻成 MTProto 分片（所以能拖进度条）。
class TgChannelPage extends StatefulWidget {
  const TgChannelPage({
    super.key,
    required this.peer,
    this.title = '',
    this.mode = 'login',
  });

  final String peer;
  final String title;

  /// `login` = MTProto（私有群 / 大文件 / 可拖拽）
  /// `public` = t.me 网页（公开频道，不需要登录）
  final String mode;

  @override
  State<TgChannelPage> createState() => _TgChannelPageState();
}

class _TgChannelPageState extends State<TgChannelPage> {
  final TgService _tg = TgService.instance;
  final ScrollController _scroll = ScrollController();

  final List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _more = true;
  String _error = '';
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >
          _scroll.position.maxScrollExtent - 400) {
        _load();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading && _items.isNotEmpty) return;
    if (!_more) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    final r = widget.mode == 'public'
        ? await _tg.publicList(widget.peer, offsetId: _offset)
        : await _tg.videos(widget.peer, offsetId: _offset, limit: 30);
    if (!mounted) return;
    if (r['ok'] == true) {
      final list = (r['items'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      setState(() {
        _items.addAll(list);
        _offset = (r['next'] as num?)?.toInt() ?? 0;
        _more = list.isNotEmpty && _offset > 0;
        _loading = false;
      });
    } else {
      setState(() {
        _loading = false;
        _error = r['error']?.toString() ?? '加载失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        title: Text(
          widget.title.isEmpty ? widget.peer : widget.title,
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        actions: [
          IconButton(
            tooltip: '收藏这个频道',
            icon: const Icon(Icons.bookmark_add_outlined),
            onPressed: () async {
              await _tg.addChannel(
                widget.peer,
                title: widget.title,
                mode: widget.mode,
              );
              if (!mounted) return;
              AppToast.message('已加入 TG 收藏');
            },
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error.isEmpty ? '这个频道里没有视频文件' : _error,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 13)),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _items.length + 1,
      itemBuilder: (context, i) {
        if (i == _items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: _more
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('没有更多了',
                      style:
                          TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
            ),
          );
        }
        return _tile(_items[i]);
      },
    );
  }

  Widget _tile(Map<String, dynamic> it) {
    final title = (it['title'] ?? '').toString();
    final thumb = (it['thumb'] ?? '').toString();
    final dur = (it['duration'] as num?)?.toInt() ?? 0;
    final size = (it['size'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _play(it),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundCard,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 108,
                  height: 62,
                  child: thumb.isEmpty
                      ? Container(
                          color: AppTheme.backgroundTertiary,
                          child: Icon(Icons.movie_outlined,
                              size: 22, color: AppTheme.textTertiary),
                        )
                      : Image.network(
                          _tg.absolute(thumb),
                          fit: BoxFit.cover,
                          cacheWidth: 216,
                          errorBuilder: (_, __, ___) => Container(
                            color: AppTheme.backgroundTertiary,
                            child: Icon(Icons.movie_outlined,
                                size: 22, color: AppTheme.textTertiary),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      [
                        if (dur > 0) _dur(dur),
                        if (size > 0) _size(size),
                      ].join('  ·  '),
                      style:
                          TextStyle(color: AppTheme.textTertiary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Icon(Icons.play_circle_outline,
                  color: AppTheme.accentOnSurface, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  void _play(Map<String, dynamic> it) {
    final rel = (it['url'] ?? '').toString();
    if (rel.isEmpty) {
      AppToast.message('地址为空');
      return;
    }
    Get.to(() => MiniAppPlayerPage(
          url: _tg.absolute(rel),
          title: (it['title'] ?? '').toString(),
        ));
  }

  static String _dur(int s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = s % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final sss = ss.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$sss' : '$mm:$sss';
  }

  static String _size(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }
}
