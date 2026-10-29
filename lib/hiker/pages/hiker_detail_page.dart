import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/miniapp/pages/mini_app_player_page.dart';
import 'package:tvbox/pages/detail/simple_image_reader_page.dart';
import 'package:tvbox/pages/detail/simple_text_reader_page.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/play_pipeline.dart';
import 'package:tvbox/services/play_route.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/playback_surface.dart';
import 'package:tvbox/hiker/models/hiker_source.dart';
import 'package:tvbox/hiker/services/hiker_engine.dart';
import 'package:tvbox/hiker/services/hiker_prefs.dart';
import 'package:tvbox/hiker/services/hiker_route.dart';
import 'package:tvbox/hiker/services/hiker_store.dart';
import 'package:tvbox/hiker/widgets/hiker_blocks.dart' show hikerPlainText, hikerRichSpans;
import 'package:tvbox/hiker/pages/hiker_search_page.dart';

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
  ///
  /// [lazyInput] 对应海阔的「条目地址 + lazyRule」写法（如 kinostream 的
  /// `pd(…,'a&&href') + lazy`）：规则 fn 里的 `input` 就是前面那截真实地址。
  final Future<HikerResult> Function(List<String> lazyIds, {String lazyInput})?
  replayLazy;

  /// 「打开一个新页面」——`nextPage` 不是 lazy 时用它：宿主用**同一个源**按那个地址
  /// 跑一次 `find_rule`，等价于海阔里点「下一页」。（见 `_loadNextChapterImages`）
  final Future<HikerResult> Function(String url)? runPage;

  const HikerDetailPage({
    super.key,
    required this.source,
    required this.item,
    this.lazyChain = const [],
    this.replayLazy,
    this.runPage,
  });

  @override
  State<HikerDetailPage> createState() => _HikerDetailPageState();
}

/// 延迟规则地址前缀（与 hiker_engine.js 的 `lazyRuleImpl` 一致）
const String kHikerLazyPrefix = 'hiker://lazy#';

