import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/miniapp/pages/mini_app_player_page.dart';
import 'package:tvbox/pages/detail/simple_image_reader_page.dart';
import 'package:tvbox/pages/detail/simple_text_reader_page.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/media_resolver.dart';
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
import 'package:tvbox/hiker/widgets/hiker_widgets.dart';
import 'package:tvbox/hiker/pages/hiker_search_page.dart';
import 'package:tvbox/hiker/pages/hiker_page_view.dart';

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
/// 解析结果的四个分组（2026-10-30）。
///
/// 按"点了会发生什么"分，而不是按脚本返回顺序 —— 脚本详情页里
/// 「倒序 / 清晰度 / 弹幕开关 / 剧集」这些操作项与真正的播放地址
/// 混在一起时，用户完全看不出哪个能播。
enum _CandGroup {
  /// 直链可播（m3u8 / mp4 / playJson / x5）
  play,

  /// 图片 / 图集
  image,

  /// 需要再打开一层（延迟规则 / 网页 / 阅读 / 搜索）
  open,

  /// 操作项与纯提示（弹幕开关 / 清晰度 / 剧集占位 / 说明）
  info,
}

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

  /// 简介是否已展开（长简介默认收 4 行，避免把「解析结果」顶出屏幕）
  bool _descOpen = false;

  /// 「操作与提示」组是否展开（默认收起）。
  ///
  /// 脚本详情页里「倒序 / 360p / 720p / 1080p / 弹幕：关 / 第46集」这类条目
  /// 往往占解析结果的大半（用户实测 55 条里 40+ 是这类），全铺出来会把
  /// 真正能播的地址埋掉 —— 默认折叠，点标题才展开。
  bool _infoOpen = false;

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

      case HikerLinkKind.hikerPageModule:
        // `hiker://page/<名>` —— **源自己的页面模块**（小程序的多页导航）。
        // 官方点开它就是执行那个模块的 rule 再铺一屏，不是"打开网页"。
        await _openPageModule(url);
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

  /// 打开**源自己的页面模块**（`hiker://page/<名>?参数`）—— 小程序的多页导航。
  ///
  /// 源里没有这个模块时给出明确原因：多半是它依赖海阔**内置页**
  /// （`hiker://page/lazy` 这类 App 自带的），而不是我们漏移植。
  Future<void> _openPageModule(String url) async {
    final pm = parseHikerPageUrl(url);
    if (pm == null) return;
    final src = widget.source;
    if (!src.hasPageModule(pm.module)) {
      AppToast.message(
        '「${src.title}」里没有名为 ${pm.module} 的页面模块'
        '（这个链接指向海阔内置页，App 不自带）',
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HikerPageView(
          source: src,
          module: pm.module,
          url: pm.url,
          args: pm.args,
          title: widget.item.title,
          lazyChain: widget.lazyChain,
        ),
      ),
    );
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
  ///
  /// [sourcePageUrl] = 这条直链是从哪个网页地址嗅探来的。传了播放页底栏
  /// 才会出现「线路」按钮（换一条解析线路 = 换个前缀重新嗅探）——
  /// 用户 2026-10-31：「播放器下面没有切换线路的按钮吗？不管是默认详情
  /// 里面的还是纯竖屏的播放器呢」。
  Future<void> _pushPlayer(
    String url,
    Map<String, String> headers, {
    String? sourcePageUrl,
    Map<String, String>? sourceHeaders,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MiniAppPlayerPage(
          url: url,
          title: widget.item.title,
          headers: headers.isEmpty ? null : headers,
          sourcePageUrl: sourcePageUrl,
          sourceHeaders: sourceHeaders ?? (headers.isEmpty ? null : headers),
        ),
      ),
    );
  }

  /// 海阔媒体统一分发（2026-10-29 重构：与影视端共用 [PlayPipeline]）。
  ///
  /// 链路（2026-10-31 补齐嗅探）：
  ///   ① 直链 → 原生播放器；
  ///   ② 网页 → **先在页面里嗅探**（离屏 WebView，和探针页「点击播放」同一条路），
  ///      抓出 m3u8/mp4 就进原生播放器；
  ///   ③ 嗅探也没出 → 内嵌网页播放器兜底（用户自己点）。
  ///
  /// 原来 ② 直接跳到 ③：海阔源给的多是解析站/播放站页面，进 WebView 后
  /// 要么被广告挡、要么要手动点两次才出画面，体验和影视端差一截。
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
        // 嗅探优先：抓不到才进网页兜底
        final sniffed = await _sniffThenPlay(resolution.url, resolution.headers);
        if (sniffed) return;
        return _pushWeb(resolution.url, headers: resolution.headers);
      case PlayKind.novel:
      case PlayKind.pictures:
        // 这两类在 `hikerLinkKind` 分流时就已经进阅读器，这里只兜底不播。
        return;
    }
  }

  /// 网页地址 → 嗅探出媒体直链就进原生播放器，返回 true。
  ///
  /// 和影视端 `detail/controller._sniffPageForMedia` 用**同一个**
  /// [MediaResolver.resolve]（`sniffFirst: true`），保证三端行为一致：
  /// 探针页测出来能播的地址，海阔里点播放也能播。
  Future<bool> _sniffThenPlay(String pageUrl, Map<String, String> headers) async {
    if (!pageUrl.startsWith('http')) return false;
    try {
      AppLog.instance.log('[Hiker] 网页地址先嗅探: $pageUrl');
      final found = await MediaResolver.instance.resolve(
        pageUrl,
        headers: headers,
        sniffFirst: true,
      );
      final trimmed = (found ?? '').trim();
      if (trimmed.isEmpty) {
        AppLog.instance.log('[Hiker] 嗅探没出地址，进网页播放器兜底');
        return false;
      }
      AppLog.instance.log('[Hiker] 嗅探命中，进原生播放器: $trimmed');
      // 把原始网页地址一起带进去 ⇒ 播放页底栏可以「换一条线路」重嗅
      await _pushPlayer(
        trimmed,
        headers,
        sourcePageUrl: pageUrl,
        sourceHeaders: headers,
      );
      return true;
    } catch (e) {
      AppLog.instance.w('[Hiker] 嗅探异常: $e');
      return false;
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
                  height: 44,
                  child: DecoratedBox(
                    // 主按钮给一层淡淡的主题色投影 —— 详情页只有一个"主动作"，
                    // 让它自己浮起来（原来和「取地址」是同一平面的两块方块）
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(13),
                      boxShadow: _busy
                          ? null
                          : [
                              BoxShadow(
                                color: AppTheme.accentColor.withValues(
                                  alpha: 0.28,
                                ),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                    ),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accentColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
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
                      label: Text(
                        _busy ? '解析中…' : '播放',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 44,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppTheme.borderMedium),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
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
          // 2026-10-29：包成卡片 + 超长可折叠（长简介以前会把「解析结果」整块顶出屏幕）
          //
          // 2026-10-30：**空简介也要显示**，内容写「无」。
          //   原来是 `if (it.desc.isNotEmpty)` 整块不画 —— 脚本没给简介时这一节
          //   凭空消失，用户以为界面少了东西（而且没法和"简介被解析错"区分）。
          //   现在固定出现：有内容就显示内容，没有就显示「无」。
          const SizedBox(height: 18),
          const HikerSectionTitle('简介'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
            decoration: BoxDecoration(
              color: AppTheme.backgroundCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.borderLight, width: 0.6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (it.desc.isEmpty)
                  Text(
                    '无',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead,
                      height: 1.65,
                    ),
                  )
                else ...[
                  Text(
                    it.desc,
                    maxLines: _descOpen ? null : 4,
                    overflow: _descOpen ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontSubhead,
                      height: 1.65,
                    ),
                  ),
                  if (it.desc.length > 80) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _descOpen = !_descOpen),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _descOpen ? '收起' : '展开全部',
                            style: TextStyle(
                              color: AppTheme.accentOnSurface,
                              fontSize: AppTheme.fontCaption,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Icon(
                            _descOpen
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            size: 15,
                            color: AppTheme.accentOnSurface,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),

          if (_candidates.isNotEmpty) ...[
            const SizedBox(height: 18),
            HikerSectionTitle('解析结果', count: _candidates.length),
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

  /// 头部信息区（用户 2026-10-29：「详情页界面能不优化美化呢」）
  ///
  /// 原来是「左封面 + 右四行 `键：值`」——四行灰字全是同一个字号，扫读时分不出
  /// 哪条重要。现在改成：封面（带投影）+ 标题 + 一排胶囊（来源 / 类型 / 地址
  /// 类型）+ 一行地址说明。「备注」不再重复出现在这里（下面「简介」卡片已经有了）。
  Widget _head(HikerItem it) {
    final link = describeHikerLink(it.url);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _cover(it),
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
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  HikerPill(
                    widget.source.title,
                    icon: Icons.source_rounded,
                    maxWidth: 150,
                  ),
                  if (it.colType.isNotEmpty)
                    HikerPill(
                      it.colType,
                      icon: Icons.sell_outlined,
                      maxWidth: 120,
                    ),
                  // 地址类型（视频直链 / 延迟规则 / 网页…）—— 原来藏在
                  // `地址：xxx` 那一行里，现在提成一眼可见的标签
                  if (it.url.isNotEmpty) HikerPill(link.kind, accent: true),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                it.url.isEmpty ? '这一步没有地址' : link.detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 详情页封面：圆角 + 投影，空图给占位图标
  Widget _cover(HikerItem it) {
    return Container(
      width: 100,
      height: 140,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
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
    );
  }

  /// 候选区：**一行三个卡片**（用户 2026-10-16：卡片上是名称、点击直接播/开）。
  ///
  /// 源经常在候选中间插"分节标题"（`—— 选集（3 集）——`、`连播已就绪`）——
  /// 那些条目的地址是 `hiker://empty`，本身不可点。以前它们也被画成一行卡片
  /// 并带个「提示」按钮（点了只弹一句"不支持"），既误导又占地方；
  /// 现在这类**整行当纯文本标题**，其余可操作的排成三列卡片。
  Widget _candidateArea() {
    // 详情里出现「播放线路：」标记 → 按海阔官方布局分区渲染
    //（线路分组 / 标签 / 剧照 / 暂不可播，参考 huoyi hiker_miniapp 的 fromItems）。
    // 没有标记时按"点了会发生什么"分组（见下）。
    if (_candidates.any(_isLineMarker)) return _groupedCandidates();

    // ── 2026-10-30：平铺分支改为**按动作类型分组** ──────────────────
    //
    // 用户：「是图片就是图片系列，是视频播放就是视频播放按钮」
    //      「排序、清晰度以及列表、弹幕都什么呀…分开分清楚」
    //
    // 原来一律三列平铺：脚本详情页里的「倒序 / 360p / 1080p / 弹幕：关 /
    // 第46集」与真正的播放地址长得一模一样，55 条挤在一起根本分不出
    // 哪个能播、哪个是图片、哪个只是个开关。现在分四段：
    //   · 可播放  → 三列卡片（播放图标）
    //   · 图片    → 缩略图网格（能直接看出是图）
    //   · 需要打开 → 三列卡片（网页 / 阅读 / 搜索 / 延迟规则）
    //   · 操作与提示 → 默认折叠，点标题展开
    final labels = <_Candidate>[];
    final metas = <_Candidate>[];
    final play = <_Candidate>[];
    final images = <_Candidate>[];
    final opens = <_Candidate>[];
    final infos = <_Candidate>[];
    for (final c in _candidates) {
      if (_isLabel(c)) {
        // 服务器错误页正文被脚本当成分节标题塞进来（用户截图：
        // 「Web server is returning an unknown error Error code 520」）。
        // 它不是标题、也不是能点的东西，画出来只会让人以为解析结果坏了 —— 丢掉。
        if (_isNoiseLabel(c)) continue;
        labels.add(c);
        continue;
      }
      // 「主演：…」「简介：…」这类是**元信息**，不是可点地址 ——
      // 用户 2026-10-30：「那些主演信息、视频简介也没正确对应」。
      // 原来它们被当成普通候选铺成卡片，和播放地址混在一起；
      // 这里抽出来单独成块（纯文本，不可点）。
      if (_isMetaLine(c)) {
        metas.add(c);
        continue;
      }
      switch (_groupOf(c)) {
        case _CandGroup.play:
          play.add(c);
        case _CandGroup.image:
          images.add(c);
        case _CandGroup.open:
          opens.add(c);
        case _CandGroup.info:
          infos.add(c);
      }
    }

    // 图片组里"取不出图片地址"的那些不能铺成缩略图 —— 那会是一排灰框
    // （用户截图：一格里只有个图片图标）。退回普通卡片，至少能看到是什么。
    final imgWithSrc = <_Candidate>[];
    final imgNoSrc = <_Candidate>[];
    for (final c in images) {
      (_firstImageOf(c).isEmpty ? imgNoSrc : imgWithSrc).add(c);
    }

    final rows = <Widget>[
      for (final l in labels) _labelRow(l),
      if (metas.isNotEmpty) ...[
        const SizedBox(height: 10),
        _metaBlock(metas),
      ],
      if (play.isNotEmpty) ...[
        const SizedBox(height: 10),
        _candGroupTitle(
            '可播放', play.length, Icons.play_circle_outline_rounded),
        ..._cardsRows(play),
      ],
      if (images.isNotEmpty) ...[
        const SizedBox(height: 10),
        _candGroupTitle('图片', images.length, Icons.photo_library_outlined),
        if (imgWithSrc.isNotEmpty) _imageTiles(imgWithSrc),
        if (imgNoSrc.isNotEmpty) ..._cardsRows(imgNoSrc),
      ],
      if (opens.isNotEmpty) ...[
        const SizedBox(height: 10),
        _candGroupTitle('需要打开', opens.length, Icons.open_in_new_rounded),
        ..._cardsRows(opens),
      ],
      if (infos.isNotEmpty) ...[
        const SizedBox(height: 10),
        _candGroupTitle(
          '操作与提示',
          infos.length,
          Icons.info_outline_rounded,
          trailing: _infoOpen ? '收起' : '展开',
          onTap: () => setState(() => _infoOpen = !_infoOpen),
        ),
        if (_infoOpen) ..._cardsRows(_collapseHints(infos)),
      ],
    ];
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  /// 把「操作与提示」里**同一句提示**的条目合并成一张卡。
  ///
  /// 实测（用户 2026-10-30 的截图）：一个 46 集的源，46 个条目全都是
  /// 「第N集 / 本集暂无720p」—— 展开之后是 46 张一模一样的卡片，
  /// 既看不出哪集不一样，也翻不到底。按提示文案分组后只剩一张：
  /// 「第1集 – 第46集（共46项）」。
  ///
  /// 只有一条的组原样返回（不改变单条时的观感）。
  static List<_Candidate> _collapseHints(List<_Candidate> items) {
    final groups = <String, List<_Candidate>>{};
    final order = <String>[];
    for (final c in items) {
      final key = describeHikerLink(c.url).detail.trim();
      if (!groups.containsKey(key)) order.add(key);
      groups.putIfAbsent(key, () => []).add(c);
    }
    final out = <_Candidate>[];
    for (final k in order) {
      final g = groups[k]!;
      if (g.length == 1) {
        out.add(g.first);
        continue;
      }
      final first = hikerPlainText(g.first.note);
      final last = hikerPlainText(g.last.note);
      out.add(
        _Candidate(
          g.first.url,
          hikerCollapsedHintTitle(first, last, g.length),
          lazy: g.first.lazy,
          chain: g.first.chain,
          headers: g.first.headers,
          input: g.first.input,
          colType: g.first.colType,
          pic: g.first.pic,
        ),
      );
    }
    return out;
  }

  /// 解析结果的分组维度 —— 按"点了会发生什么"，而不是按脚本给的顺序。
  static _CandGroup _groupOf(_Candidate c) {
    final (label, _) = _actionOf(c);
    return switch (label) {
      '播放' => _CandGroup.play,
      '看图' => _CandGroup.image,
      '打开' || '网页' || '阅读' || '搜索' => _CandGroup.open,
      _ => _CandGroup.info,
    };
  }

  /// 元信息行：`主演：岳训宇、李琦…` / `简介：…` / `类型：…`
  ///
  /// 这些是脚本详情页的**文字信息**，点了没有任何动作，不该占一个卡片位。
  static final RegExp _reMetaLine = RegExp(
    r'^(主演|导演|编剧|类型|地区|年份|语言|别名|简介|剧情简介|片长|更新时间|评分)\s*[:：]',
  );

  static bool _isMetaLine(_Candidate c) =>
      !c.lazy && _reMetaLine.hasMatch(c.note.trim());

  /// 元信息块：一行一条，纯文本不可点（与「简介」卡片同一套外观）
  Widget _metaBlock(List<_Candidate> items) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final c in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                hikerPlainText(c.note),
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 分组标题（图标 + 名字 + 条数；可带右侧「展开 / 收起」）
  Widget _candGroupTitle(
    String text,
    int count,
    IconData icon, {
    String? trailing,
    VoidCallback? onTap,
  }) {
    final row = Row(
      children: [
        Icon(icon, size: 14, color: AppTheme.accentOnSurface),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: 11.5,
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing,
            style: TextStyle(
              color: AppTheme.accentOnSurface,
              fontSize: AppTheme.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: onTap == null ? 0 : 5),
        child: row,
      ),
    );
  }

  /// 图片组：三列缩略图。
  ///
  /// 用户：「是图片就是图片系列」—— 图片类候选原来和播放地址用同一种卡片，
  /// 完全看不出是图；这里直接铺缩略图，一眼就是"图集"。
  Widget _imageTiles(List<_Candidate> items) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 3) {
      final end = (i + 3) > items.length ? items.length : i + 3;
      final slice = items.sublist(i, end);
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var j = 0; j < 3; j++) ...[
                if (j > 0) const SizedBox(width: 8),
                Expanded(
                  child: j < slice.length
                      ? _imageTile(slice[j])
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  Widget _imageTile(_Candidate c) {
    final src = _firstImageOf(c);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _play(c),
      onLongPress: () => _copy(c.url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: src.isEmpty
                  ? Container(
                      color: AppTheme.backgroundTertiary,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.photo_outlined,
                        size: 20,
                        color: AppTheme.textTertiary,
                      ),
                    )
                  : Image.network(
                      src,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: AppTheme.backgroundTertiary,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.broken_image_outlined,
                          size: 20,
                          color: AppTheme.textTertiary,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            c.note.isEmpty ? '图片' : hikerPlainText(c.note),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontCaption,
            ),
          ),
        ],
      ),
    );
  }

  /// 取一张能直接加载的图片地址：优先引擎给的 `pic`，
  /// 其次 `pics://a&&b` 里的第一张，最后才回退 http 地址。
  static String _firstImageOf(_Candidate c) {
    if (c.pic.trim().isNotEmpty) return c.pic.trim();
    final u = c.url.trim();
    if (u.startsWith('pics://')) {
      final first = u.substring(7).split('&&').first.trim();
      return first.startsWith('http') ? first : '';
    }
    return u.startsWith('http') ? u : '';
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
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final tag in tags) HikerPill(tag)],
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

  /// 区块标题（统一成「主题色竖条 + 加粗标题」，与主页 / 搜索页同一套观感）
  Widget _sectionTitle(String text) =>
      HikerSectionTitle(text, padding: const EdgeInsets.only(bottom: 4));

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

  /// 服务器错误页的正文 —— 脚本把 5xx 错误页当"标题"抓了回来。
  ///
  /// 用户 2026-10-30 的截图：解析结果里孤零零一行
  /// 「Web server is returning an unknown error Error code 520」。
  /// 那是源站返回的错误页文字，既不是标题也不是地址，画出来只会让人以为
  /// 解析结果坏了。判定逻辑见顶层 [hikerIsServerErrorText]。
  static bool _isNoiseLabel(_Candidate c) {
    final t = hikerPlainText(c.note).trim();
    if (t.isEmpty) return true;
    return hikerIsServerErrorText(t);
  }

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
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 9),
        decoration: BoxDecoration(
          color: enabled
              ? AppTheme.backgroundCard
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: enabled ? AppTheme.borderLight : Colors.transparent,
            width: 0.6,
          ),
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
                height: 1.3,
              ),
            ),
            const SizedBox(height: 7),
            // 动作标签做成小胶囊：一眼能看出这张卡是「播放 / 看图 / 阅读 / 打开」
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: enabled ? AppTheme.accentSurface : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 12,
                    color: enabled
                        ? AppTheme.accentOnSurface
                        : AppTheme.textTertiary,
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: enabled
                            ? AppTheme.accentOnSurface
                            : AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
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
      HikerLinkKind.hikerPageModule => (
        '打开页面',
        Icons.open_in_new_rounded,
      ),
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

// ============================================================
// 纯函数（与 UI 无关，单独抽出来是为了能直接测）
// ============================================================

/// 这行文字是不是**源站返回的错误页正文**（而不是脚本给的标题）。
///
/// 现场（用户 2026-10-30 截图）：解析结果里孤零零一行
/// `Web server is returning an unknown error Error code 520` ——
/// 源站 5xx 了，脚本把错误页的正文当成了分节标题。这类文字画出来
/// 只会让人以为解析结果坏了，应当直接丢掉。
///
/// ⚠️ 判据刻意很窄：**整行不含中文** 且命中错误码 / 网关固定措辞。
///   否则会误杀「第520集」「第 502 话」这种正常分节标题。
bool hikerIsServerErrorText(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(t)) return false;
  return _kServerErrorPattern.hasMatch(t);
}

final RegExp _kServerErrorPattern = RegExp(
  r'error code \d{3}|bad gateway|gateway time-?out|'
  r'internal server error|service (temporarily )?unavailable|'
  r'web server is returning|cloudflare|just a moment|enable javascript',
  caseSensitive: false,
);

/// 「操作与提示」合并卡片时的标题文案。
///
/// 例：46 条「第1集…第46集 / 本集暂无720p」合并成一张
/// `第1集 – 第46集（共46项）`。
String hikerCollapsedHintTitle(String first, String last, int count) {
  final a = first.trim();
  final b = last.trim();
  final String range;
  if (a.isEmpty && b.isEmpty) {
    range = '';
  } else if (a.isEmpty) {
    // 第一条没标题、最后一条有 —— 用有的那条，别把信息丢掉
    range = b;
  } else if (b.isEmpty || a == b) {
    range = a;
  } else {
    range = '$a – $b';
  }
  return range.isEmpty ? '共 $count 项' : '$range（共$count项）';
}
