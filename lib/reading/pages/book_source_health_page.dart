// lib/reading/pages/book_source_health_page.dart
//
// 銆屼功婧愪綋妫€銆嶉〉 鈥斺€?瀵归綈澶囦唤3.0 book_source_health_page锛圛MG_8554~8561锛夛細
//   绌洪棽椤?  锛氱浘鐗屽浘鏍?+ 娴佺▼鏂囨 + 骞跺彂鏁伴€夋嫨(1/2/3/4/6/8/12) + 寮€濮嬩綋妫€
//   杩涜涓?  锛氳繘搴?X/N + 骞跺彂 N + 鍙戠儹鎻愮ず + 瀹炴椂缁熻(鍙敤/缃戠粶婧愮珯寮傚父/瑙ｆ瀽澶辫触)
//   瀹屾垚椤?  锛氫綋妫€瀹屾垚路鏃堕棿 + 缁熻 + 鍒楄〃 + 鍏ㄩ€?+ 涓€閿紭鍖?+ 娓呯悊
// 寮曟搸鎺ョ嚎锛圢exhub WebBook锛夛細閫愭簮 鍙栦功(searchBook)鈫掕鎯?getBookInfo)
//   鈫掔洰褰?getChapterList)鈫掓鏂?getContent) 鍥涚幆鑺傦紝鍏ㄩ儴閫氳繃鎵嶇畻鍋ュ悍銆?
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../novel_source/model/book_source.dart';
import '../novel_source/model/search_book.dart';
import '../novel_source/model/xiaoshuo_book.dart';
import '../novel_source/model/xiaoshuo_book_chapter.dart';
import '../novel_source/shuyuan_source_service.dart';
import '../novel_source/web_book/web_book.dart';
import '../services/book_favorites_service.dart';
import '../services/shuyuan_source_store.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_search_bar.dart';

/// 浣撴杩涜鐘舵€?enum _Phase { idle, running, done }

/// 鏉＄洰灞曠ず鐘舵€侊紙鐢变綋妫€缁撴灉鎺ㄥ锛?enum _ItemState { untested, healthy, networkFail, parseFail }

/// 鍗曚釜婧愮殑浣撴缁撴灉
class _SourceHealth {
  final bool healthy;
  final Duration elapsed;
  final String detail;
  const _SourceHealth({
    required this.healthy,
    required this.elapsed,
    required this.detail,
  });
}

/// 澶辫触褰掔被锛氱綉缁?婧愮珯绫伙紙瓒呮椂/杩炴帴/4xx/5xx/楠岃瘉锛?vs 瑙ｆ瀽绫?enum _FailKind { network, parse }

class BookSourceHealthPage extends StatefulWidget {
  const BookSourceHealthPage({super.key});

  @override
  State<BookSourceHealthPage> createState() => _BookSourceHealthPageState();
}

class _BookSourceHealthPageState extends State<BookSourceHealthPage> {
  final WebBook _webBook = WebBook();

  _Phase _phaseVal = _Phase.idle;

  int _concurrency = 12;
  int _done = 0;

  /// 宸叉祴缁撴灉缂撳瓨锛堟寜婧?url锛?  final Map<String, _SourceHealth> _health = {};

  /// 缁熻 tab锛? 鍏ㄩ儴 / 1 鍙敤 / 4 缃戠粶寮傚父 / 5 瑙ｆ瀽澶辫触锛? 鏀惰棌 / 3 瀵嗛挜 鏃犳暟鎹淮搴︼級
  int _statTab = 0;

  /// 鍒嗙被锛? 鍏ㄩ儴 / 1 閫氬父涔︽簮 / 2 蹇€熶功婧?  int _groupTab = 0;

  final _searchCtrl = TextEditingController();
  String _kw = '';

  // 澶氶€夛細閫変腑鐨勬簮 url
  final Set<String> _selected = {};
  bool _selectAll = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _titleColor => _isDark ? Colors.white : JellyTheme.textPrimaryLight;
  Color get _subColor => _isDark ? Colors.white54 : JellyTheme.textSecondary;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ============================================================
  // 缁熻鎺ㄥ
  // ============================================================