/// 把「条目地址 + lazyRule」拆成 (前面那截真实地址, lazy id)。
///
/// 海阔最常见的写法是 `'https://site/play/123' + $('').lazyRule(fn)` ——
/// 拼出来的字符串里 `hiker://lazy#` **不在开头**。之前只认 `startsWith`，
/// 这类条目会被当成普通网页直接丢进 WebView（实测 kinostream / Xvideos）。
({String input, String id})? splitHikerLazyUrl(String url) {
  final i = url.indexOf(kHikerLazyPrefix);
  if (i < 0) return null;
  return (
    input: url.substring(0, i),
    id: url.substring(i + kHikerLazyPrefix.length),
  );
}

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

  /// lazy 条目前面那截真实地址（规则 fn 里的 `input`）
  final String input;

  /// 引擎返回的 `col_type`（剧照 / 线路标记识别用）
  final String colType;

  /// 引擎返回的封面（剧照横滑用）
  final String pic;

  const _Candidate(
    this.url,
    this.note, {
    this.lazy = false,
    this.chain = const [],
    this.headers = const {},
    this.input = '',
    this.colType = '',
    this.pic = '',
  });

  bool get isDirect => !lazy && looksLikeDirectMedia(url);

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

  /// 源给的**下一页/下一章**地址（官方 `setNextPage`；空 = 没有下一页）。
  /// 看图阅读器靠它做「下拉自动下一章」。
  String _nextPage = '';

  /// 产出当前候选的那条 lazy 链（`_nextPage` 还是 lazy 时要用它接续）
  List<String> _lastChain = const [];

  /// 本页条目地址里的**内联规则**（`@rule=` / `@lazyRule=`）。
  ///
  /// 非空时：目录由它产出；章节里的 `hiker://lazy#id` 也必须用**同一段 code**
  /// 再跑一趟才能解开（lazy 定义在那次执行的作用域里，宿主的 home/category
  /// 重放看不到它）。实测「漫小肆」的目录 → 看图链路。
  HikerInlineRule? _inline;

  /// 最近一次 lazy 解出来的**真实页面地址**（章节页），图片的 `@Referer=`
  /// 空值时用它补 Referer。
  String _lastInput = '';

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_onChanged);
    // 进页面就自动取地址（用户 2026-10-17：「要自动获取，除非是确实没有，
    // 再点击获取地址」）。原来必须点「播放 / 取地址」才跑规则，
    // 于是每个源看起来都"点下去没反应"。
    // 首帧之后再跑：initState 里直接 setState 会撞 build。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resolve(auto: true);
    });
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
    final vars = _lastVars.isEmpty
        ? HikerStore.instance.varsOf(src.id)
        : _lastVars;
    unawaited(() async {
      try {
        final r = await HikerEngine.instance.runEvents(
          src,
          codes,
          vars: vars,
          url: widget.item.url,
        );
        if (r.ok)
          await HikerStore.instance.saveVarsIfChanged(src.id, vars, r.vars);
      } catch (e) {
        AppLog.instance.log('[Hiker] onClose 回放失败: $e');
      }
    }());
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 解析候选地址（详情规则优先，取不到就回落条目 url）
  ///
  /// [auto] = 进页面时的自动解析：**只把播放列表取回来，不自动开播**
  /// （用户 2026-10-17：自动获取的是"列表"，播放仍由用户点）。
  Future<void> _resolve({bool auto = false}) async {
    if (_busy) return;
    // 条目没有地址（广告位 / 空卡片）：直接给明确提示。
    // 否则会拿空地址去跑详情规则 → 「只支持 http(s) 地址，规则要的是「（空）」」
    // 这种看不懂的异常（用户 2026-10-18 的截图）。
    if (widget.item.url.trim().isEmpty) {
      setState(() {
        _error = '这个条目没有地址（可能是广告位）';
        _candidates = const [];
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final src = widget.source;
      final out = <_Candidate>[];
      // ⚠️ 不能只用 startsWith：海阔大量源写成 `真实地址 + $('').lazyRule(fn)`
      //（如 kinostream 的 `pd(…,'a&&href') + lazy`），lazy 标记在**中间**。
      final lazySplit = splitHikerLazyUrl(widget.item.url);

      if (lazySplit != null) {
        // 延迟规则（分类/详情/选集/立即播放几乎都是它）：解一层，拿到候选
        final next = await _resolveLazy(
          '${kHikerLazyPrefix}${lazySplit.id}',
          widget.item.title,
          widget.lazyChain,
          input: lazySplit.input,
        );
        if (!mounted) return;
        setState(() {
          _candidates = next;
          _busy = false;
          if (next.isEmpty) _error = '延迟规则执行后仍然没有可用地址';
        });
        _resolvedNote = '延迟规则第二趟：${next.length} 个候选';
        // 只解出**一个可直接打开**的候选时直接打开，省一次点击
        //（不限于直链：`pics://` 漫画、`novel://` 正文也算）。
        // ⚠️ 自动解析时不开播：用户要的是"自动取列表"，不是"进页面就跳播放器"。
        if (!auto && next.length == 1 && next.first.isOpenable) {
          await _play(next.first);
        }
        return;
      }

      // ── 条目地址自带**内联规则**（`#flags#@rule=js:…`）────────────────
      // 漫画源的「目录页」就是这么来的（实测漫小肆：
      // `详情页 + '#immersiveTheme##autoCache#@rule=js:$.require("er")'`）。
      // 以前整串被当成网页丢进 WebView ⇒ 只能看到漫画详情，永远出不来章节。
      final inline = splitHikerInlineRule(widget.item.url);
      if (inline != null) {
        final vars = HikerStore.instance.varsOf(src.id);
        final r = await HikerEngine.instance.inline(
          src,
          url: inline.base,
          code: inline.code,
          vars: vars,
        );
        await HikerStore.instance.saveVarsIfChanged(src.id, vars, r.vars);
        _lastVars = r.vars;
        _inline = inline;
        _nextPage = r.nextPage;
        _lastChain = widget.lazyChain;
        final closeCodes = r.listeners['onClose'];
        if (closeCodes != null) {
          for (final c in closeCodes) {
            if (_onClose.length >= 16) break;
            if (!_onClose.contains(c)) _onClose.add(c);
          }
        }
        if (!r.ok) {
          if (!mounted) return;
          setState(() => _error = r.error ?? '内联规则执行失败');
          return;
        }
        final next = _candidatesOf(r, '目录')
            // 源常把"当前这一页"也塞进结果（`MY_URL + '#noHistory#'`）——
            // 点它只会再开一遍网页，过滤掉
            .where((c) => _stripUrlFlags(c.url) != inline.base)
            .toList();
        if (!mounted) return;
        setState(() {
          _candidates = next;
          _busy = false;
          _resolvedNote =
              '内联规则 · 抓取 ${r.requests} 次 · ${(r.elapsedMs / 1000).toStringAsFixed(1)}s';
          if (next.isEmpty) _error = '这条内联规则没有给出内容';
        });
        // 只解出一条且可直接打开时才自动打开（自动解析时仍然只取列表）
        if (!auto && next.length == 1 && next.first.isOpenable) {
          await _play(next.first);
        }
        return;
      }

      if (src.detailFindRule.isNotEmpty) {
        final vars = HikerStore.instance.varsOf(src.id);
        final r = await HikerEngine.instance.detail(
          src,
          widget.item.url,
          vars: vars,
        );
        await HikerStore.instance.saveVarsIfChanged(src.id, vars, r.vars);
        _lastVars = r.vars;
        // 详情规则也能给「下一页」（漫画源常把下一章挂在这儿）
        _nextPage = r.nextPage;
        _lastChain = widget.lazyChain;
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
          // ⚠️ 详情规则**也会产出 lazyRule**（例如 XO 的「点击获取」兜底条目）。
          // 不标记 lazy 的话它会被当成 `hiker://` 内部页 → 点了只弹"不支持"，
          // 而且永远解不出第二层地址（2026-10-17 修）。
          final sp = splitHikerLazyUrl(it.url);
          final lazy = sp != null;
          out.add(
            _Candidate(
              it.url,
              it.title.isEmpty ? (lazy ? '延迟规则' : '详情规则') : it.title,
              lazy: lazy,
              chain: widget.lazyChain,
              input: sp?.input ?? '',
            ),
          );
        }
        _resolvedNote =
            '抓取 ${r.requests} 次 · ${(r.elapsedMs / 1000).toStringAsFixed(1)}s';
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

  /// 把一次规则结果（详情 / 内联 / 延迟）转成候选列表。
  ///
  /// 条目地址里带 `hiker://lazy#id` 的标记成 lazy（点它时再解一层）；
  /// 其余原样展示。`note` 是产出来源（目录 / 详情规则 / 选集 …）。
  List<_Candidate> _candidatesOf(
    HikerResult r,
    String note, {
    List<String> chain = const [],
  }) {
    final out = <_Candidate>[];
    if (r.playUrl.isNotEmpty) {
      out.add(_Candidate(r.playUrl, note, headers: r.playHeaders));
    }
    for (final u in r.playUrlExtra) {
      out.add(_Candidate(u, '备用清晰度', headers: r.playHeaders));
    }
    for (final it in r.list) {
      if (it.url.isEmpty) continue;
      final sp = splitHikerLazyUrl(it.url);
      final lazy = sp != null;
      out.add(
        _Candidate(
          it.url,
          it.title.isEmpty ? (lazy ? '选集' : note) : it.title,
          lazy: lazy,
          chain: chain,
          input: sp?.input ?? '',
          colType: it.colType,
          pic: it.pic,
        ),
      );
    }
    return out;
  }

  /// 解一层延迟规则（`hiker://lazy#<id>`）：
  /// 把 **父链 + 自己** 交给宿主去重跑（见 hiker_engine.js 的 lazyRuleImpl），
  /// 产出的候选里可能还有 lazy（海阔的"详情→选集→立即播放"就是链条）。
  Future<List<_Candidate>> _resolveLazy(
    String lazyUrl,
    String label,
    List<String> chain, {
    String input = '',
  }) async {
    // `lazyUrl` 可能是 `真实地址 + hiker://lazy#id`：拆出 id 与 input
    final sp = splitHikerLazyUrl(lazyUrl);
    final id = sp != null ? sp.id : lazyUrl;
    final realInput = (sp != null && sp.input.isNotEmpty) ? sp.input : input;
    final full = [...chain, id];
    _lastInput = realInput;

    final HikerResult r;
    final inline = _inline;
    if (inline != null) {
      // ⚠️ 内联规则的 lazy 定义在**那一次执行的作用域**里，宿主的
      //    home/category 重放根本没有这段 JS ⇒ 必须带同样的 code 再跑一趟。
      //    实测漫小肆：目录→章节→`pics://` 全靠这条。
      final vars = _lastVars.isEmpty
          ? HikerStore.instance.varsOf(widget.source.id)
          : _lastVars;
      r = await HikerEngine.instance.inline(
        widget.source,
        url: inline.base,
        code: inline.code,
        vars: vars,
        lazyIds: full,
        lazyInput: realInput,
      );
      await HikerStore.instance.saveVarsIfChanged(
        widget.source.id,
        vars,
        r.vars,
      );
    } else {
      final replay = widget.replayLazy;
      if (replay == null) {
        throw Exception('这个条目是延迟规则（lazyRule），当前入口无法执行');
      }
      r = await replay(full, lazyInput: realInput);
    }
    if (!r.ok) throw Exception(r.error ?? '规则执行失败');
    // 变量/事件回调照旧（onClose 清理靠它）
    _lastVars = r.vars;
    // 记录「下一页」与产出它的链条（看图页续章要用）
    _nextPage = r.nextPage;
    _lastChain = full;
    final closeCodes = r.listeners['onClose'];
    if (closeCodes != null) {
      for (final c in closeCodes) {
        if (_onClose.length >= 16) break;
        if (!_onClose.contains(c)) _onClose.add(c);
      }
    }
    final out = <_Candidate>[];
    if (r.playUrl.isNotEmpty) {
      out.add(
        _Candidate(
          r.playUrl,
          label.isEmpty ? '播放地址' : label,
          headers: r.playHeaders,
        ),
      );
    }
    for (final u in r.playUrlExtra) {
      out.add(_Candidate(u, '备用清晰度', headers: r.playHeaders));
    }
    for (final it in r.list) {
      if (it.url.isEmpty) continue;
      final sp = splitHikerLazyUrl(it.url);
      final lazy = sp != null;
      out.add(
        _Candidate(
          it.url,
          it.title.isEmpty ? (lazy ? '选集' : '地址') : it.title,
          lazy: lazy,
          chain: full,
          input: sp?.input ?? '',
          colType: it.colType,
          pic: it.pic,
        ),
      );
    }
    return out;
  }

  Future<void> _play(_Candidate c) async {
    // 候选地址自带内联规则（`#flags#@lazyRule=.js:…`）：源里的**排序 / 线路切换**
    // 按钮就是这种（实测漫小肆的「⇧」与线路 tab）。执行它 → 变量变了 → 重跑本页。
    final inline = splitHikerInlineRule(c.url);
    if (inline != null && !c.lazy) {
      await _runInlineAction(inline);
      return;
    }
    if (c.lazy) {
      // 又一层延迟规则（"立即播放"/选集）：再解一层，能出直链就直接播
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        final next = await _resolveLazy(c.url, c.note, c.chain, input: c.input);
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
        await _resolveAndPlay(url, c.headers);
        return;

      case HikerLinkKind.playJson:
        // 海阔的播放地址 JSON（`{"urls":["…m3u8"]}`）：**直链进播放器、否则进网页**
        // —— 用户 2026-10-16 要求的口径，也是官方 `parse` 字段的语义。
        final pj = hikerPlayJson(url);
        if (pj == null) {
          AppToast.error('这个播放地址解析不了：${_short(url)}');
          return;
        }
        // 源给的 header 作补充；调用方（详情规则）给的**优先**
        final pjHeaders = <String, String>{...pj.headers, ...c.headers};
        final direct = pj.urls.firstWhere(
          looksLikeDirectMedia,
          orElse: () => pj.urls.first,
        );
        await _resolveAndPlay(direct, pjHeaders);
        return;

      case HikerLinkKind.x5Play:
        // 官方语义：强制用播放器播这个地址 → 剥掉外壳再判一次
        final real = hikerStripScheme(url);
        await _resolveAndPlay(real, c.headers);
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

      case HikerLinkKind.search:
        // 官方「在某个源里搜索」深链（`hiker://search?rule=<源名>&s=<词>`）：
        // 聚合源/短剧惯例——详情规则给不出直链时，让你跳到对应源里搜片名。
        // 以前一律当内部页弹「不支持」，用户看到的就是「给了个搜索链接没法用」。
        await _openHikerSearch(url);
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
      case HikerLinkKind.videoWeb:
        // 都是"在网页里打开"：X5 全屏、强制网页、视频链接。
        // 统一进内嵌 WebView 播放器，由网页自己完成播放。
        await _pushWeb(hikerStripScheme(url), headers: c.headers);
        return;

      case HikerLinkKind.http:
        await _pushWeb(url, headers: c.headers);
        return;

      case HikerLinkKind.unknown:
        // 官方兜底也是这条文案
        AppToast.message('未知链接：${_short(url)}');
        return;
    }
  }

  /// 执行一条**点击型内联规则**（排序 / 切换线路这类），随后重跑本页规则刷新目录。
  Future<void> _runInlineAction(HikerInlineRule inline) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vars = _lastVars.isEmpty
          ? HikerStore.instance.varsOf(widget.source.id)
          : _lastVars;
      final r = await HikerEngine.instance.inline(
        widget.source,
        url: inline.base,
        code: inline.code,
        vars: vars,
      );
      await HikerStore.instance.saveVarsIfChanged(
        widget.source.id,
        vars,
        r.vars,
      );
      _lastVars = r.vars;
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    // 这类规则一般只改变量 + refreshPage()，内容要带上新变量重跑一次
    await _resolve();
  }

  /// 打开「海阔内置搜索」深链（`hiker://search?rule=<源名>&s=<关键词>`）。
  ///
  /// `rule` 是官方里的**源标题**（实测「聚阅√」的搜索框/条目地址都是它）。
  /// 找不到同名源就退回当前源；关键词为空时只是打开搜索页让用户输入。
  Future<void> _openHikerSearch(String url) async {
    final sp = parseHikerSearchUrl(url);
    if (sp == null) return;
    final src = _findSourceForSearch(sp.rule) ?? widget.source;
    if (sp.keyword.isNotEmpty && src.searchFind.trim().isEmpty) {
      AppToast.error('「${src.title}」没有搜索规则（searchFind）');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HikerSearchPage(
          source: src,
          initialKeyword: sp.keyword,
        ),
      ),
    );
  }

  /// 按源标题找源（官方 `rule=` 传的就是标题）；容忍结尾的 `√` 与空白差异
  static HikerSource? _findSourceForSearch(String rule) {
    final name = rule.trim();
    if (name.isEmpty) return null;
    final all = HikerStore.instance.sources;
    for (final s in all) {
      if (s.title == name) return s;
    }
    String norm(String v) => v.replaceAll(RegExp(r'[√\s]+$'), '').trim();
    final target = norm(name);
    if (target.isEmpty) return null;
    for (final s in all) {
      if (norm(s.title) == target) return s;
    }
    return null;
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

  /// 海阔媒体统一分发（2026-10-29 重构：与影视端共用 [PlayPipeline]）。
  ///
  /// 链路只有一条：
  ///   ① 直链 → 原生播放器；
  ///   ② 仍是网页 → 内嵌网页播放器兜底。
  Future<void> _resolveAndPlay(String url, Map<String, String> headers) async {
    final resolution = PlayPipeline.instance.resolve(
      url,
      headers: headers,
      apiBase: null,
    );
    switch (resolution.kind) {
      case PlayKind.media:
        return _pushPlayer(resolution.url, resolution.headers);
      case PlayKind.page:
        return _pushWeb(resolution.url, headers: resolution.headers);
      case PlayKind.novel:
      case PlayKind.pictures:
        // 这两类在 `hikerLinkKind` 分流时就已经进阅读器，这里只兜底不播。
        return;
    }
  }

  /// 进内嵌网页播放器。
  ///
  /// 海阔源经常只给网页、不给直链；进网页播放器后由用户自行在页面里点播。
  /// 保持**竖屏**（站点页面不是播放器，横屏只露一半）。
  Future<void> _pushWeb(String url, {Map<String, String> headers = const {}}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaybackSurface.webFallback(
          url: url,
          title: widget.item.title,
          forceLandscape: false,
        ),
      ),
    );
  }

  /// 进看图阅读器（漫画 / 图集共用）
  ///
  /// 源给了「下一页」（官方 `setNextPage`）就带上 [SimpleImageReaderPage.onLoadNextChapter]
  /// —— 用户一路往下滑会自动续章（对齐官方 `pics://` 的"下拉自动下一章"）。
  void _openImageReader(List<String> images, Map<String, String> headers) {
    // 海阔给条目/图片拼的 `@Referer=` 尾巴不是 URL 的一部分：
    // 空值表示"用来源页当 Referer"，有值则用它。不剥掉会整章图全加载失败。
    final clean = <String>[];
    var explicitReferer = '';
    var needPageReferer = false;
    for (final raw in images) {
      final sp = splitHikerReferer(raw);
      if (raw.contains('@Referer=')) {
        if (sp.referer.isEmpty) {
          needPageReferer = true;
        } else if (explicitReferer.isEmpty) {
          explicitReferer = sp.referer;
        }
      }
      if (sp.url.isNotEmpty) clean.add(sp.url);
    }
    final h = Map<String, String>.from(headers);
    final referer = explicitReferer.isNotEmpty
        ? explicitReferer
        : (needPageReferer ? _lastInput : '');
    if (referer.isNotEmpty) h.putIfAbsent('Referer', () => referer);
    AppLog.instance.log(
      '[Hiker] 图片列表 → 看图阅读器（${clean.length} 张）'
      '${referer.isEmpty ? '' : ' · Referer=$referer'}'
      '${_nextPage.isEmpty ? '' : ' · 有下一页，支持自动续章'}',
    );
    SimpleImageReaderPage.open(
      title: widget.item.title,
      images: clean,
      chapterName: widget.source.title,
      headers: h,
      onLoadNextChapter: _nextPage.isEmpty ? null : _loadNextChapterImages,
    );
  }

  /// 拉「下一章」：`nextPage` 还是 lazy 就带链条重跑，否则交给宿主当新页面跑一次。
  /// 返回 (新图片, 再下一页)。任何失败都返回空图片 —— 阅读器据此显示"没有下一章了"。
  Future<NextChapterResult> _loadNextChapterImages() async {
    final np = _nextPage;
    if (np.isEmpty) return (images: const <String>[], nextPage: '');
    HikerResult r;
    try {
      final sp = splitHikerLazyUrl(np);
      if (sp != null) {
        final replay = widget.replayLazy;
        if (replay == null) return (images: const <String>[], nextPage: '');
        r = await replay([..._lastChain, sp.id], lazyInput: sp.input);
      } else {
        final run = widget.runPage;
        if (run == null) return (images: const <String>[], nextPage: '');
        r = await run(np);
      }
    } catch (e) {
      AppLog.instance.log('[Hiker] 下一章拉取失败: $e');
      return (images: const <String>[], nextPage: '');
    }
    if (!r.ok) {
      AppLog.instance.log('[Hiker] 下一章规则报错: ${r.error}');
      return (images: const <String>[], nextPage: '');
    }
    _lastVars = r.vars;
    _nextPage = r.nextPage;
    return (images: _imagesOf(r), nextPage: _nextPage);
  }

  /// 从一次规则结果里抽出"这一页的图片"：`pics://` 优先，其次单图候选（去重保序）。
  static List<String> _imagesOf(HikerResult r) {
    final out = <String>[];
    for (final u in <String>[
      if (r.playUrl.isNotEmpty) r.playUrl,
      ...r.playUrlExtra,
    ]) {
      final pics = hikerPicList(u);
      if (pics != null && pics.isNotEmpty) {
        out.addAll(pics.map((p) => splitHikerReferer(p).url));
      }
    }
    for (final it in r.list) {
      final u = it.url;
      if (u.isEmpty || u.startsWith(kHikerLazyPrefix)) continue;
      final pics = hikerPicList(u);
      if (pics != null && pics.isNotEmpty) {
        out.addAll(pics.map((p) => splitHikerReferer(p).url));
        continue;
      }
      if (hikerLinkKind(u) == HikerLinkKind.image) {
        out.add(splitHikerReferer(u).url);
      }
    }
    final seen = <String>{};
    out.retainWhere(seen.add);
    return out;
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
          widget.item.title.isEmpty
              ? '(无标题)'
              : hikerPlainText(widget.item.title),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '复制条目地址',
            onPressed: it.url.isEmpty ? null : () => _copy(it.url),
            icon: Icon(
              Icons.copy_rounded,
              size: 18,
              color: AppTheme.textSecondary,
            ),
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
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _busy ? null : _playPrimary,
                    icon: _busy
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
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
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _busy ? null : _resolve,
                  child: Text(
                    '取地址',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontSubhead,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_resolvedNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '解析：$_resolvedNote',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                ),
              ),
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
                  Icon(
                    Icons.error_outline_rounded,
                    size: 18,
                    color: Colors.orange.shade400,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: AppTheme.fontFootnote,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // 用户 2026-10-18：「把简介放在解析结果前面」——
          // 先看简介再决定点哪条解析地址，顺序更自然。
          if (it.desc.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              '简介',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              it.desc,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
                height: 1.6,
              ),
            ),
          ],

          if (_candidates.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              '解析结果（${_candidates.length}）',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _candidateArea(),
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
    final pick = _candidates.firstWhere(
      (c) => !c.lazy,
      orElse: () => _candidates.first,
    );
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
                    child: Icon(
                      Icons.movie_outlined,
                      size: 26,
                      color: AppTheme.textTertiary,
                    ),
                  )
                : CachedNetworkImage(
                    imageUrl: it.pic,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        size: 22,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                it.title.isEmpty ? '(无标题)' : hikerPlainText(it.title),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              _infoRow('来源', widget.source.title),
              if (it.desc.isNotEmpty) _infoRow('备注', it.desc),
              if (it.colType.isNotEmpty) _infoRow('类型', it.colType),
              // 不再裸露 `hiker://lazy#14uwff4` 这种中间态地址 —— 翻成
              // 「延迟规则 · 点一次才算得出真地址」这样看得懂的话
              _infoRow(
                '地址',
                it.url.isEmpty ? '(空)' : describeHikerLinkText(it.url),
              ),
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
        Text(
          '$k：',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: AppTheme.fontCaption,
          ),
        ),
        Expanded(
          child: Text(
            v,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontCaption,
            ),
          ),
        ),
      ],
    ),
  );

  /// 候选区：**一行三个卡片**（用户 2026-10-16：卡片上是名称、点击直接播/开）。
  ///
  /// 源经常在候选中间插"分节标题"（`—— 选集（3 集）——`、`连播已就绪`）——
  /// 那些条目的地址是 `hiker://empty`，本身不可点。以前它们也被画成一行卡片
  /// 并带个「提示」按钮（点了只弹一句"不支持"），既误导又占地方；
  /// 现在这类**整行当纯文本标题**，其余可操作的排成三列卡片。
  Widget _candidateArea() {
    // 详情里出现「播放线路：」标记 → 按海阔官方布局分区渲染
    //（线路分组 / 标签 / 剧照 / 暂不可播，参考 huoyi hiker_miniapp 的 fromItems）。
    // 没有标记时保持原有平铺，向后兼容。
    if (_candidates.any(_isLineMarker)) return _groupedCandidates();
    final rows = <Widget>[];
    final pending = <_Candidate>[];
    void flush() {
      while (pending.isNotEmpty) {
        final n = pending.length >= 3 ? 3 : pending.length;
        final slice = pending.sublist(0, n);
        pending.removeRange(0, n);
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: i < slice.length
                        ? _candidateCard(slice[i])
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        );
      }
    }

    for (final c in _candidates) {
      if (_isLabel(c)) {
        flush();
        rows.add(_labelRow(c));
      } else {
        pending.add(c);
      }
    }
    flush();
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  /// 「播放线路：」/「播放线路」开头的分节标记
  static bool _isLineMarker(_Candidate c) =>
      _isLabel(c) && c.note.startsWith('播放线路');

  /// 「本片剧照」标记（或带图的分节条目兜底进剧照）
  static bool _isStillsMarker(_Candidate c) =>
      _isLabel(c) && c.note == '本片剧照';

  /// 「标签：」开头的分节标记
  static bool _isTagMarker(_Candidate c) =>
      _isLabel(c) && c.note.startsWith('标签：');

  /// 线路名：`播放线路：xxx` → xxx；空名回退「在线播放」
  static String _lineName(_Candidate c) {
    var name = c.note;
    if (name.startsWith('播放线路：')) {
      name = name.substring(5);
    } else if (name.startsWith('播放线路')) {
      name = name.substring(4);
    }
    final trimmed = name.trim();
    return trimmed.isEmpty ? '在线播放' : trimmed;
  }

  /// `标签：A·B·C` → [A, B, C]（兼容 `、` 分隔）
  static List<String> _splitTags(String note) {
    final raw = note.startsWith('标签：')
        ? note.substring(3)
        : note.startsWith('标签:')
        ? note.substring(3)
        : note;
    return [
      for (final part in raw.split(RegExp(r'[·、]')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  /// 详情含「播放线路：」标记时：按线路分组渲染 + 标签 / 剧照 / 暂不可播
  ///（参考 huoyi hiker_miniapp 的 `HikerMiniappDetail.fromItems` 语义）。
  Widget _groupedCandidates() {
    final groups = <_LineGroup>[];
    final tags = <String>[];
    final stills = <String>[];
    final unavailable = <_Candidate>[];
    final plainLabels = <_Candidate>[];
    _LineGroup? current;

    for (final c in _candidates) {
      if (_isLineMarker(c)) {
        current = _LineGroup(_lineName(c));
        groups.add(current);
      } else if (_isStillsMarker(c)) {
        if (c.pic.isNotEmpty) stills.add(c.pic);
      } else if (_isTagMarker(c)) {
        tags.addAll(_splitTags(c.note));
      } else if (_isLabel(c)) {
        // 其它不可点分节（如「立即播放」说明）保留原有居中样式
        plainLabels.add(c);
      } else if (!c.isOpenable && !c.lazy) {
        // 非 http / 打不开的选集 → 暂不可播（huoyi `unavailable` 同义）
        unavailable.add(c);
      } else {
        (current ??= _LineGroup('在线播放')).items.add(c);
      }
    }

    final rows = <Widget>[
      for (final label in plainLabels) _labelRow(label),
      for (final group in groups) ...[
        if (group.items.isNotEmpty) ...[
          const SizedBox(height: 10),
          _sectionTitle('播放线路：${group.name}'),
          ..._cardsRows(group.items),
        ],
      ],
      if (tags.isNotEmpty) ...[
        const SizedBox(height: 10),
        _sectionTitle('标签'),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundCard,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.borderLight),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontFootnote,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
      if (stills.isNotEmpty) ...[
        const SizedBox(height: 10),
        _sectionTitle('本片剧照'),
        const SizedBox(height: 8),
        _stillsRow(stills),
      ],
      if (unavailable.isNotEmpty) ...[
        const SizedBox(height: 10),
        _sectionTitle('暂不可播选集'),
        ..._cardsRows(unavailable, enabled: false),
      ],
    ];
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  /// 区块标题（左对齐加粗，贴合详情页现有字体体系）
  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        color: AppTheme.textPrimary,
        fontSize: AppTheme.fontSubhead,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  /// 候选 3 列卡片行（复用平铺逻辑；[enabled] 为 false 时不可点）
  List<Widget> _cardsRows(List<_Candidate> items, {bool enabled = true}) {
    final rows = <Widget>[];
    final pending = List.of(items);
    while (pending.isNotEmpty) {
      final n = pending.length >= 3 ? 3 : pending.length;
      final slice = pending.sublist(0, n);
      pending.removeRange(0, n);
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: i < slice.length
                      ? _candidateCard(slice[i], enabled: enabled)
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return rows;
  }

  /// 剧照横向滑动条
  Widget _stillsRow(List<String> stills) {
    return SizedBox(
      height: 128,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: stills.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final url = stills[index];
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: GestureDetector(
              onTap: () => _previewStills(stills, index),
              child: CachedNetworkImage(
                imageUrl: url,
                width: 88,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: 88,
                  color: AppTheme.backgroundTertiary,
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: 22,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 剧照预览（简单全屏看图）
  Future<void> _previewStills(List<String> stills, int index) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _StillsViewer(urls: stills, initialIndex: index),
      ),
    );
  }

  /// 不可点的"分节标题/说明"条目
  static bool _isLabel(_Candidate c) =>
      c.url.isEmpty || c.url == 'hiker://empty';

  Widget _labelRow(_Candidate c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text.rich(
        TextSpan(
          children: hikerRichSpans(
            c.note,
            TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _candidateCard(_Candidate c, {bool enabled = true}) {
    final (label, icon) = _actionOf(c);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => _play(c) : null,
      onLongPress: enabled ? () => _copy(c.url) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: enabled
              ? AppTheme.backgroundCard
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              c.note.isEmpty ? '(无标题)' : hikerPlainText(c.note),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: enabled
                    ? AppTheme.textPrimary
                    : AppTheme.textTertiary,
                fontSize: AppTheme.fontFootnote,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 13, color: AppTheme.accentOnSurface),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.accentOnSurface,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ),
              ],
            ),
            // 真正的内容：图片几张 / 正文多少字 / 视频直链 / 网页地址
            // （用户 2026-10-16：「取地址要给我图片、正文、视频直链」）
            if (!c.lazy && c.url.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                describeHikerLink(c.url).detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 卡片底部的动作文案 + 图标（lazy 候选点了会再解一层，所以是"打开"）
  static (String, IconData) _actionOf(_Candidate c) {
    if (c.lazy) return ('打开', Icons.touch_app_rounded);
    if (splitHikerInlineRule(c.url) != null) {
      return ('切换', Icons.tune_rounded);
    }
    return switch (hikerLinkKind(c.url)) {
      HikerLinkKind.media ||
      HikerLinkKind.playJson ||
      HikerLinkKind.x5Play => ('播放', Icons.play_arrow_rounded),
      HikerLinkKind.pics ||
      HikerLinkKind.image => ('看图', Icons.photo_library_rounded),
      HikerLinkKind.novel => ('阅读', Icons.menu_book_rounded),
      HikerLinkKind.search => ('搜索', Icons.search_rounded),
      HikerLinkKind.toast ||
      HikerLinkKind.copyLink ||
      HikerLinkKind.external ||
      HikerLinkKind.download ||
      HikerLinkKind.apk ||
      HikerLinkKind.hikerPage ||
      HikerLinkKind.unknown => ('提示', Icons.info_outline_rounded),
      _ => ('网页', Icons.language_rounded),
    };
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
          Text(
            k,
            style: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: AppTheme.fontCaption,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            v,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontFootnote,
            ),
          ),
        ],
      ),
    );
  }

  /// 去掉地址末尾的海阔 flag（`#noHistory#` / `#autoCache#` …），用于比"是不是同一页"
  static String _stripUrlFlags(String url) =>
      url.replaceFirst(RegExp(r'#+$'), '').trim();

  static String _short(String url) => url.length <= 70
      ? url
      : '${url.substring(0, 34)}…${url.substring(url.length - 30)}';
}

/// 剧照全屏预览（横向翻页，支持手势缩放）
class _StillsViewer extends StatefulWidget {
  const _StillsViewer({required this.urls, required this.initialIndex});

  final List<String> urls;
  final int initialIndex;

  @override
  State<_StillsViewer> createState() => _StillsViewerState();
}

class _StillsViewerState extends State<_StillsViewer> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          '${_index + 1} / ${widget.urls.length}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.urls.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, index) => Center(
          child: InteractiveViewer(
            maxScale: 4,
            child: CachedNetworkImage(
              imageUrl: widget.urls[index],
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(
                Icons.broken_image_outlined,
                size: 48,
                color: Colors.white38,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一条播放线路（「播放线路：xxx」标记之后、下一个标记之前的可播候选）
class _LineGroup {
  _LineGroup(this.name);

  final String name;
  final List<_Candidate> items = [];
}
