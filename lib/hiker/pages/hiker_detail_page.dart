import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../../miniapp/pages/mini_app_player_page.dart';
import '../../pages/play/webview_player_page.dart';
import '../../services/app_log.dart';
import '../../services/sniff_filter.dart';
import '../../widgets/app_toast.dart';
import '../models/hiker_source.dart';
import '../services/hiker_engine.dart';
import '../services/hiker_prefs.dart';
import '../services/hiker_store.dart';

/// 海阔条目详情 + 播放。
///
/// 取址逻辑：
///   1. 源有 `detail_find_rule` → 跑它拿候选播放地址；
///   2. 没有（Phase 1 里绝大多数）→ 把条目 `url` 当播放地址
///      （很多源的列表项本身就是直链 / 播放页）；
///   3. 每个地址按影视模块**同一套判定**（[SniffFilter.isDirectMedia]，
///      全项目唯一事实来源）分流：直链进原生播放器，网页进内嵌 WebView。
class HikerDetailPage extends StatefulWidget {
  final HikerSource source;
  final HikerItem item;

  /// 延迟规则（`$('').lazyRule(fn)`）的**第二趟**执行入口。
  ///
  /// 列表页把"重跑自己那次查询并带上 lazyId"的闭包传进来 —— 这样详情页不需要
  /// 知道这条条目是从首页 / 分类 / 搜索哪个入口来的（规则重跑才能命中同一个 id）。
  final Future<List<HikerItem>> Function(String lazyId)? replayLazy;

  const HikerDetailPage({
    super.key,
    required this.source,
    required this.item,
    this.replayLazy,
  });

  @override
  State<HikerDetailPage> createState() => _HikerDetailPageState();
}

/// 延迟规则地址前缀（与 hiker_engine.js 的 `lazyRuleImpl` 一致）
const String kHikerLazyPrefix = 'hiker://lazy#';

/// 一条候选播放地址
class _Candidate {
  final String url;
  final String note; // 来源说明（详情规则 / 条目地址）
  const _Candidate(this.url, this.note);
  bool get isDirect => SniffFilter.isDirectMedia(url);
}

class _HikerDetailPageState extends State<HikerDetailPage> {
  final _prefs = HikerPrefs.instance;

  bool _busy = false;
  String? _error;
  String? _resolvedNote;
  List<_Candidate> _candidates = const [];

  /// 规则用 `addListener('onClose', …)` 登记的回调：**离开本页时回放**
  ///（海阔里由原生在页面关闭时执行，多为"清 MyVar / 清缓存"）
  final List<String> _onClose = [];

