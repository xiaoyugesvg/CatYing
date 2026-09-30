import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/tts_service.dart';

// ============================================================
// 阅读配色
// ============================================================

/// 一份阅读配色：底色 + 配套文字色。
///
/// 两者必须成对出现 —— 单看一个底色判断不出该配深字还是浅字，
/// 拆成两个列表迟早会出现"加了新底色忘了加文字色"的黑底黑字。
class _ReaderPalette {
  const _ReaderPalette(this.name, this.background, this.text);

  final String name;
  final Color background;
  final Color text;
}

/// 六种阅读底色（纸白 / 米黄 / 护眼绿 / 浅灰 / 夜间 / 纯黑）。
///
/// 这里是**正文纸色**，不是界面主题色：它们由"长时间阅读不刺眼"决定，
/// 跟 AppTheme 那套随外观模式切换的界面色是两套体系 —— 也不能跟着深色模式走，
/// 否则用户挑好的纸色会被系统主题改掉。所以这组值只能落在这里。
const List<_ReaderPalette> _palettes = [
  _ReaderPalette('纸白', Color(0xFFF8F5EE), Color(0xFF2B2B2B)),
  _ReaderPalette('米黄', Color(0xFFF5EBD8), Color(0xFF3A3226)),
  _ReaderPalette('护眼绿', Color(0xFFDCE8D5), Color(0xFF28331F)),
  _ReaderPalette('浅灰', Color(0xFFEDEDED), Color(0xFF2B2B2B)),
  _ReaderPalette('夜间', Color(0xFF1A1A1A), Color(0xFFB8B8B8)),
  _ReaderPalette('纯黑', Color(0xFF000000), Color(0xFF9E9E9E)),
];

/// 沉浸式阅读器：纵向下滑读正文，点屏幕中间呼出/收起工具栏。
///
/// 没做仿真翻页 —— 那需要精确的分页计算（依赖字体度量与行高取整），
/// 换字号/行距后极易出现"上一页最后一句丢失"。纵向滚动永远不丢字，
/// 且天然适配任意字号与窗口尺寸，是这里唯一稳妥的选择。
class BookReaderPage extends StatefulWidget {
  const BookReaderPage({
    super.key,
    required this.title,
    this.chapters = const [],
    this.initialIndex = 0,
    this.loadContent,
  });

  /// 书名（顶栏显示）
  final String title;

  /// 章节列表（目录 / 上下章都基于它，为空时只剩正文）
  final List<({String name, String url})> chapters;

  /// 打开时停在第一章（越界会自动收敛到首/末章）
  final int initialIndex;

  /// 取正文的回调：入参是章节下标。
  ///
  /// 用回调而不是直接把正文塞进 chapters，是因为正文往往要按需下载 ——
  /// 进来就把几百章全拉下来既慢又费流量。回调为空时只显示"暂无正文"。
  final Future<String> Function(int index)? loadContent;

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

class _BookReaderPageState extends State<BookReaderPage> {
  /// 顶栏固定高度：正文靠内边距给它让位，工具栏本身则浮在上面
  static const double _topBarHeight = 52;

  /// 底部工具栏高度（进度行 + 按钮行），同样只用于正文让位
  static const double _bottomBarHeight = 96;

  final _scroll = ScrollController();

  int _index = 0;
  String _content = '';

  /// 朗读自动滚动的去抖：同一个段落只滚一次
  int _ttsScrolledTo = -1;
  bool _loading = false;
  String _error = '';

  // 阅读设置：这三项是"每个读者不一样"的，默认值按中文小说常见排版给
  double _fontSize = 18;
  double _lineHeight = 1.7;
  double _margin = 20;
  int _paletteIndex = 0;

  bool _barsVisible = true;

  _ReaderPalette get _palette => _palettes[_paletteIndex];

  int get _chapterCount => widget.chapters.length;

  String get _chapterName {
    if (_chapterCount == 0) return widget.title;
    final name = widget.chapters[_index].name.trim();
    return name.isEmpty ? '第 ${_index + 1} 章' : name;
  }

  String get _progressText =>
      _chapterCount == 0 ? '无章节' : '第 ${_index + 1}/$_chapterCount 章';

  @override
  void initState() {
    super.initState();
    // 外部可能传进来一个越界下标（比如从"继续阅读"进来时章节列表变了）
    _index = _chapterCount == 0 ? 0 : widget.initialIndex.clamp(0, _chapterCount - 1);
    _load();
  }

