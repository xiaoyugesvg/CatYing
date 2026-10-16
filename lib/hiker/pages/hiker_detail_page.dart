import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../../miniapp/pages/mini_app_player_page.dart';
import '../../pages/detail/simple_image_reader_page.dart';
import '../../pages/detail/simple_text_reader_page.dart';
import '../../pages/play/webview_player_page.dart';
import '../../services/app_log.dart';
import '../../services/sniff_filter.dart';
import '../../widgets/app_toast.dart';
import '../models/hiker_source.dart';
import '../services/hiker_engine.dart';
import '../services/hiker_prefs.dart';
import '../services/hiker_route.dart';
import '../services/hiker_store.dart';

/// 海阔条目详情 + 打开。
///
/// 取址逻辑：
///   1. 源有 `detail_find_rule` → 跑它拿候选地址；
///   2. 没有（Phase 1 里绝大多数）→ 把条目 `url` 当候选地址
///      （很多源的列表项本身就是直链 / 播放页）；
///   3. 每个地址走 [hikerLinkKind]（海阔**官方** `dealWithUrl` + `UrlDetector`
///      的等价实现）分流，而不是"不是直链就当网页"：
///      `pics://` → 看图阅读器；`novel://` → 书籍阅读器；图片 → 图集阅读器；
///      `toast://` / `copy://` → 提示或复制；影视直链 → 原生播放器；
///      其余网页 → 内嵌 WebView。
class HikerDetailPage extends StatefulWidget {
  final HikerSource source;
  final HikerItem item;

  /// 延迟规则**链条**（父→子）：本页条目是从哪个列表点进来的（空 = 顶层列表）。
  ///
  /// 海阔的 lazy URL 自带那段 JS，点嵌套条目只跑那一段（分类→详情→选集→立即播放）；
  /// 我们是"重跑规则 + 带上要执行的 id"，所以必须把**父链**一起带着，
  /// 引擎才能逐层执行到用户真正点的那一条（见 hiker_engine.js 的 lazyRuleImpl）。
  final List<String> lazyChain;

  /// 延迟规则执行入口：宿主（列表页）拿**整条链**去重跑它那次查询，把结果返回。
  final Future<HikerResult> Function(List<String> lazyIds)? replayLazy;

  const HikerDetailPage({
    super.key,
    required this.source,
    required this.item,
    this.lazyChain = const [],
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
  final String note; // 来源说明（详情规则 / 条目地址 / 选集 / 立即播放）

  /// 还是延迟规则（点它要再解一层）
  final bool lazy;

  /// 产出它的那条链（点它时用 `chain + 自己的 id`）
  final List<String> chain;

  /// 播放请求头（来自海阔播放 JSON 的 headers，防盗链要用）
  final Map<String, String> headers;

  const _Candidate(
    this.url,
    this.note, {
    this.lazy = false,
    this.chain = const [],
    this.headers = const {},
  });

  bool get isDirect => !lazy && SniffFilter.isDirectMedia(url);

  /// 解开后能不能"直接打开"（播放器 / 看图 / 阅读 / 网页 / 提示都算）。
  /// 只解出一条候选时宿主会自动打开它，省一次点击 —— 官方也是直接打开。
  bool get isOpenable {
    if (lazy) return false;
    final k = hikerLinkKind(url);
    return k != HikerLinkKind.unknown && k != HikerLinkKind.hikerPage;
  }
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
        // 延迟规则（分类/详情/选集/立即播放几乎都是它）：解一层，拿到候选
        final next = await _resolveLazy(widget.item.url, widget.item.title, widget.lazyChain);
        if (!mounted) return;
        setState(() {
          _candidates = next;
          _busy = false;
          if (next.isEmpty) _error = '延迟规则执行后仍然没有可用地址';
        });
        _resolvedNote = '延迟规则第二趟：${next.length} 个候选';
        // 只解出**一个可直接打开**的候选时直接打开，省一次点击
        //（不限于直链：`pics://` 漫画、`novel://` 正文也算）
        if (next.length == 1 && next.first.isOpenable) {
          await _play(next.first);
        }
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
          out.add(_Candidate(r.playUrl, '详情规则', headers: r.playHeaders));
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

  /// 解一层延迟规则（`hiker://lazy#<id>`）：
  /// 把 **父链 + 自己** 交给宿主去重跑（见 hiker_engine.js 的 lazyRuleImpl），
  /// 产出的候选里可能还有 lazy（海阔的"详情→选集→立即播放"就是链条）。
  Future<List<_Candidate>> _resolveLazy(
      String lazyUrl, String label, List<String> chain) async {
    final replay = widget.replayLazy;
    if (replay == null) {
      throw Exception('这个条目是延迟规则（lazyRule），当前入口无法执行');
    }
    final id = lazyUrl.substring(kHikerLazyPrefix.length);
    final full = [...chain, id];
    final r = await replay(full);
    if (!r.ok) throw Exception(r.error ?? '规则执行失败');
    // 变量/事件回调照旧（onClose 清理靠它）
    _lastVars = r.vars;
    final closeCodes = r.listeners['onClose'];
    if (closeCodes != null) {
      for (final c in closeCodes) {
        if (_onClose.length >= 16) break;
        if (!_onClose.contains(c)) _onClose.add(c);
      }
    }
    final out = <_Candidate>[];
    if (r.playUrl.isNotEmpty) {
      out.add(_Candidate(r.playUrl,
          label.isEmpty ? '播放地址' : label,
          headers: r.playHeaders));
    }
    for (final u in r.playUrlExtra) {
      out.add(_Candidate(u, '备用清晰度', headers: r.playHeaders));
    }
    for (final it in r.list) {
      if (it.url.isEmpty) continue;
      final lazy = it.url.startsWith(kHikerLazyPrefix);
      out.add(_Candidate(
        it.url,
        it.title.isEmpty ? (lazy ? '选集' : '地址') : it.title,
        lazy: lazy,
        chain: full,
      ));
    }
    return out;
  }

  Future<void> _play(_Candidate c) async {
    if (c.lazy) {
      // 又一层延迟规则（"立即播放"/选集）：再解一层，能出直链就直接播
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        final next = await _resolveLazy(c.url, c.note, c.chain);
        if (!mounted) return;
        setState(() {
          _busy = false;
          _candidates = next;
          if (next.isEmpty) _error = '这一步没解析出地址';
        });
        final plain = next.where((x) => x.isOpenable).toList();
        if (next.length == 1 && plain.length == 1) {
          await _play(plain.first);
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = '$e';
          });
        }
      }
      return;
    }
    final url = c.url;
    if (url.isEmpty) return;