  /// 最近一次规则跑完的变量（回放 onClose 时用它当上下文）
  Map<String, dynamic> _lastVars = const {};

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_onChanged);
  }

  @override
  void dispose() {
    _prefs.removeListener(_onChanged);
    _fireOnClose();
    super.dispose();
  }

  /// 回放 `onClose`（fire-and-forget；销毁时不能 await）
  void _fireOnClose() {
    final codes = List<String>.from(_onClose);
    if (codes.isEmpty) return;
    final src = widget.source;
    final vars = _lastVars.isEmpty ? HikerStore.instance.varsOf(src.id) : _lastVars;
    unawaited(() async {
      try {
        final r = await HikerEngine.instance
            .runEvents(src, codes, vars: vars, url: widget.item.url);
        if (r.ok) await HikerStore.instance.saveVarsIfChanged(src.id, vars, r.vars);
      } catch (e) {
        AppLog.instance.log('[Hiker] onClose 回放失败: $e');
      }
    }());
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 解析候选地址（详情规则优先，取不到就回落条目 url）
  Future<void> _resolve() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final src = widget.source;
      final out = <_Candidate>[];
      final isLazy = widget.item.url.startsWith(kHikerLazyPrefix);

      if (isLazy) {
        // 延迟规则：第一趟只给了 `hiker://lazy#<id>`，这里跑第二趟拿真值
        final id = widget.item.url.substring(kHikerLazyPrefix.length);
        final replay = widget.replayLazy;
        if (replay == null) {
          if (!mounted) return;
          setState(() => _error = '这个条目是延迟规则（lazyRule），当前入口无法执行');
          return;
        }
        final items = await replay(id);
        for (final x in items) {
          if (x.url.isEmpty || x.url.startsWith(kHikerLazyPrefix)) continue;
          if (out.any((c) => c.url == x.url)) continue;
          out.add(_Candidate(x.url, x.title.isEmpty ? '延迟规则' : x.title));
        }
        _resolvedNote = '延迟规则第二趟：${out.length} 个地址';
        if (!mounted) return;
        setState(() {
          _candidates = out;
          if (out.isEmpty) _error = '延迟规则执行后仍然没有可用地址';
        });
        return;
      }

      if (src.detailFindRule.isNotEmpty) {
        final vars = HikerStore.instance.varsOf(src.id);
        final r = await HikerEngine.instance.detail(src, widget.item.url, vars: vars);
        await HikerStore.instance.saveVarsIfChanged(src.id, vars, r.vars);
        _lastVars = r.vars;
        // 规则登记的事件回调 → 本页关闭时回放（见 _fireOnClose）
        final closeCodes = r.listeners['onClose'];
        if (closeCodes != null) {
          for (final c in closeCodes) {
            if (_onClose.length >= 16) break;
            if (!_onClose.contains(c)) _onClose.add(c);
          }
        }
        if (!r.ok) {
          if (!mounted) return;
          setState(() => _error = r.error ?? '解析失败');
          return;
        }
        if (r.playUrl.isNotEmpty) {
          out.add(_Candidate(r.playUrl, '详情规则'));
        }
        for (final it in r.list) {
          if (it.url.isEmpty) continue;
          out.add(_Candidate(it.url, it.title.isEmpty ? '详情规则' : it.title));
        }
        _resolvedNote = '抓取 ${r.requests} 次 · ${(r.elapsedMs / 1000).toStringAsFixed(1)}s';
      }

      // 条目自身地址也作为候选（详情规则给不出地址时就是它）
      if (widget.item.url.isNotEmpty &&
          !out.any((c) => c.url == widget.item.url)) {
        out.add(_Candidate(widget.item.url, '条目地址'));
      }

      if (!mounted) return;
      setState(() {
        _candidates = out;
        if (out.isEmpty) _error = '没有解析出可用地址';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play(String url) async {
    if (url.isEmpty) return;
    if (SniffFilter.isDirectMedia(url)) {
      // 直链 → 现有原生播放器（MiniAppPlayerPage 就是通用的「url + headers」播放页）
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MiniAppPlayerPage(url: url, title: widget.item.title),
        ),
      );
    } else {
      // 网页 → 内嵌网页播放器（不做嗅探，与影视模块的嗅探开关解耦）
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WebviewPlayerPage(url: url, title: widget.item.title),
        ),
      );
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    AppToast.message('已复制');
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final showRaw = _prefs.showRawUrl;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        title: Text(
          it.title.isEmpty ? '(无标题)' : it.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: '复制条目地址',
            onPressed: it.url.isEmpty ? null : () => _copy(it.url),
            icon: Icon(Icons.copy_rounded, size: 18, color: AppTheme.textSecondary),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _head(it),
          const SizedBox(height: 16),

          // 播放区
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accentColor,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _busy ? null : _playPrimary,
                    icon: _busy
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.play_arrow_rounded, size: 20),
                    label: Text(_busy ? '解析中…' : '播放'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 42,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppTheme.borderMedium),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _busy ? null : _resolve,
                  child: Text('取地址',
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead)),
                ),
              ),
            ],
          ),
          if (_resolvedNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('解析：$_resolvedNote',
                  style: TextStyle(
                      color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
            ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: Colors.orange.shade400),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: AppTheme.fontFootnote,
                            height: 1.5)),
                  ),
                ],
              ),
            ),
          ],

          if (_candidates.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('播放地址（${_candidates.length}）',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ..._candidates.map(_candidateTile),
          ],

          if (it.desc.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('简介',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(it.desc,
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead,
                    height: 1.6)),
          ],

          if (showRaw) ...[
            const SizedBox(height: 18),
            _kv('条目地址', it.url),
            _kv('来源', '${widget.source.title}（${widget.source.author}）'),
            if (it.colType.isNotEmpty) _kv('col_type', it.colType),
          ],
        ],
      ),
    );
  }

  Future<void> _playPrimary() async {
    if (_candidates.isEmpty) await _resolve();
    if (!mounted) return;
    if (_candidates.isEmpty) {
      AppToast.error(_error ?? '没有可用地址');
      return;
    }
    await _play(_candidates.first.url);
  }

  Widget _head(HikerItem it) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 96,
            height: 134,
            color: AppTheme.backgroundTertiary,
            child: it.pic.isEmpty
                ? Center(
                    child: Icon(Icons.movie_outlined,
                        size: 26, color: AppTheme.textTertiary))
                : CachedNetworkImage(
                    imageUrl: it.pic,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Center(
                      child: Icon(Icons.broken_image_outlined,
                          size: 22, color: AppTheme.textTertiary),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(it.title.isEmpty ? '(无标题)' : it.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _infoRow('来源', widget.source.title),
              if (it.desc.isNotEmpty) _infoRow('备注', it.desc),
              if (it.colType.isNotEmpty) _infoRow('类型', it.colType),
              _infoRow('地址', it.url.isEmpty ? '(空)' : _short(it.url)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$k：',
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
            Expanded(
              child: Text(v,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: AppTheme.fontCaption)),
            ),
          ],
        ),
      );

  Widget _candidateTile(_Candidate c) {
    final direct = c.isDirect;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accentSurface,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              direct ? Icons.play_arrow_rounded : Icons.language_rounded,
              size: 17,
              color: AppTheme.accentOnSurface,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontFootnote,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(_short(c.url),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
              ],
            ),
          ),
          IconButton(
            tooltip: '复制',
            onPressed: () => _copy(c.url),
            icon: Icon(Icons.copy_rounded, size: 16, color: AppTheme.textTertiary),
          ),
          TextButton(
            onPressed: () => _play(c.url),
            child: Text(direct ? '播放' : '网页',
                style: TextStyle(
                    color: AppTheme.accentOnSurface, fontSize: AppTheme.fontFootnote)),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    if (v.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k,
              style: TextStyle(
                  color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
          const SizedBox(height: 4),
          SelectableText(v,
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: AppTheme.fontFootnote)),
        ],
      ),
    );
  }

  static String _short(String url) =>
      url.length <= 70 ? url : '${url.substring(0, 34)}…${url.substring(url.length - 30)}';
}