  @override
  void dispose() {
    // 退出阅读器要停掉朗读，否则会在别的页面继续念
    TtsService.instance.stop();
    TtsService.instance.onChapterFinished = null;
    _scroll.dispose();
    super.dispose();
  }

  // ============================================================
  // 正文加载 / 换章
  // ============================================================

  Future<void> _load() async {
    final loader = widget.loadContent;
    if (loader == null) {
      setState(() {
        _content = '';
        _error = '';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final text = await loader(_index);
      if (!mounted) return;
      setState(() {
        _content = text;
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

  Future<void> _goChapter(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= _chapterCount) return;
    await _jumpTo(next);
  }

  Future<void> _jumpTo(int index) async {
    setState(() {
      _index = index;
      _content = '';
    });
    // 换章必须回到顶部：沿用上一章的滚动位置会让人以为"这章是空的"
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _load();
  }

  // ============================================================
  // 交互
  // ============================================================

  /// 点屏幕中间切换工具栏。
  ///
  /// 只认中间 1/3：阅读时手指经常落在左右两侧（准备滑动），整屏都响应会把
  /// 工具栏刷得一闪一闪；中间留白正好是"没有其他含义"的区域。
  void _onTapUp(TapUpDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    final x = details.localPosition.dx;
    if (x < width / 3 || x > width * 2 / 3) return;
    setState(() => _barsVisible = !_barsVisible);
  }

  /// 目录：章节可能几百条，用可滚动列表而不是一次铺开
  Future<void> _openChapterList() async {
    if (_chapterCount == 0) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppTheme.glassRadius)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppTheme.spacingXL,
                  AppTheme.spacingLG, AppTheme.spacingXL, AppTheme.spacingSM),
              child: Row(
                children: [
                  Text('目录',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('共 $_chapterCount 章',
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption)),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _chapterCount,
                itemBuilder: (c, i) {
                  final current = i == _index;
                  final name = widget.chapters[i].name.trim();
                  return ListTile(
                    dense: true,
                    title: Text(
                      name.isEmpty ? '第 ${i + 1} 章' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: current
                            ? AppTheme.accentColor
                            : AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight:
                            current ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    trailing: current
                        ? const Icon(Icons.check,
                            size: 18, color: AppTheme.accentColor)
                        : null,
                    onTap: () => Navigator.pop(ctx, i),
                  );
                },
              ),
            ),
            const SizedBox(height: AppTheme.spacingSM),
          ],
        ),
      ),
    );
    if (picked == null || picked == _index) return;
    await _jumpTo(picked);
  }

