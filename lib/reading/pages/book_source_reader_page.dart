import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../services/book_source_service.dart';

/// 书源在线阅读器。
///
/// ── 为什么不复用 `BookReaderPage` ──────────────────────────────
/// cmbok 的 `BookReaderPage` 吃的是 `BookContent`（整本书一次性解析好的
/// 本地文件），入口是 `BookDownloadTask` + 本地字节流。
/// 书源是**在线逐章抓取**：章节数量几十上百，不可能进页面就把全书拉下来。
/// 硬塞进旧阅读器要改它的加载链路（侵入很大、且会波及本地书那条路径）。
/// 所以这里做一个**同风格**的在线阅读器，共用同一套配色与翻页手势。
///
/// ── 关键设计 ──────────────────────────────────────────────────
///   · **懒加载 + 预取**：只抓当前章，同时后台预取下一章（翻页不卡）
///   · **缓存**：同一章重复读不再抓（缓存上限，防长篇小说吃爆内存）
///   · **进度持久化**：书名+源 作为 key，回来能续读
class BookSourceReaderPage extends StatefulWidget {
  const BookSourceReaderPage({
    super.key,
    required this.source,
    required this.bookName,
    required this.author,
    required this.chapters,
    this.initialIndex = 0,
  });

  final BookSource source;
  final String bookName;
  final String author;
  final List<BookSourceChapter> chapters;
  final int initialIndex;

  @override
  State<BookSourceReaderPage> createState() => _BookSourceReaderPageState();
}

class _BookSourceReaderPageState extends State<BookSourceReaderPage> {
  late int _index;
  late final PageController _pageCtrl;

  /// 章节内容缓存：章节下标 → 段落列表
  final Map<int, List<String>> _cache = {};
  static const int _cacheLimit = 12;

  bool _loading = false;
  String? _error;
  List<String> _paragraphs = const [];

  /// 字号 / 行距 / 背景（与设置页同一把尺子）
  double _fontSize = 18;
  double _lineHeight = 1.9;
  int _bgIndex = 0;
  bool _showBar = true;

