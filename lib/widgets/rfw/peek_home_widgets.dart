import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:rfw/rfw.dart';

import '../../services/app_log.dart';
import '../../common/theme.dart';

/// `peek.home` 本地组件库 —— RFW 主题文件靠这些组件渲染首页。
///
/// 为什么必须自建：PeekPro 的 15 套 .rfwtxt 模板都 `import peek.home`，
/// 且**没有任何模板自己定义**这些组件（已扫描确认），所以 App 侧必须提供
/// PeekStickyGrid / PeekGlass / T4Image / PeekCarousel / PeekImmersiveHero /
/// PeekImmersiveBackdrop 六个本地组件。
///
/// 参数签名不是猜的，是从模板的真实调用点提取的（见各组件注释）。
class PeekHomeWidgets {
  /// 库名，对应主题里的 `import peek.home;`
  static const LibraryName libraryName = LibraryName(<String>['peek', 'home']);

  static WidgetLibrary create() {
    return LocalWidgetLibrary(<String, LocalWidgetBuilder>{
      // ---------------------------------------------------------------
      // T4Image —— 用到的次数最多（全模板 58 次）
      //
      // 模板调用形态：
      //   T4Image(url: args.item.pic)
      //   T4Image(url: args.url, fit: "contain", alignment: args.alignment,
      //           placeholderColor: 0x00000000, useOldImageOnUrlChange: true)
      // ---------------------------------------------------------------
      'T4Image': (BuildContext context, DataSource source) {
        final url = source.v<String>(<Object>['url']) ?? '';
        final fitStr = source.v<String>(<Object>['fit']) ?? 'cover';
        final alignStr = source.v<String>(<Object>['alignment']) ?? '';
        final placeholder = source.v<int>(<Object>['placeholderColor']);
        // V12b：默认占位色原为写死白 8%（深色档）—— 浅色模式下图片未加载时
        // 那是"浅底上的白块"。浅色改走调色板的低透明度底，深色保留原值。
        final bg = placeholder != null
            ? Color(placeholder)
            : (AppBrightness.isLight.value
                ? AppTheme.backgroundTertiary
                : const Color(0x14FFFFFF));

        if (url.isEmpty) {
          return ColoredBox(color: bg);
        }
        return ColoredBox(
          color: bg,
          child: Image.network(
            url,
            fit: _boxFit(fitStr),
            alignment: _alignment(alignStr),
            // 列表里图片很多，限制解码宽度避免 iOS 内存暴涨
            errorBuilder: (_, __, ___) => ColoredBox(color: bg),
            loadingBuilder: (_, child, progress) =>
                progress == null ? child : ColoredBox(color: bg),
          ),
        );
      },

      // ---------------------------------------------------------------
      // PeekGlass —— 毛玻璃面板（11 次）
      //
      // 模板调用形态：PeekGlass(blur:, radius:, tintColor:, borderColor:, child:)
      // ---------------------------------------------------------------
      'PeekGlass': (BuildContext context, DataSource source) {
        final blur = source.v<double>(<Object>['blur']) ?? 0.0;
        final radius = source.v<double>(<Object>['radius']) ?? 12.0;
        // V12b：默认 tint/border 原为写死白 10% / 9%（深色档）—— 浅色底上
        // 那是"灰白糊片"。浅色改走 AppTheme 的玻璃取色，深色保留原值。
        final tintColor = source.v<int>(<Object>['tintColor']);
        final borderColor = source.v<int>(<Object>['borderColor']);
        final tint = tintColor != null
            ? Color(tintColor)
            : (AppBrightness.isLight.value
                ? AppTheme.glassTint
                : const Color(0x1AFFFFFF));
        final border = borderColor != null
            ? Color(borderColor)
            : (AppBrightness.isLight.value
                ? AppTheme.glassBorder
                : const Color(0x18FFFFFF));
        final child = source.optionalChild(<Object>['child']);
        final br = BorderRadius.circular(radius);

        Widget panel = Container(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: br,
            border: Border.all(color: border, width: 0.8),
          ),
          child: child,
        );
        if (blur > 0.5) {
          panel = ClipRRect(
            borderRadius: br,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: panel,
            ),
          );
        }
        return panel;
      },

      // ---------------------------------------------------------------
      // PeekStickyGrid —— 每个主题的 root 容器（15 次）
      //
      // 模板调用形态（全部 15 个模板）：
      //   PeekStickyGrid(
      //     heroHeight: <double>,
      //     pinnedHeight: data.home.stickyHeaderHeight,
      //     sectionHeight: <double>,
      //     crossAxisCount: <int>,
      //     childAspectRatio: <double>,
      //     hero: <widget>, pinnedHeader: <widget>, sectionHeader: <widget>,
      //     empty: <widget>,
      //     children: [ ... ],
      //   )
      //
      // 语义：hero 区（推荐位/轮播）固定高度，pinnedHeader 吸顶，
      // 下方是 crossAxisCount 列的网格，每个 cell 按 childAspectRatio 定高。
      // ---------------------------------------------------------------
      'PeekStickyGrid': (BuildContext context, DataSource source) {
        final heroHeight = source.v<double>(<Object>['heroHeight']) ?? 0.0;
        final pinnedHeight = source.v<double>(<Object>['pinnedHeight']) ?? 0.0;
        final sectionHeight =
            source.v<double>(<Object>['sectionHeight']) ?? 0.0;
        final crossAxisCount =
            (source.v<int>(<Object>['crossAxisCount']) ?? 3).clamp(1, 8);
        final ratio =
            source.v<double>(<Object>['childAspectRatio']) ?? 0.6;
        final hero = source.optionalChild(<Object>['hero']);
        final pinnedHeader =
            source.optionalChild(<Object>['pinnedHeader']);
        final sectionHeader =
            source.optionalChild(<Object>['sectionHeader']);
        final empty = source.optionalChild(<Object>['empty']);
        final children = source.childList(<Object>['children']);

        final blocks = <Widget>[];
        if (hero != null && heroHeight > 0.5) {
          blocks.add(SizedBox(height: heroHeight, child: hero));
        }
        if (pinnedHeader != null && pinnedHeight > 0.5) {
          blocks.add(SizedBox(height: pinnedHeight, child: pinnedHeader));
        }
        if (sectionHeader != null && sectionHeight > 0.5) {
          blocks.add(SizedBox(height: sectionHeight, child: sectionHeader));
        }
        if (children.isEmpty) {
          blocks.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: empty ??
                // V12b：空态文案原来写死 `Colors.white54` —— 浅色模式下
                // 白字压浅底等于看不见，改用跟随明暗的次要文字色。
                Center(
                  child: Text('暂无内容',
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontSubhead)),
                ),
          ));
        } else {
          blocks.add(GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: ratio <= 0 ? 0.6 : ratio,
            ),
            itemCount: children.length,
            itemBuilder: (_, i) => children[i],
          ));
        }
        // 外层不滚动：由调用方（首页）提供滚动容器，
        // 否则 hero + 网格会出现嵌套滚动冲突。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: blocks,
        );
      },

      // ---------------------------------------------------------------
      // PeekCarousel —— 轮播（9 次）
      //
      // 模板调用形态：
      //   PeekCarousel(autoPlay: true, interval: 3500, viewportFraction: 0.46,
      //                activeColor: 0xFFE0A44B, inactiveColor: 0x55725A38,
      //                style: "standard", showIndicators: true,
      //                indicatorAlignment: "center", children: [...])
      // ---------------------------------------------------------------
      'PeekCarousel': (BuildContext context, DataSource source) {
        final autoPlay = source.v<bool>(<Object>['autoPlay']) ?? false;
        final interval =
            (source.v<int>(<Object>['interval']) ?? 4000).clamp(800, 60000);
        final vp = (source.v<double>(<Object>['viewportFraction']) ?? 1.0)
            .clamp(0.2, 1.0);
        final active = source.v<int>(<Object>['activeColor']);
        final inactive = source.v<int>(<Object>['inactiveColor']);
        final showIndicators =
            source.v<bool>(<Object>['showIndicators']) ?? false;
        final children = source.childList(<Object>['children']);

        if (children.isEmpty) return const SizedBox.shrink();
        return _PeekCarouselView(
          children: children,
          autoPlay: autoPlay,
          intervalMs: interval,
          viewportFraction: vp,
          // V12b（同一处漏改的延伸）：指示条默认值是写死白（active 全白 /
          // inactive 白 33%），浅色模式下白条压在浅底上等于看不见。
          // 深色保留原值，浅色改走调色板取色。
          activeColor: Color(
            active ??
                (AppBrightness.isLight.value
                    ? AppTheme.accentColor.toARGB32()
                    : 0xFFFFFFFF),
          ),
          inactiveColor: Color(
            inactive ??
                (AppBrightness.isLight.value
                    ? AppTheme.borderMedium.toARGB32()
                    : 0x55FFFFFF),
          ),
          showIndicators: showIndicators,
        );
      },

      // ---------------------------------------------------------------
      // PeekImmersiveHero —— 沉浸式头图（仅「沉浸光影」用）
      // 参数：imageUrl, primaryColor, secondaryColor, backgroundColor,
      //       fit, portraitFit, landscapeFit, portraitAlignment,
      //       landscapeAlignment, child
      // ---------------------------------------------------------------
      'PeekImmersiveHero': (BuildContext context, DataSource source) {
        final imageUrl = source.v<String>(<Object>['imageUrl']) ?? '';
        final bg = source.v<int>(<Object>['backgroundColor']);
        final primary = source.v<int>(<Object>['primaryColor']);
        final fitStr = _isPortrait(context)
            ? (source.v<String>(<Object>['portraitFit']) ??
                source.v<String>(<Object>['fit']) ??
                'cover')
            : (source.v<String>(<Object>['landscapeFit']) ??
                source.v<String>(<Object>['fit']) ??
                'cover');
        final alignStr = _isPortrait(context)
            ? (source.v<String>(<Object>['portraitAlignment']) ?? 'topCenter')
            : (source.v<String>(<Object>['landscapeAlignment']) ?? 'center');
        final child = source.optionalChild(<Object>['child']);

        return Stack(
          fit: StackFit.expand,
          children: [
            if (imageUrl.isNotEmpty)
              Image.network(
                imageUrl,
                fit: _boxFit(fitStr),
                alignment: _alignment(alignStr),
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            if (bg != null) Container(color: Color(bg)),
            if (child != null) child,
            // primaryColor 用于让主题把标题色传导到整页背景（此处占位保留语义）
            if (primary != null) const SizedBox.shrink(),
          ],
        );
      },

      // ---------------------------------------------------------------
      // PeekImmersiveBackdrop —— 沉浸式背景层（仅「沉浸光影」用）
      // ---------------------------------------------------------------
      'PeekImmersiveBackdrop': (BuildContext context, DataSource source) {
        final imageUrl = source.v<String>(<Object>['imageUrl']) ?? '';
        final bg = source.v<int>(<Object>['backgroundColor']);
        return ColoredBox(
          // V12b：默认背景原为写死 0xFF0E1116（深色档）—— 浅色模式下
          // 「沉浸光影」整页发黑。浅色改走调色板底色，深色保留原值。
          color: bg != null
              ? Color(bg)
              : (AppBrightness.isLight.value
                  ? AppTheme.backgroundPrimary
                  : const Color(0xFF0E1116)),
          child: imageUrl.isEmpty
              ? const SizedBox.expand()
              : Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.expand(),
                ),
        );
      },
    });
  }

  // ================================================================
  // 工具
  // ================================================================

  static bool _isPortrait(BuildContext context) =>
      MediaQuery.maybeOf(context)?.orientation == Orientation.portrait;

  /// 模板里的 fit 是字符串（"cover" / "contain" / "fill" …）
  static BoxFit _boxFit(String s) {
    switch (s) {
      case 'contain':
        return BoxFit.contain;
      case 'fill':
        return BoxFit.fill;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      case 'none':
        return BoxFit.none;
      case 'scaleDown':
        return BoxFit.scaleDown;
      case 'cover':
      default:
        return BoxFit.cover;
    }
  }

  /// 模板里的 alignment 是字符串（"topCenter" / "center" / "bottomLeft" …）
  static Alignment _alignment(String s) {
    switch (s) {
      case 'topLeft':
        return Alignment.topLeft;
      case 'topCenter':
        return Alignment.topCenter;
      case 'topRight':
        return Alignment.topRight;
      case 'centerLeft':
        return Alignment.centerLeft;
      case 'centerRight':
        return Alignment.centerRight;
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'bottomCenter':
        return Alignment.bottomCenter;
      case 'bottomRight':
        return Alignment.bottomRight;
      case 'center':
      default:
        return Alignment.center;
    }
  }
}

