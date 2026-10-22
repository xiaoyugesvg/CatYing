import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';
import 'rex_models.dart';
import 'rex_player_page.dart';
import 'rex_service.dart';

/// REX 模块的详情页：展示 `loadDetail` 结果，播放时调 `loadResource`。
///
/// 播放地址通常是**带时效签名**的（如 helvid 的 m3u8），所以这里不在进页面时
/// 预解析，而是用户点「播放」那一刻才去取，保证签名新鲜。
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
  bool _resolving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;

  Future<void> _load() async {
    try {
      final d = await _service.detail(widget.module, widget.item);
      if (!mounted) return;
      setState(() {
        if (d != null) _item = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(_item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 108,
                  height: 158,
                  child: _item.cover.isEmpty
                      ? Container(
                          color: _isDark
                              ? Colors.white10
                              : Colors.black.withValues(alpha: 0.06),
                          child: Icon(Icons.movie_outlined,
                              size: 24, color: _sub),
                        )
                      : CachedNetworkImage(
                          imageUrl: _item.cover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: _isDark
                                ? Colors.white10
                                : Colors.black.withValues(alpha: 0.06),
                            child: Icon(Icons.movie_outlined,
                                size: 24, color: _sub),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_item.title,
                        style: TextStyle(
                            color: _fg,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600,
                            height: 1.3)),
                    if (_item.description.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(_item.description,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _sub,
                              fontSize: AppTheme.fontFootnote,
                              height: 1.5)),
                    ],
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accentColor,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 42),
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppTheme.radiusMD)),
                        ),
                        onPressed: _resolving ? null : _play,
                        icon: _resolving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.play_arrow_rounded, size: 20),
                        label: Text(_resolving ? '解析线路中…' : '播放'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_loading) ...[
            const SizedBox(height: 18),
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: AppTheme.fontFootnote,
                    height: 1.5)),
          ],
          const SizedBox(height: 16),
          Text(
            '模块：${widget.module.title}'
            '${_item.playerType.isNotEmpty ? ' · ${_item.playerType}' : ''}',
            style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption),
          ),
        ],
      ),
    );
  }

  Future<void> _play() async {
    // 少数模块的 detail 直接给直链（没有 loadResource）
    if (_item.link.startsWith('http') && _looksLikeMedia(_item.link)) {
      _open(RexStream(name: '直链', url: _item.link));
      return;
    }
    if (!widget.module.canPlay) {
      AppToast.show('这个模块没有 loadResource，不能播放', '');
      return;
    }
    setState(() => _resolving = true);
    try {
      final streams = await _service.resource(widget.module, _item);
      if (!mounted) return;
      if (streams.isEmpty) {
        AppToast.show('没有解析到播放地址', '');
        return;
      }
      if (streams.length == 1) {
        _open(streams.first);
        return;
      }
      final picked = await showModalBottomSheet<RexStream>(
        context: context,
        backgroundColor: _isDark ? const Color(0xFF1C1C1E) : Colors.white,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (ctx) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Text('选择线路',
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: streams.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 0.5, color: _sub.withValues(alpha: 0.2)),
                  itemBuilder: (context, i) {
                    final s = streams[i];
                    return ListTile(
                      title: Text(s.name,
                          style: TextStyle(
                              color: _fg, fontSize: AppTheme.fontSubhead)),
                      subtitle: s.description.isEmpty
                          ? null
                          : Text(s.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: _sub,
                                  fontSize: AppTheme.fontCaption)),
                      trailing: Icon(Icons.play_arrow_rounded, color: _sub),
                      onTap: () => Navigator.pop(context, s),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (picked != null) _open(picked);
    } catch (e) {
      if (mounted) AppToast.show('$e', '');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
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
