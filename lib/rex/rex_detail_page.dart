import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/rex/rex_models.dart';
import 'package:tvbox/rex/rex_player_page.dart';
import 'package:tvbox/rex/rex_service.dart';

/// REX 详情页 —— 布局对齐影视详情：
///   大幅头图 + 悬浮返回键 → 海报 + 标题/元数据 + 播放按钮 → 简介 → 播放列表。
///
/// ⚠️ 播放列表在**进入页面时**就自动解析（用户 2026-10-23：「不是点击播放
///    加载列表，而是点击进去就有播放列表」）。部分模块返回的地址带时效签名，
///    放太久再点可能失效 —— 届时回到列表重进即可，列表上有「重新解析」。
class RexDetailPage extends StatefulWidget {
  const RexDetailPage({
    super.key,
    required this.module,
    required this.item,
  });

  final RexModule module;
  final RexItem item;

  @override
  State<RexDetailPage> createState() => _RexDetailPageState();
}

class _RexDetailPageState extends State<RexDetailPage> {
  final _service = RexService.instance;

  late RexItem _item = widget.item;
  bool _loading = true;
  bool _expanded = false;
  String? _error;

  // 播放列表（进页面即解析）
  List<RexStream> _streams = const [];
  bool _streamsLoading = false;
  String? _streamsError;

