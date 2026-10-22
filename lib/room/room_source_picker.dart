import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../services/app_log.dart';
import '../services/spider_service.dart';

/// 房间要播放的一条内容（已解析成可直接播放的地址）
class RoomMedia {
  const RoomMedia({
    required this.url,
    this.headers = const {},
    this.title = '',
  });

  final String url;
  final Map<String, String> headers;
  final String title;
}

/// 「一起看」的选片器：在当前影视源里搜片 → 选线路/集数 → 解析出播放地址。
///
/// 复用 App 现有的源与解析链路（[SpiderService]），因此和正常播放看到的
/// 内容、清晰度、请求头完全一致；只是把最终地址交回房间广播出去。
class RoomSourcePickerPage extends StatefulWidget {
  const RoomSourcePickerPage({super.key});

  @override
  State<RoomSourcePickerPage> createState() => _RoomSourcePickerPageState();
}

class _RoomSourcePickerPageState extends State<RoomSourcePickerPage> {
  final _kwCtrl = TextEditingController();
  final _focus = FocusNode();

  List<Map<String, dynamic>> _results = const [];
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _kwCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;

  ({String key, int type, String api, String ext}) get _spider =>
      SpiderService.instance.getCurrentSpiderInfo();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isDark ? const Color(0xFF101012) : Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('选片',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _kwCtrl,
                    focusNode: _focus,
                    textInputAction: TextInputAction.search,
                    style: TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: '搜电影 / 剧集 / 动漫…',
                      hintStyle:
                          TextStyle(color: _sub, fontSize: AppTheme.fontSubhead),
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 19, color: _sub),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMD),
                        borderSide: BorderSide(
                            color: _isDark ? Colors.white24 : Colors.black12,
                            width: 0.8),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMD),
                        borderSide: BorderSide(
                            color: _isDark ? Colors.white24 : Colors.black12,
                            width: 0.8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accentColor,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(64, 42),
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMD)),
                  ),
                  onPressed: _searching ? null : _search,
                  child: Text(_searching ? '搜…' : '搜索'),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_error!,
                  style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: AppTheme.fontFootnote,
                      height: 1.4)),
            ),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_searching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            '输入片名搜索当前影视源。\n选一集之后会把播放地址同步给房间里所有人。',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: _sub, fontSize: AppTheme.fontFootnote, height: 1.6),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final v = _results[i];
        final name = '${v['vod_name'] ?? v['name'] ?? '未命名'}';
        final remarks = '${v['vod_remarks'] ?? v['remarks'] ?? ''}';
        final pic = '${v['vod_pic'] ?? v['pic'] ?? ''}';
        return InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          onTap: () => _pickEpisodes(v),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 52,
                    height: 72,
                    child: pic.isEmpty
                        ? Container(
                            color: _isDark ? Colors.white10 : Colors.black12,
                            child: Icon(Icons.movie_outlined,
                                size: 20, color: _sub),
                          )
                        : CachedNetworkImage(
                            imageUrl: pic,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: _isDark ? Colors.white10 : Colors.black12,
                              child: Icon(Icons.movie_outlined,
                                  size: 20, color: _sub),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _fg,
                              fontSize: AppTheme.fontSubhead,
                              fontWeight: FontWeight.w600)),
                      if (remarks.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(remarks,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: _sub,
                                fontSize: AppTheme.fontCaption)),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: _sub),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _search() async {
    final kw = _kwCtrl.text.trim();
    if (kw.isEmpty) return;
    final sp = _spider;
    if (sp.key.isEmpty) {
      setState(() => _error = '还没有可用的影视源：先去首页「切换源」选一个，再回来搜片');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _results = const [];
    });
    try {
      final r = await SpiderService.instance
          .search(sp.key, sp.type, sp.api, kw, ext: sp.ext);
      final list = r?['list'];
      final out = <Map<String, dynamic>>[];
      if (list is List) {
        for (final e in list) {
          if (e is Map) out.add(e.cast<String, dynamic>());
        }
      }
      if (!mounted) return;
      setState(() {
        _results = out;
        _searching = false;
        if (out.isEmpty) _error = '没搜到结果，换个关键词试试';
      });
    } catch (e) {
      AppLog.instance.log('[Room] 搜索失败: $e');
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '搜索失败：$e';
      });
    }
  }

  /// 拉详情 → 弹出线路/集数选择
  Future<void> _pickEpisodes(Map<String, dynamic> vod) async {
    final sp = _spider;
    final vodId = '${vod['vod_id'] ?? vod['id'] ?? ''}';
    final vodName = '${vod['vod_name'] ?? vod['name'] ?? ''}';
    if (vodId.isEmpty) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    Map<String, dynamic> detail = const {};
    try {
      final r = await SpiderService.instance
          .getDetail(sp.key, sp.type, sp.api, vodId, ext: sp.ext);
      if (r != null) {
        detail = r;
        final list = r['list'];
        if (list is List && list.isNotEmpty && list.first is Map) {
          detail = (list.first as Map).cast<String, dynamic>();
        }
      }
    } catch (e) {
      AppLog.instance.log('[Room] 详情失败: $e');
    }
    if (!mounted) return;
    Navigator.of(context).pop();

    final groups = _buildEpisodeGroups(detail);
    if (groups.isEmpty) {
      AppToastText.show(context, '这个条目没有可播放的集数');
      return;
    }

    final picked = await showModalBottomSheet<_Episode>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _EpisodeSheet(
        title: vodName.isEmpty ? '选集' : vodName,
        groups: groups,
      ),
    );
    if (picked == null || !mounted) return;
    await _resolve(picked, vodName);
  }

  List<_EpisodeGroup> _buildEpisodeGroups(Map<String, dynamic> d) {
    final froms = '${d['vod_play_from'] ?? ''}'.split(r'$$$');
    final urls = '${d['vod_play_url'] ?? ''}'.split(r'$$$');
    final groups = <_EpisodeGroup>[];
    for (var i = 0; i < urls.length; i++) {
      final raw = urls[i].trim();
      if (raw.isEmpty) continue;
      final flag = i < froms.length ? froms[i].trim() : '';
      final eps = <_Episode>[];
      for (final part in raw.split('#')) {
        final p = part.trim();
        if (p.isEmpty) continue;
        final idx = p.indexOf(r'$');
        final epName = idx >= 0 ? p.substring(0, idx) : p;
        final epId = idx >= 0 ? p.substring(idx + 1) : p;
        if (epId.isEmpty) continue;
        eps.add(_Episode(name: epName.isEmpty ? '正片' : epName, id: epId, flag: flag));
      }
      if (eps.isNotEmpty) {
        groups.add(_EpisodeGroup(
          name: flag.isEmpty ? '线路 ${i + 1}' : flag,
          episodes: eps,
        ));
      }
    }
    return groups;
  }

  Future<void> _resolve(_Episode ep, String vodName) async {
    final sp = _spider;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    Map<String, dynamic>? r;
    String? err;
    try {
      r = await SpiderService.instance
          .getPlayUrl(sp.key, sp.type, sp.api, ep.flag, ep.id, ext: sp.ext);
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    Navigator.of(context).pop();

    if (r == null) {
      AppToastText.show(context, err == null ? '解析播放地址失败' : '解析失败：$err');
      return;
    }
    final url = _pickUrl(r['url']);
    if (url.isEmpty) {
      AppToastText.show(context, '这个源没有返回可播放地址');
      return;
    }
    final headers = <String, String>{};
    final h = r['header'];
    if (h is Map) {
      h.forEach((k, v) => headers['$k'] = '$v');
    }
    Navigator.of(context).pop(RoomMedia(
      url: url,
      headers: headers,
      title: vodName.isEmpty ? ep.name : '$vodName · ${ep.name}',
    ));
  }

  /// catvod 的 url 可能是字符串，也可能是 [名称, 地址, 名称, 地址…]
  String _pickUrl(dynamic v) {
    if (v is String) return v.trim();
    if (v is List) {
      for (var i = 1; i < v.length; i += 2) {
        final s = '${v[i]}'.trim();
        if (s.isNotEmpty) return s;
      }
      for (final e in v) {
        final s = '$e'.trim();
        if (s.startsWith('http')) return s;
      }
    }
    return '';
  }
}