  static const _bgs = <List<Color>>[
    [Color(0xFFFFFFFF), Color(0xFF1A1A1A)], // 白
    [Color(0xFFF5EFE0), Color(0xFF3A3226)], // 米黄
    [Color(0xFFC7E0C0), Color(0xFF23301F)], // 护眼绿
    [Color(0xFF2B2B2B), Color(0xFFB8B8B8)], // 夜间
  ];

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.chapters.length - 1);
    _pageCtrl = PageController();
    _restorePrefs();
    _loadChapter(_index);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  // ── 偏好与进度 ──────────────────────────────────────────────

  String get _progressKey =>
      'bsr.progress.${widget.source.id}.${widget.bookName}';

  Future<void> _restorePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final fs = p.getDouble('reading.fontSize');
      final lh = p.getDouble('reading.lineHeight');
      final bg = p.getInt('reading.bgIndex');
      // 只在用户**没有从详情页指定章节**时才恢复进度，
      // 否则点"第 5 章"却被跳到上次读到的地方就很怪。
      final savedIdx = p.getInt(_progressKey);
      if (!mounted) return;
      setState(() {
        if (fs != null && fs >= 12 && fs <= 30) _fontSize = fs;
        if (lh != null && lh >= 1.2 && lh <= 3.0) _lineHeight = lh;
        if (bg != null && bg >= 0 && bg < _bgs.length) _bgIndex = bg;
        if (widget.initialIndex == 0 &&
            savedIdx != null &&
            savedIdx > 0 &&
            savedIdx < widget.chapters.length) {
          _index = savedIdx;
        }
      });
      if (_index != widget.initialIndex) _loadChapter(_index);
    } catch (_) {
      // 偏好读不到就用默认值，不影响阅读
    }
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('reading.fontSize', _fontSize);
      await p.setDouble('reading.lineHeight', _lineHeight);
      await p.setInt('reading.bgIndex', _bgIndex);
    } catch (_) {}
  }

  Future<void> _saveProgress() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_progressKey, _index);
    } catch (_) {}
  }

  // ── 章节加载 ────────────────────────────────────────────────

  Future<void> _loadChapter(int i, {bool prefetchOnly = false}) async {
    if (i < 0 || i >= widget.chapters.length) return;

    // 命中缓存：直接切换
    if (_cache.containsKey(i)) {
      if (!prefetchOnly) {
        setState(() {
          _paragraphs = _cache[i]!;
          _loading = false;
          _error = null;
        });
      }
      _prefetch(i + 1);
      return;
    }

    if (!prefetchOnly) {
      setState(() {
        _loading = true;
        _error = null;
        _paragraphs = const [];
      });
    }

    final ch = widget.chapters[i];
    try {
      final r = await BookSourceService.instance.content(widget.source, ch.url);
      if (!mounted) return;
      if (!r.ok) {
        if (!prefetchOnly) {
          setState(() {
            _loading = false;
            _error = r.error ?? '正文获取失败';
          });
        }
        return;
      }
      final paras = _splitParagraphs(r.content);
      _cache[i] = paras;
      _evictIfNeeded();
      if (!prefetchOnly) {
        setState(() {
          _paragraphs = paras;
          _loading = false;
          _error = null;
        });
        _pageCtrl.jumpTo(0);
        await _saveProgress();
      }
      _prefetch(i + 1);
    } catch (e) {
      if (!prefetchOnly && mounted) {
        setState(() {
          _loading = false;
          _error = '加载失败：$e';
        });
      }
    }
  }

  /// 预取下一章 —— 翻页体验的关键。
  /// 不预取的话每次翻章都要等一次网络往返，长篇小说会非常难受。
  void _prefetch(int i) {
    if (i < 0 || i >= widget.chapters.length) return;
    if (_cache.containsKey(i)) return;
    // 不 await：后台跑，失败也不影响当前阅读
    _loadChapter(i, prefetchOnly: true);
  }

  /// 缓存超限时丢掉离当前位置最远的章节
  void _evictIfNeeded() {
    if (_cache.length <= _cacheLimit) return;
    final keys = _cache.keys.toList()
      ..sort((a, b) => (b - _index).abs().compareTo((a - _index).abs()));
    while (_cache.length > _cacheLimit && keys.isNotEmpty) {
      _cache.remove(keys.removeAt(0));
    }
  }

  /// 把抓到的正文切成段落。
  ///
  /// 书源返回的正文形态不统一：有的每段换行，有的用 `<br>`（引擎已转成 \n），
  /// 有的还带前后空白、连续空行。这里统一清洗，
  /// 否则段间距会忽大忽小、出现大片空白。
  List<String> _splitParagraphs(String raw) {
    final out = <String>[];
    for (var line in raw.split('\n')) {
      line = line.replaceAll('\r', '').trim();
      if (line.isEmpty) continue;
      // 全角空格也当空白去掉
      line = line.replaceAll('\u3000', ' ').trim();
      if (line.isEmpty) continue;
      out.add(line);
    }
    return out;
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0) {
      _toast('已经是第一章');
      return;
    }
    if (next >= widget.chapters.length) {
      _toast('已经是最后一章');
      return;
    }
    setState(() => _index = next);
    _loadChapter(next);
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(m),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ));
  }

  // ── UI ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bg = _bgs[_bgIndex];
    return Scaffold(
      backgroundColor: bg[0],
      body: GestureDetector(
        // 点屏幕中间切换菜单栏；点左/右 1/3 翻章
        onTapUp: (d) {
          final w = MediaQuery.of(context).size.width;
          final x = d.globalPosition.dx;
          if (_showBar) {
            setState(() => _showBar = false);
            return;
          }
          if (x < w * 0.3) {
            _go(-1);
          } else if (x > w * 0.7) {
            _go(1);
          } else {
            setState(() => _showBar = true);
          }
        },
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(child: _contentArea(bg[1])),
                  _bottomNav(bg[1]),
                ],
              ),
              if (_showBar) _topBar(bg[1]),
              if (_showBar) _settingsPanel(bg[1]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _contentArea(Color fg) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 14),
            Text('正在加载正文...',
                style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.6))),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 44, color: fg.withValues(alpha: 0.4)),
              const SizedBox(height: 14),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.7))),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => _loadChapter(_index),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
              TextButton.icon(
                onPressed: () => _go(1),
                icon: const Icon(Icons.skip_next_rounded),
                label: const Text('看下一章'),
              ),
            ],
          ),
        ),
      );
    }
    if (_paragraphs.isEmpty) {
      return Center(
        child: Text('这一章没有正文',
            style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.6))),
      );
    }
    return PageView(
      controller: _pageCtrl,
      // 暂不分页，整章一页滚动 —— 分页需要按可用高度逐段度量，
      // 那是 cmbok 分页器的活儿；在线阅读先保证"能看到内容"，
      // 分页留作下一步（见文件末尾说明）。
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.chapters[_index].name,
                style: TextStyle(
                  fontSize: _fontSize + 3,
                  fontWeight: FontWeight.w700,
                  color: fg,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              for (final p in _paragraphs)
                Padding(
                  padding: EdgeInsets.only(bottom: _fontSize * 0.85),
                  child: Text(
                    p,
                    style: TextStyle(
                      fontSize: _fontSize,
                      height: _lineHeight,
                      color: fg,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar(Color fg) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: _bgs[_bgIndex][0].withValues(alpha: 0.96),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back_rounded, color: fg),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.bookName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: fg)),
                  Text(widget.source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          color: fg.withValues(alpha: 0.6))),
                ],
              ),
            ),
            IconButton(
              tooltip: '目录',
              icon: Icon(Icons.list_rounded, color: fg),
              onPressed: _showToc,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomNav(Color fg) {
    final bgTop = _bgs[_bgIndex][0];
    return Container(
      color: bgTop.withValues(alpha: 0.96),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              onPressed: () => _go(-1),
              icon: Icon(Icons.skip_previous_rounded,
                  size: 18, color: fg.withValues(alpha: 0.85)),
              label: Text('上一章',
                  style: TextStyle(
                      fontSize: 12.5, color: fg.withValues(alpha: 0.85))),
            ),
          ),
          Text(
            '${_index + 1}/${widget.chapters.length}',
            style: TextStyle(
                fontSize: 12, color: fg.withValues(alpha: 0.6)),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () => _go(1),
              icon: Icon(Icons.skip_next_rounded,
                  size: 18, color: fg.withValues(alpha: 0.85)),
              label: Text('下一章',
                  style: TextStyle(
                      fontSize: 12.5, color: fg.withValues(alpha: 0.85))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsPanel(Color fg) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        color: _bgs[_bgIndex][0].withValues(alpha: 0.98),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('字号',
                    style: TextStyle(
                        fontSize: 12.5, color: fg.withValues(alpha: 0.7))),
                Expanded(
                  child: Slider(
                    value: _fontSize,
                    min: 12,
                    max: 30,
                    divisions: 18,
                    label: _fontSize.round().toString(),
                    onChanged: (v) => setState(() => _fontSize = v),
                    onChangeEnd: (_) => _savePrefs(),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Text('行距',
                    style: TextStyle(
                        fontSize: 12.5, color: fg.withValues(alpha: 0.7))),
                Expanded(
                  child: Slider(
                    value: _lineHeight,
                    min: 1.2,
                    max: 3.0,
                    divisions: 18,
                    label: _lineHeight.toStringAsFixed(1),
                    onChanged: (v) => setState(() => _lineHeight = v),
                    onChangeEnd: (_) => _savePrefs(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text('背景',
                    style: TextStyle(
                        fontSize: 12.5, color: fg.withValues(alpha: 0.7))),
                const SizedBox(width: 14),
                for (var i = 0; i < _bgs.length; i++)
                  GestureDetector(
                    onTap: () {
                      setState(() => _bgIndex = i);
                      _savePrefs();
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 12),
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: _bgs[i][0],
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _bgIndex == i
                              ? fg.withValues(alpha: 0.8)
                              : fg.withValues(alpha: 0.2),
                          width: _bgIndex == i ? 2 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showToc() {
    final fg = _bgs[_bgIndex][1];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _bgs[_bgIndex][0],
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (ctx, sc) => Column(
          children: [
            const SizedBox(height: 12),
            Text('目录（${widget.chapters.length} 章）',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: fg)),
            const Divider(height: 20),
            Expanded(
              child: ListView.builder(
                controller: sc,
                itemCount: widget.chapters.length,
                itemBuilder: (c, i) => ListTile(
                  dense: true,
                  selected: i == _index,
                  title: Text(
                    widget.chapters[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: i == _index
                          ? Theme.of(context).colorScheme.primary
                          : fg,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() => _index = i);
                    _loadChapter(i);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
