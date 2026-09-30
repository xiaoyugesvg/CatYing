import 'package:flutter/material.dart';

import '../../common/theme.dart';

/// 漫画阅读器：纵向长图流。
///
/// 没做"一页一屏"的横向翻页 —— 条漫本身是长图，横向分页要么把图裁断，
/// 要么得按图片真实高度动态算页数（图没加载完算不出来）。纵向滚动最稳。
class MangaReaderPage extends StatefulWidget {
  const MangaReaderPage({
    super.key,
    required this.title,
    required this.chapterName,
    this.images = const [],
    this.onPrevChapter,
    this.onNextChapter,
  });

  /// 漫画名
  final String title;

  /// 当前话（顶栏副标题 + 页码计数都靠它区分）
  final String chapterName;

  /// 本话的图片地址，按阅读顺序排列
  final List<String> images;

  /// 上一话 / 下一话：由调用方决定去哪（为空 = 已是首/末话，按钮置灰）
  final VoidCallback? onPrevChapter;
  final VoidCallback? onNextChapter;

  @override
  State<MangaReaderPage> createState() => _MangaReaderPageState();
}

class _MangaReaderPageState extends State<MangaReaderPage> {
  // 56 而非 52：顶栏是"书名 + 当前话"两行，留够行高避免大字模式下挤爆
  static const double _topBarHeight = 56;
  static const double _bottomBarHeight = 56;

  final _scroll = ScrollController();

  bool _barsVisible = true;
  int _page = 1;

  int get _total => widget.images.length;

  String get _pageText => _total == 0 ? '0/0' : '$_page/$_total';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  /// 滚动时更新页码。
  ///
  /// 图片只有加载完才知道真实高度，精确的"当前第几张"算不出来，
  /// 所以按滚动总长的百分比等分估算 —— 它只用于显示页码，
  /// 不参与任何加载/预取逻辑，误差一两张无所谓。
  void _onScroll() {
    if (!_scroll.hasClients || _total <= 1) return;
    final position = _scroll.position;
    final max = position.maxScrollExtent;
    final index = max <= 0
        ? 0
        : ((position.pixels / max) * (_total - 1)).round().clamp(0, _total - 1);
    final page = index + 1;
    if (page != _page) setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildBody()),
            Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
            Positioned(
                bottom: 0, left: 0, right: 0, child: _buildBottomBar()),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 图片流
  // ============================================================

  Widget _buildBody() {
    if (_total == 0) {
      return Center(
        child: Text('这一话还没有图片',
            style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontSubhead)),
      );
    }
    return AnimatedPadding(
      duration: AppTheme.motionFast,
      curve: AppTheme.motionCurve,
      // 工具栏出现时给图片让位，收起时满屏 —— 也让工具栏不会压住第一格/最后一格
      padding: EdgeInsets.only(
        top: _barsVisible ? _topBarHeight : 0,
        bottom: _barsVisible ? _bottomBarHeight : 0,
      ),
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingXS),
        itemCount: _total,
        itemBuilder: (context, i) => _buildImage(widget.images[i]),
      ),
    );
  }

  Widget _buildImage(String url) {
    final src = url.trim();
    return GestureDetector(
      // 整页都是图，命中区域越简单越好：点哪都算"切工具栏"
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _barsVisible = !_barsVisible),
      child: src.isEmpty
          ? _placeholder(icon: Icons.image_not_supported_outlined)
          : Image.network(
              src,
              // 宽度铺满 + 高度自适应：长图靠滚动看，绝不能裁切
              width: double.infinity,
              fit: BoxFit.fitWidth,
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : _placeholder(spinner: true),
              errorBuilder: (context, error, stack) => _placeholder(
                  icon: Icons.broken_image_outlined),
            ),
    );
  }

  /// 占位块：加载中用转圈，失败用断图图标，两者尺寸一致避免列表跳动
  Widget _placeholder({bool spinner = false, IconData? icon}) {
    return SizedBox(
      height: 220,
      width: double.infinity,
      child: ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Center(
          child: spinner
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: AppTheme.accentColor),
                )
              : Icon(icon ?? Icons.image_outlined,
                  size: 34, color: AppTheme.textTertiary),
        ),
      ),
    );
  }

  // ============================================================
  // 工具栏
  // ============================================================

  Widget _buildTopBar() {
    return AnimatedSlide(
      offset: _barsVisible ? Offset.zero : const Offset(0, -1),
      duration: AppTheme.motionFast,
      curve: AppTheme.motionCurve,
      child: IgnorePointer(
        ignoring: !_barsVisible,
        child: Container(
          height: _topBarHeight,
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary.withValues(alpha: 0.94),
            border: Border(
                bottom: BorderSide(color: AppTheme.borderLight, width: 0.6)),
          ),
          child: Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: SizedBox(
                  width: 48,
                  height: _topBarHeight,
                  child: Center(
                    child: Icon(Icons.arrow_back_ios_new,
                        size: 19, color: AppTheme.textPrimary),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead + 1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.chapterName.trim().isNotEmpty)
                      Text(
                        widget.chapterName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.spacingMD),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return AnimatedSlide(
      offset: _barsVisible ? Offset.zero : const Offset(0, 1),
      duration: AppTheme.motionFast,
      curve: AppTheme.motionCurve,
      child: IgnorePointer(
        ignoring: !_barsVisible,
        child: Container(
          height: _bottomBarHeight,
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary.withValues(alpha: 0.94),
            border: Border(
                top: BorderSide(color: AppTheme.borderLight, width: 0.6)),
          ),
          child: Row(
            children: [
              Expanded(
                child: _chapterAction(
                    Icons.chevron_left, '上一话', widget.onPrevChapter),
              ),
              Text(
                _pageText,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontSubhead,
                  fontFamily: 'monospace',
                ),
              ),
              Expanded(
                child: _chapterAction(
                    Icons.chevron_right, '下一话', widget.onNextChapter),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 换话按钮：没有回调 = 到头了，置灰且不可点
  Widget _chapterAction(IconData icon, String label, VoidCallback? onTap) {
    final enabled = onTap != null;
    final tint =
        AppTheme.textSecondary.withValues(alpha: enabled ? 1 : 0.35);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: _bottomBarHeight,
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