  @override
  void initState() {
    super.initState();
    // 详情与线路并行加载，谁也不等谁
    _loadDetail();
    if (_needsResolve()) _loadStreams();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;

  /// 是否需要调 loadResource：直链 detail 直接能播，就不用
  bool _needsResolve() {
    if (_item.link.startsWith('http') && _looksLikeMedia(_item.link)) {
      return false;
    }
    return widget.module.canPlay;
  }

  Future<void> _loadDetail() async {
    try {
      final d = await _service.detail(widget.module, widget.item);
      if (!mounted) return;
      final linkChanged = d != null && d.link != _item.link;
      setState(() {
        if (d != null) _item = d;
        _loading = false;
      });
      // 详情可能把列表里的简写 link 换成带 id 的真实 link：
      // 那样之前用旧 link 解析出的线路就是错的 ⇒ 用新 link 重新解析。
      if (linkChanged && _needsResolve()) _loadStreams();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadStreams() async {
    setState(() {
      _streamsLoading = true;
      _streamsError = null;
    });
    try {
      final streams = await _service.resource(widget.module, _item);
      if (!mounted) return;
      setState(() {
        _streams = streams;
        _streamsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // 清空旧线路：解析失败时留着上一次的结果（可能已过期）更误导
        _streams = const [];
        _streamsError = '$e';
        _streamsLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final backdrop = _item.backdrop.isNotEmpty ? _item.backdrop : _item.cover;
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.zero,
            children: [
              // ── 头图（对齐影视详情的大图）──────────────────────
              SizedBox(
                height: 224 + top,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (backdrop.isEmpty)
                      Container(
                        color: _isDark
                            ? Colors.white10
                            : Colors.black.withValues(alpha: 0.06),
                      )
                    else
                      CachedNetworkImage(
                        imageUrl: backdrop,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: _isDark
                              ? Colors.white10
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                    // 顶部压暗：保证返回键在任何图上都清晰
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.45),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.45],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // ── 海报 + 信息（上移一点，和头图衔接）──────────────
              Transform.translate(
                offset: const Offset(0, -34),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 海报（影视详情同款：左海报、右信息）
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  blurRadius: 12,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 104,
                                height: 156,
                                child: _item.cover.isEmpty
                                    ? _posterPlaceholder()
                                    : CachedNetworkImage(
                                        imageUrl: _item.cover,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            _posterPlaceholder(),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 38),
                                Text(
                                  _item.title,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: _fg,
                                      fontSize: AppTheme.fontTitle3,
                                      fontWeight: FontWeight.w700,
                                      height: 1.25),
                                ),
                                const SizedBox(height: 8),
                                _metaRow(),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppTheme.accentColor,
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size(0, 42),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                              AppTheme.radiusMD)),
                                    ),
                                    onPressed: _streamsLoading ? null : _play,
                                    icon: _streamsLoading
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white))
                                        : const Icon(Icons.play_arrow_rounded,
                                            size: 22),
                                    label: Text(
                                        _streamsLoading ? '解析线路中…' : '立即播放'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      if (_loading)
                        const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      if (_error != null)
                        Text(_error!,
                            style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: AppTheme.fontFootnote,
                                height: 1.5)),
                      // ── 播放列表：进页面就摆在这，点哪条播哪条 ──────
                      if (_needsResolve()) ...[
                        _sectionTitle('播放列表'),
                        const SizedBox(height: 8),
                        _streamList(),
                        const SizedBox(height: 6),
                      ],
                      if (_item.description.isNotEmpty) ...[
                        _sectionTitle('简介'),
                        const SizedBox(height: 6),
                        Text(
                          _item.description,
                          maxLines: _expanded ? 30 : 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _fg,
                              fontSize: AppTheme.fontFootnote,
                              height: 1.65),
                        ),
                        if (_item.description.length > 80)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () =>
                                setState(() => _expanded = !_expanded),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_expanded ? '收起' : '展开',
                                      style: TextStyle(
                                          color: AppTheme.accentColor,
                                          fontSize: AppTheme.fontCaption)),
                                  Icon(
                                      _expanded
                                          ? Icons.keyboard_arrow_up
                                          : Icons.keyboard_arrow_down,
                                      size: 14,
                                      color: AppTheme.accentColor),
                                ],
                              ),
                            ),
                          ),
                      ],
                      const SizedBox(height: 18),
                      _sectionTitle('来源'),
                      const SizedBox(height: 6),
                      Text(
                        '${widget.module.title}'
                        '${_item.playerType.isNotEmpty ? ' · ${_item.playerType}' : ''}\n'
                        '播放地址由模块实时解析，可能带时效签名，失效请点「重新解析」。',
                        style: TextStyle(
                            color: _sub,
                            fontSize: AppTheme.fontCaption,
                            height: 1.6),
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // 悬浮返回键（头图上的白字按钮）
          Positioned(
            left: 6,
            top: top + 4,
            child: Material(
              color: Colors.black.withValues(alpha: 0.3),
              shape: const CircleBorder(),
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded,
                    size: 18, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaRow() {
    final chips = <String>[
      if (widget.module.title.isNotEmpty) widget.module.title,
      if (_item.mediaType.isNotEmpty) _item.mediaType,
      if (_item.playerType.isNotEmpty) _item.playerType,
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final c in chips)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.accentColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(c,
                style: TextStyle(
                    color: AppTheme.accentColor,
                    fontSize: AppTheme.fontCaption)),
          ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Row(
        children: [
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              color: AppTheme.accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 7),
          Text(text,
              style: TextStyle(
                  color: _fg,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600)),
        ],
      );

  Widget _posterPlaceholder() => Container(
        color: _isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, size: 24, color: _sub),
      );

  Widget _streamList() {
    if (_streamsLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text('正在解析线路…',
                style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
          ],
        ),
      );
    }
    if (_streamsError != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: _isDark ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(_streamsError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: _sub,
                      fontSize: AppTheme.fontCaption,
                      height: 1.5)),
            ),
            TextButton(
              onPressed: _loadStreams,
              child: const Text('重新解析'),
            ),
          ],
        ),
      );
    }
    if (_streams.isEmpty) {
      // 空态也要给「重新解析」：详情返回后 link 变化、或首发请求没落地时，
      // 用户不该只能退出重进（旧版这里是个死胡同）。
      return Row(
        children: [
          Expanded(
            child: Text('没有解析到播放地址',
                style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
          ),
          TextButton(
            onPressed: _loadStreams,
            child: const Text('重新解析'),
          ),
        ],
      );
    }
    return Column(
      children: [
        for (var i = 0; i < _streams.length; i++) _streamTile(_streams[i], i),
      ],
    );
  }

  Widget _streamTile(RexStream s, int index) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(s),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.025),
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text('${index + 1}',
                  style: TextStyle(
                      color: AppTheme.accentOnSurface,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name.isEmpty ? '线路 ${index + 1}' : s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _fg,
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w500)),
                  if (s.description.isNotEmpty)
                    Text(s.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _sub, fontSize: AppTheme.fontCaption)),
                ],
              ),
            ),
            Icon(Icons.play_circle_outline_rounded,
                size: 20, color: AppTheme.accentOnSurface),
          ],
        ),
      ),
    );
  }

  void _play() {
    // 少数模块的 detail 直接给直链（没有 loadResource）
    if (_item.link.startsWith('http') && _looksLikeMedia(_item.link)) {
      _open(RexStream(name: '直链', url: _item.link));
      return;
    }
    if (!widget.module.canPlay) {
      AppToast.show('这个模块没有 loadResource，不能播放', '');
      return;
    }
    // 线路在进页面时就解析好了：直接播第一条。
    // 列表空 / 加载失败过 → 点按钮相当于再试一次
    if (_streams.isNotEmpty) {
      _open(_streams.first);
      return;
    }
    if (_streamsError != null) {
      _loadStreams();
      return;
    }
    AppToast.show('没有解析到播放地址', '');
  }

  bool _looksLikeMedia(String url) {
    final u = url.toLowerCase().split('?').first;
    return u.endsWith('.m3u8') ||
        u.endsWith('.mp4') ||
        u.endsWith('.flv') ||
        u.endsWith('.ts');
  }

  void _open(RexStream s) {
    Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'rex:player'),
      builder: (_) => RexPlayerPage(
        title: _item.title,
        url: s.url,
        headers: s.headers,
      ),
    ));
  }
}