  /// 阅读设置面板：字号 / 行距 / 边距 + 底色
  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppTheme.glassRadius)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // 拖动滑块要同时刷新两处：正文（立刻重排）和面板里的数值/选中态
          void apply(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
          }

          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppTheme.spacingXL,
                  AppTheme.spacingLG, AppTheme.spacingXL, AppTheme.spacingLG),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('阅读设置',
                          style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: AppTheme.fontHeadline,
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      // 调乱了不用一格格拖回来
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => apply(() {
                          _fontSize = 18;
                          _lineHeight = 1.7;
                          _margin = 20;
                        }),
                        child: const Text('恢复默认',
                            style: TextStyle(
                                color: AppTheme.accentColor,
                                fontSize: AppTheme.fontSubhead)),
                      ),
                    ],
                  ),
                  _sliderRow('字号', _fontSize.toStringAsFixed(0), _fontSize, 11,
                      30, 19, (v) => apply(() => _fontSize = v)),
                  _sliderRow('行距', _lineHeight.toStringAsFixed(2), _lineHeight,
                      1.2, 2.5, 26, (v) => apply(() => _lineHeight = v)),
                  _sliderRow('左右边距', _margin.toStringAsFixed(0), _margin, 12,
                      48, 18, (v) => apply(() => _margin = v)),
                  const SizedBox(height: AppTheme.spacingSM),
                  Text('背景',
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead)),
                  const SizedBox(height: AppTheme.spacingMD),
                  Row(
                    children: [
                      for (var i = 0; i < _palettes.length; i++)
                        _paletteDot(i, apply),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _sliderRow(String label, String value, double current, double min,
      double max, int divisions, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead)),
            const Spacer(),
            Text(value,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead,
                    fontFamily: 'monospace')),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: AppTheme.accentColor,
            thumbColor: AppTheme.accentColor,
            inactiveTrackColor: AppTheme.backgroundTertiary,
            trackHeight: 3,
            // 滑块本来就很细，外圈光晕在这个面板里只会显得脏
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(
            value: current,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _paletteDot(int index, void Function(VoidCallback) apply) {
    final palette = _palettes[index];
    final selected = index == _paletteIndex;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => apply(() => _paletteIndex = index),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.background,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? AppTheme.accentColor
                      : AppTheme.borderMedium,
                  width: selected ? 2 : 0.8,
                ),
              ),
              // 用该底色自己的文字色打勾，顺便预览"这套配色读起来什么观感"
              child: selected
                  ? Icon(Icons.check, size: 16, color: palette.text)
                  : null,
            ),
            const SizedBox(height: 6),
            Text(palette.name,
                style: TextStyle(
                    color: selected
                        ? AppTheme.accentColor
                        : AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption)),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 界面
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final palette = _palette;
    return Scaffold(
      backgroundColor: palette.background,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildBody(palette)),
            Positioned(top: 0, left: 0, right: 0, child: _buildTopBar(palette)),
            Positioned(
                bottom: 0, left: 0, right: 0, child: _buildBottomBar(palette)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(_ReaderPalette palette) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTapUp,
      child: AnimatedPadding(
        duration: AppTheme.motionFast,
        curve: AppTheme.motionCurve,
        // 工具栏出现时正文缩进让位，收起时铺满整屏（沉浸感的来源）
        padding: EdgeInsets.only(
          top: _barsVisible ? _topBarHeight : 0,
          bottom: _barsVisible ? _bottomBarHeight : 0,
        ),
        child: _buildContent(palette),
      ),
    );
  }

  Widget _buildContent(_ReaderPalette palette) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.accentColor),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingXXL),
          child: Text(
            '正文加载失败：$_error',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.text.withValues(alpha: 0.8),
              fontSize: AppTheme.fontSubhead,
            ),
          ),
        ),
      );
    }

    // 抓来的正文常带大量空行/缩进空格：先清干净再按段落渲染，
    // 否则行距设置会被空行吃出大片莫名其妙的留白。
    final paragraphs = _content
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (paragraphs.isEmpty) {
      return Center(
        child: Text(
          widget.loadContent == null ? '这一章还没有正文' : '暂无正文内容',
          style: TextStyle(
            color: palette.text.withValues(alpha: 0.6),
            fontSize: AppTheme.fontSubhead,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(
          _margin, AppTheme.spacingXL, _margin, AppTheme.spacingXXL),
      itemCount: paragraphs.length,
      itemBuilder: (context, i) => Obx(() {
        // 朗读时高亮正在念的那一段，并把它滚进视野
        final tts = TtsService.instance;
        final speaking = tts.isSpeaking.value || tts.isPaused.value;
        final active = speaking && tts.currentIndex.value == i;
        if (active) _ensureVisible(i);
        return Padding(
          padding: const EdgeInsets.only(bottom: AppTheme.spacingMD),
          child: AnimatedContainer(
            duration: AppTheme.motionFast,
            curve: AppTheme.motionCurve,
            decoration: active
                ? BoxDecoration(
                    color: AppTheme.accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  )
                : null,
            padding: active
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
                : EdgeInsets.zero,
            child: Text(
              // 中文排版惯例：段首空两格（用全角空格，不受字体字距影响）
              '　　${paragraphs[i]}',
              style: TextStyle(
                color: active ? AppTheme.accentColor : palette.text,
                // 不乘 AppTheme.fontScale：阅读字号由本页滑块直接决定，
                // 再叠一层全局缩放会让"18 号字"显示出来并不是 18
                fontSize: _fontSize,
                height: _lineHeight,
              ),
            ),
          ),
        );
      }),
    );
  }

  /// 把正在朗读的段落滚进视野（只在它离开可见区时才滚，避免抖动）
  void _ensureVisible(int index) {
    if (_ttsScrolledTo == index) return;
    _ttsScrolledTo = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 段落高度随字号/行距变化，估算一个大致位置即可（够用且不引入测量）
      final approx = index * (_fontSize * _lineHeight + AppTheme.spacingMD);
      try {
        _scroll.animateTo(
          approx,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
      } catch (_) {/* 还没 attach 时忽略 */}
    });
  }

  /// 朗读开关：未朗读→开始；朗读中→暂停；暂停中→继续
  Future<void> _toggleTts() async {
    final tts = TtsService.instance;
    if (tts.isSpeaking.value) {
      await tts.pause();
      return;
    }
    if (tts.isPaused.value) {
      await tts.resume();
      return;
    }
    // 念完一章自动接下一章
    tts.onChapterFinished = () {
      if (!mounted) return;
      if (_index < _chapterCount - 1) {
        _goChapter(1).then((_) => tts.speak(_content));
      }
    };
    final text = _content.trim().isEmpty
        // 有些源正文是懒加载的，先确保拿到内容
        ? await _ensureContent()
        : _content;
    await tts.speak(text);
  }

  /// 确保当前章正文已加载（朗读前调用）
  Future<String> _ensureContent() async {
    if (_content.trim().isNotEmpty) return _content;
    final loader = widget.loadContent;
    if (loader == null) return '';
    try {
      return await loader(_index);
    } catch (_) {
      return '';
    }
  }

  Widget _buildTopBar(_ReaderPalette palette) {
    return AnimatedSlide(
      offset: _barsVisible ? Offset.zero : const Offset(0, -1),
      duration: AppTheme.motionFast,
      curve: AppTheme.motionCurve,
      child: IgnorePointer(
        ignoring: !_barsVisible,
        child: Container(
          height: _topBarHeight,
          decoration: BoxDecoration(
            // 用当前纸色做底（不是 AppTheme 界面色）：夜间配色下顶栏才不会白得刺眼
            color: palette.background.withValues(alpha: 0.94),
            border: Border(
              bottom: BorderSide(
                  color: palette.text.withValues(alpha: 0.10), width: 0.6),
            ),
          ),
          child: Row(
            children: [
              _barIcon(Icons.arrow_back_ios_new,
                  () => Navigator.of(context).maybePop(), palette.text),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: AppTheme.fontSubhead + 2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // 朗读（听书）：点了就从当前章开头念，再点暂停/继续
              Obx(() {
                final tts = TtsService.instance;
                final on = tts.isSpeaking.value;
                return _barIcon(
                  on
                      ? Icons.pause_circle_outline
                      : (tts.isPaused.value
                          ? Icons.play_circle_outline
                          : Icons.headphones),
                  () => _toggleTts(),
                  on ? AppTheme.accentColor : palette.text,
                );
              }),
              // 设置入口："点中间"只负责显隐工具栏，字号这类调整需要一个明确按钮
              _barIcon(Icons.text_fields, _openSettings, palette.text),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(_ReaderPalette palette) {
    final hasPrev = _index > 0;
    final hasNext = _index < _chapterCount - 1;
    return AnimatedSlide(
      offset: _barsVisible ? Offset.zero : const Offset(0, 1),
      duration: AppTheme.motionFast,
      curve: AppTheme.motionCurve,
      child: IgnorePointer(
        ignoring: !_barsVisible,
        child: Container(
          decoration: BoxDecoration(
            color: palette.background.withValues(alpha: 0.94),
            border: Border(
              top: BorderSide(
                  color: palette.text.withValues(alpha: 0.10), width: 0.6),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(AppTheme.spacingLG,
              AppTheme.spacingSM, AppTheme.spacingLG, AppTheme.spacingSM),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _chapterName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text.withValues(alpha: 0.75),
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppTheme.spacingSM),
                  Text(
                    _progressText,
                    style: TextStyle(
                      color: palette.text.withValues(alpha: 0.55),
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spacingSM),
              Row(
                children: [
                  Expanded(
                    child: _barAction(Icons.chevron_left, '上一章',
                        hasPrev ? () => _goChapter(-1) : null, palette.text),
                  ),
                  Expanded(
                    child: _barAction(Icons.list_alt, '目录', _openChapterList,
                        palette.text),
                  ),
                  Expanded(
                    child: _barAction(Icons.chevron_right, '下一章',
                        hasNext ? () => _goChapter(1) : null, palette.text),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barIcon(IconData icon, VoidCallback onTap, Color color) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 48,
        height: _topBarHeight,
        child: Center(child: Icon(icon, size: 19, color: color)),
      ),
    );
  }

  /// 底部工具按钮：到达首/末章时置灰且不可点（onTap 传 null）
  Widget _barAction(
      IconData icon, String label, VoidCallback? onTap, Color color) {
    final enabled = onTap != null;
    final tint = color.withValues(alpha: enabled ? 0.9 : 0.3);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: tint),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: tint,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
