import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../miniapp/pages/mini_app_player_page.dart';
import '../../../services/tg_service.dart';
import '../../../services/translate_service.dart';
import '../../../widgets/app_toast.dart';

/// 某个频道内的视频列表
///
/// 2026-10-25 改版（用户要求）：
///   · **一行两个**（网格），不再是通栏长条
///   · **一次只取 12 条**，滚到底再取下一批
///   · 顶部可**切换群组**（收藏的频道 / 账号里的群），不用退回上一页
///
/// 数据来自 `/tg`：登录模式走 `tgVideos`（MTProto，私有群/大文件），
/// 公开模式走 `tgPublicList`（t.me 网页，不用登录）。
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

  /// 当前频道（可在页内切换）
  late String _peer = widget.peer;
  late String _title = widget.title;
  late String _mode = widget.mode;

  final List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _more = true;
  String _error = '';
  int _offset = 0;

  /// 每批条数（用户要求：一次 12 个）
  static const int _pageSize = 12;

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
    final r = _mode == 'public'
        ? await _tg.publicList(_peer, offsetId: _offset)
        : await _tg.videos(_peer, offsetId: _offset, limit: _pageSize);
    if (!mounted) return;
    if (r['ok'] == true) {
      var list = (r['items'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      // 公开频道那条接口一次会给一整页（~20 条），这里自己截到 12 条，
      // 并把「下一页游标」改成**截断后最后一条**的 id —— 否则会漏掉中间 8 条。
      if (_mode == 'public' && list.length > _pageSize) {
        list = list.sublist(0, _pageSize);
      }
      setState(() {
        _items.addAll(list);
        _offset = _mode == 'public'
            ? ((list.isEmpty ? 0 : (list.last['id'] as num).toInt()))
            : ((r['next'] as num?)?.toInt() ?? 0);
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

  // ── 切换群组 ───────────────────────────────────────────
  Future<void> _switchChannel() async {
    final saved = await _tg.channels();
    // 只有登录过才去拉账号里的群（否则白发一次网络请求）
    var dialogs = <Map<String, dynamic>>[];
    final st = await _tg.status();
    if (st['authorized'] == true) {
      final r = await _tg.dialogs();
      dialogs = ((r['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    if (!mounted) return;

    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (c) {
        Widget row(Map<String, dynamic> d) {
          final peer = (d['peer'] ?? '').toString();
          final mode = (d['mode'] ?? 'public').toString();
          final on = peer == _peer;
          return ListTile(
            dense: true,
            leading: Icon(
              mode == 'login' ? Icons.lock_outline : Icons.public,
              size: 19,
              color: on ? AppTheme.accentOnSurface : AppTheme.textTertiary,
            ),
            title: Text(
              (d['title'] ?? peer).toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                color: on ? AppTheme.accentOnSurface : AppTheme.textPrimary,
              ),
            ),
            subtitle: Text(
              '@$peer',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
            ),
            trailing: on
                ? Icon(Icons.check, size: 17, color: AppTheme.accentOnSurface)
                : null,
            onTap: () => Navigator.pop(c, {
              'peer': peer,
              'title': (d['title'] ?? peer).toString(),
              'mode': mode,
            }),
          );
        }

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(c).size.height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.textTertiary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Row(
                    children: [
                      Text('切换群组',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary)),
                      const Spacer(),
                      Text('${saved.length + dialogs.length} 个',
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textTertiary)),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (saved.isNotEmpty) ...[
                        _sheetLabel('收藏的频道'),
                        ...saved.map(row),
                      ],
                      if (dialogs.isNotEmpty) ...[
                        _sheetLabel('账号里的群 / 频道'),
                        ...dialogs.map((d) => row({
                              'peer': d['peer'],
                              'title': d['title'],
                              'mode': 'login',
                            })),
                      ],
                      if (saved.isEmpty && dialogs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 30),
                          child: Center(
                            child: Text('还没有可切换的频道\n先去 TG 分类页收藏一个',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 12,
                                    height: 1.6,
                                    color: AppTheme.textTertiary)),
                          ),
                        ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (picked == null || !mounted) return;
    setState(() {
      _peer = (picked['peer'] ?? _peer).toString();
      _title = (picked['title'] ?? _peer).toString();
      _mode = (picked['mode'] ?? _mode).toString();
      _items.clear();
      _offset = 0;
      _more = true;
      _error = '';
    });
    _load();
  }

  Widget _sheetLabel(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(t,
            style: TextStyle(fontSize: 11, color: AppTheme.textTertiary)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: InkWell(
          onTap: _switchChannel,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _title.isEmpty ? _peer : _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textPrimary, fontSize: 16),
                  ),
                ),
                const SizedBox(width: 3),
                Icon(Icons.expand_more_rounded,
                    size: 19, color: AppTheme.textTertiary),
              ],
            ),
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '切换群组',
            icon: const Icon(Icons.swap_horiz_rounded),
            onPressed: _switchChannel,
          ),
          IconButton(
            tooltip: '收藏这个频道',
            icon: const Icon(Icons.bookmark_add_outlined),
            onPressed: () async {
              await _tg.addChannel(_peer, title: _title, mode: _mode);
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
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        // 固定高度比 aspectRatio 更好控：缩略图 16:9 + 两行标题 + 一行时长
        mainAxisExtent: 196,
      ),
      itemCount: _items.length + 1,
      itemBuilder: (context, i) {
        if (i == _items.length) {
          return Center(
            child: _more
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text('没有更多了',
                    style:
                        TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
          );
        }
        return _card(_items[i]);
      },
    );
  }

  Widget _card(Map<String, dynamic> it) {
    final title = (it['title'] ?? '').toString();
    final thumb = (it['thumb'] ?? '').toString();
    final dur = (it['duration'] as num?)?.toInt() ?? 0;
    final size = (it['size'] as num?)?.toInt() ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _play(it),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumb.isEmpty)
                    Container(
                      color: AppTheme.backgroundTertiary,
                      child: Icon(Icons.movie_outlined,
                          size: 22, color: AppTheme.textTertiary),
                    )
                  else
                    Image.network(
                      _tg.absolute(thumb),
                      fit: BoxFit.cover,
                      cacheWidth: 400,
                      errorBuilder: (_, __, ___) => Container(
                        color: AppTheme.backgroundTertiary,
                        child: Icon(Icons.movie_outlined,
                            size: 22, color: AppTheme.textTertiary),
                      ),
                    ),
                  // 时长角标
                  if (dur > 0)
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          _dur(dur),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 5,
                    top: 5,
                    child: Icon(Icons.play_circle_fill_rounded,
                        size: 20,
                        color: Colors.white.withValues(alpha: 0.9),
                        shadows: const [
                          Shadow(color: Colors.black26, blurRadius: 4)
                        ]),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _toggleZh(it),
                        child: Text(
                          (it['_zh'] is String &&
                                  (it['_zh'] as String).isNotEmpty)
                              ? it['_zh'] as String
                              : title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 12.5,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      size > 0 ? _size(size) : '',
                      style: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点标题翻译 / 再点还原（外语频道）
  Future<void> _toggleZh(Map<String, dynamic> it) async {
    final zh = it['_zh'];
    if (zh is String && zh.isNotEmpty) {
      setState(() => it.remove('_zh'));
      return;
    }
    final raw = (it['title'] ?? '').toString();
    if (!TranslateService.needsTranslation(raw)) {
      AppToast.message('这条本来就是中文');
      return;
    }
    AppToast.message('翻译中…');
    try {
      final t = await TranslateService.instance.toZh(raw);
      if (!mounted) return;
      setState(() => it['_zh'] = t);
    } catch (e) {
      if (mounted) AppToast.message('翻译失败：$e');
    }
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