  _ItemState _itemState(ShuyuanSource s) {
    final h = _health[s.bookSourceUrl];
    if (h == null) return _ItemState.untested;
    if (h.healthy) return _ItemState.healthy;
    final kind = _failKind(h.detail);
    return kind == _FailKind.network ? _ItemState.networkFail : _ItemState.parseFail;
  }

  int get _total => ShuyuanSourceStore.instance.allSources.length;
  int get _usable => ShuyuanSourceStore.instance.allSources
      .where((s) => _itemState(s) == _ItemState.healthy)
      .length;
  int get _networkFail => ShuyuanSourceStore.instance.allSources
      .where((s) => _itemState(s) == _ItemState.networkFail)
      .length;
  int get _parseFail => ShuyuanSourceStore.instance.allSources
      .where((s) => _itemState(s) == _ItemState.parseFail)
      .length;

  /// 鍒嗙被鍒嗙粍锛氱粍鍚嶅惈銆屽揩閫熴€嶁啋 蹇€熶功婧?  bool _isFast(ShuyuanSource s) =>
      (s.bookSourceGroup ?? '').contains('蹇€?);

  /// 璇ユ簮鏄惁鏈夎鏀惰棌鐨勪功锛堣鎯呴〉鏀惰棌鏃跺甫 sourceName锛?  bool _isFavoritedSource(ShuyuanSource s) => BookFavoritesService()
      .books
      .any((b) => (b.sourceName ?? '').isNotEmpty && b.sourceName == s.bookSourceName);

  /// 璇ユ簮鏄惁甯︾櫥褰曟€?瀵嗛挜锛坔eader 鍚?Cookie/token 绫诲瓧娈碉級
  bool _isKeyedSource(ShuyuanSource s) {
    final h = (s.header ?? '').toLowerCase();
    return h.contains('cookie') || h.contains('token') || h.contains('secret');
  }

  List<ShuyuanSource> get _filtered {
    var list =
        List<ShuyuanSource>.of(ShuyuanSourceStore.instance.allSources);
    if (_kw.isNotEmpty) {
      final k = _kw.trim().toLowerCase();
      list = list
          .where((s) => s.bookSourceName.toLowerCase().contains(k))
          .toList();
    }
    switch (_statTab) {
      case 1:
        list = list
            .where((s) => _itemState(s) == _ItemState.healthy)
            .toList();
      case 2:
        list = list.where(_isFavoritedSource).toList();
      case 3:
        list = list.where(_isKeyedSource).toList();
      case 4:
        list = list
            .where((s) => _itemState(s) == _ItemState.networkFail)
            .toList();
      case 5:
        list = list
            .where((s) => _itemState(s) == _ItemState.parseFail)
            .toList();
      default:
        break;
    }
    switch (_groupTab) {
      case 1:
        list = list.where((s) => !_isFast(s)).toList();
      case 2:
        list = list.where((s) => _isFast(s)).toList();
      default:
        break;
    }
    return list;
  }

  int get _fastCount =>
      ShuyuanSourceStore.instance.allSources.where((s) => _isFast(s)).length;
  int get _normalCount =>
      ShuyuanSourceStore.instance.allSources.where((s) => !_isFast(s)).length;
  int get _favoritedCount => ShuyuanSourceStore.instance.allSources
      .where(_isFavoritedSource)
      .length;
  int get _keyedCount =>
      ShuyuanSourceStore.instance.allSources.where(_isKeyedSource).length;

  // ============================================================
  // 浣撴寮曟搸锛圢exhub WebBook 鍥涚幆鑺傦級
  // ============================================================

  _FailKind _failKind(String detail) {
    final d = detail.toLowerCase();
    if (d.contains('timeout') ||
        d.contains('瓒呮椂') ||
        d.contains('connection') ||
        d.contains('杩炴帴') ||
        d.contains('socket') ||
        d.contains('dioexception') ||
        d.contains('status code') ||
        d.contains('http 4') ||
        d.contains('http 5') ||
        d.contains('403') ||
        d.contains('404') ||
        d.contains('500') ||
        d.contains('楠岃瘉')) {
      return _FailKind.network;
    }
    return _FailKind.parse;
  }

  /// 閫愭簮浣撴锛氬彇涔︹啋璇︽儏鈫掔洰褰曗啋姝ｆ枃銆?  /// 鍏抽敭瀛楀浐瀹氱敤澶т紬涔﹀悕銆屽ぇ濂夋墦鏇翠汉銆嶏紙涓庝功婧愪粨搴撲綋妫€鍙ｅ緞涓€鑷达級銆?  Future<_SourceHealth> _healthCheckOne(ShuyuanSource source) async {
    final sw = Stopwatch()..start();
    try {
      final src = source.toBookSource();
      final results = await _webBook.searchBook(source: src, key: '澶у鎵撴洿浜?);
      if (results == null || results.isEmpty) {
        return _SourceHealth(
            healthy: false, elapsed: sw.elapsed, detail: '鎼滅储鏃犵粨鏋?);
      }
      final first = results.first;
      // 璇︽儏
      final info = await _webBook.getBookInfo(
        source: src,
        bookUrl: first.bookUrl,
      );
      // 鐩綍
      final chapters = await _webBook.getChapterList(
        source: src,
        book: info,
      );
      if (chapters.isEmpty) {
        return _SourceHealth(
            healthy: false, elapsed: sw.elapsed, detail: '鐩綍涓虹┖');
      }
      // 姝ｆ枃锛堢涓€绔狅級
      final content = await _webBook.getContent(
        source: src,
        chapterUrl: chapters.first.url,
        originalBook: info,
      );
      if (content.content.trim().isEmpty) {
        return _SourceHealth(
            healthy: false, elapsed: sw.elapsed, detail: '姝ｆ枃涓虹┖');
      }
      return _SourceHealth(
        healthy: true,
        elapsed: sw.elapsed,
        detail: '鍙栦功鈫掕鎯呪啋鐩綍鈫掓鏂?鍏ㄩ儴閫氳繃',
      );
    } catch (e) {
      final msg = e.toString();
      return _SourceHealth(
          healthy: false, elapsed: sw.elapsed, detail: msg);
    }
  }

  Future<void> _start() async {
    setState(() {
      _phaseVal = _Phase.running;
      _done = 0;
      _health.clear();
    });
    final all = ShuyuanSourceStore.instance.allSources;
    // 骞跺彂鍒嗗潡锛氭寜 _concurrency 涓€缁勪竴缁勮窇
    for (var i = 0; i < all.length; i += _concurrency) {
      final batch = all.skip(i).take(_concurrency).toList();
      final results = await Future.wait(batch.map(_healthCheckOne));
      if (!mounted) return;
      for (var j = 0; j < batch.length; j++) {
        _health[batch[j].bookSourceUrl] = results[j];
      }
      _done += batch.length;
      setState(() {});
    }
    if (!mounted) return;
    setState(() {
      _phaseVal = _Phase.done;
      _done = _total;
    });
  }

  Future<void> _optimize() async {
    final usable = ShuyuanSourceStore.instance.allSources
        .where((s) => _itemState(s) == _ItemState.healthy)
        .toList();
    final bad = ShuyuanSourceStore.instance.allSources
        .where((s) =>
            _itemState(s) == _ItemState.networkFail ||
            _itemState(s) == _ItemState.parseFail)
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('涓€閿紭鍖?, style: TextStyle(fontSize: AppTheme.fontHeadline)),
        content: Text(
          '灏嗘妸 ${usable.length} 涓彲鐢ㄦ簮缃《锛?
          '骞跺仠鐢?${bad.length} 涓綉缁?婧愮珯寮傚父鎴栬В鏋愬け璐ョ殑婧?
          '锛堜笉鍒犻櫎锛屽彲鍐嶆浣撴鎭㈠锛夈€傜‘瀹氱户缁紵',
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('鍙栨秷')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('浼樺寲')),
        ],
      ),
    );
    if (ok != true) return;
    // 鍙敤婧愮疆椤讹紙鎸夊師椤哄簭锛夛紝鍏朵綑淇濇寔鍘熼『搴忓湪鍚?    final ordered = <String>[
      ...usable.map((s) => s.bookSourceUrl),
      ...ShuyuanSourceStore.instance.allSources
          .where((s) => !usable.contains(s))
          .map((s) => s.bookSourceUrl),
    ];
    await ShuyuanSourceStore.instance.reorder(ordered);
    for (final s in bad) {
      if (s.enabled) {
        await ShuyuanSourceStore.instance.setEnabled(s.bookSourceUrl, false);
      }
    }
    if (mounted) {
      _toast('宸蹭紭鍖栵細缃《 ${usable.length} 涓彲鐢ㄦ簮锛屽仠鐢?${bad.length} 涓け璐ユ簮');
    }
  }

  Future<void> _cleanup() async {
    final n = _selected.length;
    if (n == 0) {
      _toast('璇峰厛鍕鹃€夎娓呯悊鐨勪功婧?);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('娓呯悊涔︽簮', style: TextStyle(fontSize: AppTheme.fontHeadline)),
        content: Text(
          '灏嗗垹闄?$n 涓功婧愶紝鍒犻櫎鍚庝笉鍙仮澶嶏紝纭畾缁х画锛?,
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('鍙栨秷')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('鍒犻櫎', style: TextStyle(color: JellyTheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final url in _selected.toList()) {
      await ShuyuanSourceStore.instance.removeSource(url);
    }
    setState(() => _selected.clear());
    _toast('宸插垹闄?$n 涓功婧?);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: AppTheme.fontFootnote)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ============================================================
  // 鏋勫缓
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark;
    return Scaffold(
      backgroundColor: isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        backgroundColor: isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: _titleColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '涔︽簮浣撴',
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
            color: _titleColor,
          ),
        ),
        actions: [
          Icon(Icons.shield_rounded, size: 18, color: _subColor),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '閲嶆柊浣撴',
            icon: Icon(Icons.refresh_rounded, size: 20, color: _titleColor),
            onPressed: _phaseVal == _Phase.running ? null : _start,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _phaseVal == _Phase.idle
                ? ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    children: _buildIdle(),
                  )
                : CustomScrollView(
                    slivers: [
                      // 鍥哄畾澶达細杩涘害/缁熻/鎼滅储/缁熻tab/鍒嗙粍tab锛堟噿鍔犺浇涓嶅弬涓庯級
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: _buildResultHeader(),
                          ),
                        ),
                      ),
                      // 婧愭潯鐩細SliverList.builder 鎳掑姞杞?                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        sliver: SliverList.builder(
                          itemCount: _filtered.length,
                          itemBuilder: (context, i) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _itemTile(_filtered[i]),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          if (_phaseVal != _Phase.idle) _buildBottomBar(),
        ],
      ),
    );
  }

  // 鈹€鈹€ 绌洪棽椤碉紙8554锛夆攢鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
  List<Widget> _buildIdle() {
    return [
      const SizedBox(height: 60),
      Icon(Icons.verified_user_rounded, size: 48, color: JellyTheme.primary),
      const SizedBox(height: 20),
      Center(
        child: Text(
          '閫愭簮浣撴锛氬彇涔︹啋璇︽儏鈫掔洰褰曗啋姝ｆ枃',
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: FontWeight.w600,
            color: _titleColor,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Center(
        child: Text(
          '鎼滅储銆屽ぇ濂夋墦鏇翠汉銆嶉€愭簮楠岃瘉锛岄獙璇佺爜/瓒呮椂/403/5xx 璁″叆缃戠粶鎴栨簮绔欏紓甯?,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: AppTheme.fontFootnote, color: _subColor),
        ),
      ),
      const SizedBox(height: 44),
      Center(
        child: Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [1, 2, 3, 4, 6, 8, 12]
              .map((n) => _concurrencyChip(n))
              .toList(),
        ),
      ),
      const SizedBox(height: 40),
      Center(
        child: GestureDetector(
          onTap: _start,
          child: Container(
            width: 220,
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              color: JellyTheme.primary,
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Center(
              child: Text(
                '寮€濮嬩綋妫€',
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 40),
    ];
  }

  Widget _concurrencyChip(int n) {
    final sel = n == _concurrency;
    return GestureDetector(
      onTap: () => setState(() => _concurrency = n),
      child: Container(
        width: 46,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel
              ? (JellyTheme.primary.withValues(alpha: 0.14))
              : (_isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: sel ? JellyTheme.primary : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: Text(
          sel ? '鉁?$n' : '$n',
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? JellyTheme.primary : _titleColor,
          ),
        ),
      ),
    );
  }

  // 鈹€鈹€ 杩涜涓?/ 瀹屾垚椤碉紙8555~8561锛夆攢鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
  // 鍥哄畾澶撮儴鍒嗭紙鎳掑姞杞?SliverToBoxAdapter 鐢級锛屾簮鏉＄洰鐢?SliverList.builder 鎻愪緵
  List<Widget> _buildResultHeader() {
    final running = _phaseVal == _Phase.running;
    final doneTime = _fmtTime(DateTime.now());
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              running
                  ? '浣撴涓?$_done/$_total锛堝彇涔︹啋璇︽儏鈫掔洰褰曗啋姝ｆ枃锛?
                  : '浣撴瀹屾垚路$doneTime',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
                color: _titleColor,
              ),
            ),
          ),
          Text(
            '骞跺彂 $_concurrency',
            style: TextStyle(fontSize: AppTheme.fontFootnote, color: _subColor),
          ),
        ],
      ),
      if (running) ...[
        const SizedBox(height: 6),
        Text(
          '鍚庡彴澶氱嚎绋嬩綋妫€浼氫娇鎵嬫満鍙戠儹锛屽睘姝ｅ父鐜拌薄',
          style: TextStyle(fontSize: AppTheme.fontCaption, color: _subColor),
        ),
      ],
      const SizedBox(height: 12),
      Row(
        children: [
          _statPill('鍙敤', _usable, Colors.green),
          const SizedBox(width: 10),
          _statPill('缃戠粶/婧愮珯寮傚父', _networkFail, Colors.orange),
          const SizedBox(width: 10),
          _statPill('瑙ｆ瀽澶辫触', _parseFail, JellyTheme.error),
        ],
      ),
      const SizedBox(height: 14),
      JellySearchBar(
        controller: _searchCtrl,
        hintText: '鎼滅储涔︽簮',
        onChanged: (v) => setState(() => _kw = v.trim()),
        onCleared: () => setState(() => _kw = ''),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          _numTab(0, '鎬绘暟', _total),
          _numTab(1, '鍙敤', _usable),
          _numTab(2, '鏀惰棌', _favoritedCount),
          _numTab(3, '瀵嗛挜', _keyedCount),
          _numTab(4, '缃戠粶/婧愮珯寮傚父', _networkFail),
          _numTab(5, '瑙ｆ瀽澶辫触', _parseFail),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          _groupTabChip(0, '鍏ㄩ儴', _total),
          const SizedBox(width: 8),
          _groupTabChip(1, '閫氬父涔︽簮', _normalCount),
          const SizedBox(width: 8),
          _groupTabChip(2, '蹇€熶功婧?, _fastCount),
        ],
      ),
      const SizedBox(height: 12),
      if (_filtered.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 60),
          child: Center(
            child: Text(
              '鏆傛棤鍙敤鐨勬簮',
              style: TextStyle(fontSize: AppTheme.fontSubhead, color: _subColor),
            ),
          ),
        ),
      const SizedBox(height: 4),
    ];
  }

  String _fmtTime(DateTime t) =>
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _statPill(String label, int n, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label $n',
        style: TextStyle(
          fontSize: AppTheme.fontFootnote,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _numTab(int index, String label, int n) {
    final sel = _statTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _statTab = index),
        child: Column(
          children: [
            Text(
              '$n',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w700,
                color: sel ? JellyTheme.primary : _titleColor,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              label,
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                color: sel ? JellyTheme.primary : _subColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupTabChip(int index, String label, int n) {
    final sel = _groupTab == index;
    return GestureDetector(
      onTap: () => setState(() => _groupTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: sel
              ? JellyTheme.primary.withValues(alpha: 0.14)
              : (_isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: sel ? JellyTheme.primary : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Text(
          '$label $n',
          style: TextStyle(
            fontSize: AppTheme.fontCaption,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? JellyTheme.primary : _titleColor,
          ),
        ),
      ),
    );
  }

  // 鈹€鈹€ 鍒楄〃鏉＄洰 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
  Widget _itemTile(ShuyuanSource s) {
    final state = _itemState(s);
    final h = _health[s.bookSourceUrl];
    final selected = _selected.contains(s.bookSourceUrl);
    final (Color color, IconData icon, String sub) = switch (state) {
      _ItemState.healthy => (
          Colors.green,
          Icons.check_circle_rounded,
          '${h!.elapsed.inMilliseconds}ms路${h.detail}',
        ),
      _ItemState.networkFail => (
          Colors.orange,
          Icons.wifi_off_rounded,
          h!.detail,
        ),
      _ItemState.parseFail => (
          JellyTheme.error,
          Icons.error_rounded,
          h!.detail,
        ),
      _ItemState.untested => (
          _subColor,
          Icons.radio_button_unchecked_rounded,
          '灏氭湭浣撴',
        ),
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        if (selected) {
          _selected.remove(s.bookSourceUrl);
        } else {
          _selected.add(s.bookSourceUrl);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? JellyTheme.primary
                    : (_isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
                border: Border.all(
                  color: selected
                      ? JellyTheme.primary
                      : _subColor.withValues(alpha: 0.4),
                  width: 1.2,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.bookSourceName,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: _titleColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(icon, size: 12, color: color),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          sub,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption, color: color),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 鈹€鈹€ 搴曢儴鎿嶄綔鏉★細鍏ㄩ€?/ 涓€閿紭鍖?/ 娓呯悊 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
  Widget _buildBottomBar() {
    final list = _filtered;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        decoration: BoxDecoration(
          color: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() {
                _selectAll = !_selectAll;
                if (_selectAll) {
                  _selected
                    ..clear()
                    ..addAll(list.map((s) => s.bookSourceUrl));
                } else {
                  _selected.clear();
                }
              }),
              icon: Icon(
                _selectAll
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 18,
                color: _titleColor,
              ),
              label: Text(
                _selectAll ? '鍙栨秷鍏ㄩ€? : '鍏ㄩ€?,
                style: TextStyle(fontSize: AppTheme.fontFootnote, color: _titleColor),
              ),
            ),
            const Spacer(),
            if (_phaseVal == _Phase.done) ...[
              IconButton(
                tooltip: '涓€閿紭鍖?,
                icon: Icon(Icons.auto_fix_high_rounded, size: 20, color: JellyTheme.primary),
                onPressed: _usable > 0 ? _optimize : null,
              ),
              const SizedBox(width: 4),
            ],
            TextButton.icon(
              onPressed: _selected.isEmpty ? null : _cleanup,
              icon: Icon(Icons.delete_outline_rounded, size: 18, color: JellyTheme.error),
              label: Text(
                '娓呯悊',
                style: TextStyle(fontSize: AppTheme.fontFootnote, color: JellyTheme.error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