/// 轮播实现：PageView + 可选自动播放 + 指示条
class _PeekCarouselView extends StatefulWidget {
  final List<Widget> children;
  final bool autoPlay;
  final int intervalMs;
  final double viewportFraction;
  final Color activeColor;
  final Color inactiveColor;
  final bool showIndicators;

  const _PeekCarouselView({
    required this.children,
    required this.autoPlay,
    required this.intervalMs,
    required this.viewportFraction,
    required this.activeColor,
    required this.inactiveColor,
    required this.showIndicators,
  });

  @override
  State<_PeekCarouselView> createState() => _PeekCarouselViewState();
}

class _PeekCarouselViewState extends State<_PeekCarouselView> {
  late final PageController _controller;
  int _index = 0;
  bool _timerActive = false;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: widget.viewportFraction);
    _controller.addListener(() {
      final p = _controller.page;
      if (p == null) return;
      final i = p.round();
      if (i != _index && mounted) setState(() => _index = i);
    });
    _startAutoPlay();
  }

  void _startAutoPlay() {
    if (!widget.autoPlay || widget.children.length < 2) return;
    _timerActive = true;
    _tick();
  }

  Future<void> _tick() async {
    while (_timerActive && mounted) {
      await Future<void>.delayed(Duration(milliseconds: widget.intervalMs));
      if (!_timerActive || !mounted) return;
      if (!_controller.hasClients) continue;
      final next = (_index + 1) % widget.children.length;
      try {
        await _controller.animateToPage(
          next,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        );
      } catch (e) {
        // 页面销毁瞬间 animate 会抛，忽略即可
        AppLog.instance.log('[PeekCarousel] animate 失败: $e');
        return;
      }
    }
  }

  @override
  void dispose() {
    _timerActive = false;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        PageView(
          controller: _controller,
          padEnds: false,
          children: widget.children,
        ),
        if (widget.showIndicators)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(widget.children.length, (i) {
                final on = i == _index;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: on ? 16 : 6,
                  height: 4,
                  decoration: BoxDecoration(
                    color: on ? widget.activeColor : widget.inactiveColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }
}