/// 简易提示（不依赖全局 Toast 的调用点上下文）
class AppToastText {
  static void show(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 2),
    ));
  }
}

class _Episode {
  const _Episode({required this.name, required this.id, required this.flag});
  final String name;
  final String id;
  final String flag;
}

class _EpisodeGroup {
  const _EpisodeGroup({required this.name, required this.episodes});
  final String name;
  final List<_Episode> episodes;
}

class _EpisodeSheet extends StatelessWidget {
  const _EpisodeSheet({required this.title, required this.groups});

  final String title;
  final List<_EpisodeGroup> groups;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    final sub = isDark ? Colors.white60 : Colors.black54;
    final bg = isDark ? const Color(0xFF1C1C1E) : Colors.white;

    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.72),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black26,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: fg,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: groups.length,
                itemBuilder: (context, i) {
                  final g = groups[i];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 6),
                        child: Text(g.name,
                            style: TextStyle(
                                color: sub,
                                fontSize: AppTheme.fontCaption,
                                fontWeight: FontWeight.w600)),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final ep in g.episodes)
                            ActionChip(
                              label: Text(ep.name,
                                  style: TextStyle(
                                      fontSize: AppTheme.fontFootnote,
                                      color: fg)),
                              onPressed: () => Navigator.of(context).pop(ep),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