    // 按海阔**官方** `dealWithUrl()` 的顺序分流（见 hiker_route.dart）。
    // 原来只有"直链 / 网页"两支，导致漫画（`pics://`）、小说（`novel://`）、
    // 图集（图片地址）和提示类（`toast://`）全被丢给 WebView，打开是空白页。
    switch (hikerLinkKind(url)) {
      case HikerLinkKind.pics:
        // 多图模式（类似漫画）：`pics://图1&&图2`
        final pics = hikerPicList(url) ?? const <String>[];
        if (pics.isEmpty) {
          AppToast.error('这个条目是图片列表，但没解析出图片');
          return;
        }
        _openImageReader(pics, c.headers);
        return;

      case HikerLinkKind.novel:
        // 正文协议（小说源）：`novel://{title,content}`
        final novel = hikerNovelContent(url);
        if (novel == null || novel.content.trim().isEmpty) {
          AppToast.error('这个条目是正文，但内容是空的');
          return;
        }
        SimpleTextReaderPage.open(
          content: novel.content,
          bookName: widget.item.title,
          chapterName: novel.title,
        );
        return;

      case HikerLinkKind.image:
        // 官方：点列表里的一张图 → 把**当前候选里的所有图片**一起收进大图预览
        //（可左右翻页），而不是只开这一张。
        final pics = _collectImages(url);
        _openImageReader(pics, c.headers);
        return;

      case HikerLinkKind.media:
        await _pushPlayer(url, c.headers);
        return;

      case HikerLinkKind.x5Play:
        // 官方语义：强制用播放器播这个地址 → 剥掉外壳再判一次
        final real = hikerStripScheme(url);
        if (SniffFilter.isDirectMedia(real)) {
          await _pushPlayer(real, c.headers);
        } else {
          await _pushWeb(real);
        }
        return;

      case HikerLinkKind.toast:
        AppToast.message(_payloadOf(url));
        return;

      case HikerLinkKind.copyLink:
      case HikerLinkKind.external:
        // `copy://内容` / `magnet:…`：官方是复制到剪贴板 / 交第三方软件。
        // 本模块没有外部 App 调起能力，统一复制 + 提示，别静默。
        final text = hikerStripScheme(_payloadOf(url));
        await Clipboard.setData(ClipboardData(text: text));
        AppToast.message('已复制到剪贴板');
        return;

      case HikerLinkKind.download:
      case HikerLinkKind.apk:
        final real = hikerStripScheme(url);
        await Clipboard.setData(ClipboardData(text: real));
        AppToast.message('下载地址已复制（本模块不做下载）');
        return;

      case HikerLinkKind.hikerPage:
        // `hiker://…` 是海阔 App 的内部页面/二级页面，本模块没有对应功能
        AppToast.message('这个条目跳的是海阔内部页面，当前不支持：${_short(url)}');
        return;

      case HikerLinkKind.js:
        // 官方叫"彩蛋模式"：url 本身就是一段 JS，跳浏览器执行。
        // 我们没法执行它，也不能把 `javascript:…` 丢给 WebView（会白屏）。
        AppToast.message('这个条目是一段 JS（海阔的彩蛋模式），当前不支持');
        return;

      case HikerLinkKind.x5:
      case HikerLinkKind.web:
      case HikerLinkKind.videoSniff:
        // 都是"在网页里打开"：X5 全屏、强制网页、自动提取视频。
        // 自动提取视频官方是进播放器嗅探；本模块与嗅探开关解耦，降级为网页，
        // 用户可在内嵌网页里自己点播放（至少不是非法 scheme 导致的空白页）。
        await _pushWeb(hikerStripScheme(url));
        return;

      case HikerLinkKind.http:
        await _pushWeb(url);
        return;

      case HikerLinkKind.unknown:
        // 官方兜底也是这条文案
        AppToast.message('未知链接：${_short(url)}');
        return;
    }
  }

  /// 进原生播放器
  Future<void> _pushPlayer(String url, Map<String, String> headers) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MiniAppPlayerPage(
          url: url,
          title: widget.item.title,
          headers: headers.isEmpty ? null : headers,
        ),
      ),
    );
  }

  /// 进内嵌网页
  Future<void> _pushWeb(String url) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WebviewPlayerPage(url: url, title: widget.item.title),
      ),
    );
  }

  /// 进看图阅读器（漫画 / 图集共用）
  void _openImageReader(List<String> images, Map<String, String> headers) {
    AppLog.instance
        .log('[Hiker] 图片列表 → 看图阅读器（${images.length} 张）');
    SimpleImageReaderPage.open(
      title: widget.item.title,
      images: images,
      chapterName: widget.source.title,
      headers: headers,
    );
  }

  /// 收集本页候选里的所有图片（官方"点一张图 → 翻本列表所有图"的等价实现）；
  /// [first] 强制排在最前，保证点谁就先看谁。
  List<String> _collectImages(String first) {
    final out = <String>[first];
    for (final c in _candidates) {
      if (c.lazy) continue;
      if (c.url == first) continue;
      if (hikerLinkKind(c.url) != HikerLinkKind.image) continue;
      if (out.contains(c.url)) continue;
      out.add(c.url);
    }
    return out;
  }

  /// 取协议体（`toast://文本` → `文本`，`copy://内容.js:'x'` → `内容`）
  static String _payloadOf(String url) {
    final i = url.indexOf('://');
    var body = i >= 0 ? url.substring(i + 3) : url;
    // 官方的 `copy://内容.js:'…'` 尾巴要去掉
    final dot = body.indexOf(".js:");
    if (dot >= 0) body = body.substring(0, dot);
    return body;
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
    // 优先挑"直接能播"的那个；全是 lazy 就先解第一个（会再解一层）
    final pick = _candidates.firstWhere((c) => !c.lazy,
        orElse: () => _candidates.first);
    await _play(pick);
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
    // lazy 候选（"选集"/"立即播放"这类）点了会再解一层，按钮文案给"打开"
    final kind = c.lazy ? null : hikerLinkKind(c.url);
    final actionLabel = c.lazy
        ? '打开'
        : switch (kind!) {
            HikerLinkKind.media || HikerLinkKind.x5Play => '播放',
            HikerLinkKind.pics || HikerLinkKind.image => '看图',
            HikerLinkKind.novel => '阅读',
            HikerLinkKind.toast ||
            HikerLinkKind.copyLink ||
            HikerLinkKind.external ||
            HikerLinkKind.download ||
            HikerLinkKind.apk ||
            HikerLinkKind.hikerPage ||
            HikerLinkKind.unknown =>
              '提示',
            _ => '网页',
          };
    final actionIcon = c.lazy
        ? Icons.touch_app_rounded
        : switch (kind!) {
            HikerLinkKind.media || HikerLinkKind.x5Play => Icons.play_arrow_rounded,
            HikerLinkKind.pics || HikerLinkKind.image => Icons.photo_library_rounded,
            HikerLinkKind.novel => Icons.menu_book_rounded,
            HikerLinkKind.toast ||
            HikerLinkKind.copyLink ||
            HikerLinkKind.external ||
            HikerLinkKind.download ||
            HikerLinkKind.apk ||
            HikerLinkKind.hikerPage ||
            HikerLinkKind.unknown =>
              Icons.info_outline_rounded,
            _ => Icons.language_rounded,
          };
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
              actionIcon,
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
            onPressed: () => _play(c),
            child: Text(actionLabel,
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
