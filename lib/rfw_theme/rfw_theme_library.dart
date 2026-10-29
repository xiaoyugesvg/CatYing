import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:rfw/rfw.dart';

LocalWidgetLibrary createPeekCoreWidgets() {
  final widgets = Map<String, LocalWidgetBuilder>.of(
    createCoreWidgets().widgets,
  );
  widgets['Image'] = (context, source) => _RfwNetworkImage(
    url: source.v<String>(['url']) ?? source.v<String>(['source']) ?? '',
    width: _asDouble(source, ['width']),
    height: _asDouble(source, ['height']),
    fit: _boxFit(source.v<String>(['fit'])),
    alignment: _alignment(source.v<String>(['alignment'])),
    color: _asColor(source, ['color']),
  );
  return LocalWidgetLibrary(widgets);
}

LocalWidgetLibrary createPeekHomeLibrary() {
  return LocalWidgetLibrary(<String, LocalWidgetBuilder>{
    'PeekStickyGrid': (context, source) => _PeekStickyGrid(
      heroHeight: _asDouble(source, ['heroHeight']) ?? 0,
      pinnedHeight: _asDouble(source, ['pinnedHeight']) ?? 0,
      sectionHeight: _asDouble(source, ['sectionHeight']) ?? 0,
      crossAxisCount: _asInt(source, ['crossAxisCount']) ?? 3,
      childAspectRatio: _asDouble(source, ['childAspectRatio']) ?? 0.58,
      mainAxisSpacing: _asDouble(source, ['mainAxisSpacing']) ?? 0,
      crossAxisSpacing: _asDouble(source, ['crossAxisSpacing']) ?? 0,
      horizontalPadding: _asDouble(source, ['horizontalPadding']) ?? 0,
      bottomPadding: _asDouble(source, ['bottomPadding']) ?? 0,
      hero: source.optionalChild(['hero']),
      pinnedHeader: source.optionalChild(['pinnedHeader']),
      sectionHeader: source.optionalChild(['sectionHeader']),
      empty: source.optionalChild(['empty']),
      children: _childList(source, ['children']),
    ),
    'PeekCarousel': (context, source) => _PeekCarousel(
      height: _asDouble(source, ['height']) ?? 150,
      viewportFraction: _asDouble(source, ['viewportFraction']) ?? 0.9,
      autoPlay: source.v<bool>(['autoPlay']) ?? false,
      autoPlayInterval:
          _asDouble(source, ['interval']) ??
          _asDouble(source, ['autoPlayInterval']) ??
          4.0,
      showIndicators: source.v<bool>(['showIndicators']) ?? true,
      activeColor: _asColor(source, ['activeColor']),
      inactiveColor: _asColor(source, ['inactiveColor']),
      children: _childList(source, ['children']),
    ),
    'PeekGlass': (context, source) => _PeekGlass(
      blur: _asDouble(source, ['blur']) ?? 20,
      radius: _asDouble(source, ['radius']) ?? 16,
      tintColor: _asColor(source, ['tintColor']),
      borderColor: _asColor(source, ['borderColor']),
      child: source.optionalChild(['child']),
    ),
    'T4Image': (context, source) => _RfwNetworkImage(
      url: source.v<String>(['url']) ?? '',
      fit: _boxFit(source.v<String>(['fit'])),
    ),
    'PeekImmersiveScaffold': (context, source) => _ImmersiveScaffold(
      imageUrl: source.v<String>(['imageUrl']) ?? '',
      primaryColor: _asColor(source, ['primaryColor']),
      secondaryColor: _asColor(source, ['secondaryColor']),
      backgroundColor: _asColor(source, ['backgroundColor']),
      child: source.optionalChild(['child']),
    ),
    'PeekImmersiveHero': (context, source) => _ImmersiveHero(
      imageUrl: source.v<String>(['imageUrl']) ?? '',
      primaryColor: _asColor(source, ['primaryColor']),
      secondaryColor: _asColor(source, ['secondaryColor']),
      backgroundColor: _asColor(source, ['backgroundColor']),
      fit: _boxFit(source.v<String>(['fit'])),
      child: source.optionalChild(['child']),
    ),
    'PeekImmersiveBackdrop': (context, source) => _ImmersiveBackdrop(
      imageUrl: source.v<String>(['imageUrl']) ?? '',
      primaryColor: _asColor(source, ['primaryColor']),
      secondaryColor: _asColor(source, ['secondaryColor']),
      backgroundColor: _asColor(source, ['backgroundColor']),
      child: source.optionalChild(['child']),
    ),
  });
}

double? _asDouble(DataSource source, List<Object> key) {
  final asDouble = source.v<double>(key);
  if (asDouble != null) return asDouble;
  return source.v<int>(key)?.toDouble();
}

int? _asInt(DataSource source, List<Object> key) {
  final asInt = source.v<int>(key);
  if (asInt != null) return asInt;
  return source.v<double>(key)?.toInt();
}

Color? _asColor(DataSource source, List<Object> key) {
  final value = source.v<int>(key);
  return value == null ? null : Color(value);
}

List<Widget> _childList(DataSource source, List<Object> key) {
  if (!source.isList(key)) return const [];
  return source.childList(key);
}

BoxFit _boxFit(String? value) {
  switch (value) {
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

Alignment _alignment(String? value) {
  switch (value) {
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

class _RfwNetworkImage extends StatelessWidget {
  const _RfwNetworkImage({
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.color,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return SizedBox(
        width: width,
        height: height,
        child: const ColoredBox(
          color: Color(0xFF1E1E1E),
          child: Icon(Icons.broken_image, color: Colors.white38, size: 24),
        ),
      );
    }
    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      color: color,
      errorBuilder: (context, error, stackTrace) => SizedBox(
        width: width,
        height: height,
        child: const ColoredBox(
          color: Color(0xFF1E1E1E),
          child: Icon(Icons.broken_image, color: Colors.white38, size: 24),
        ),
      ),
    );
  }
}

class _PeekStickyGrid extends StatelessWidget {
  const _PeekStickyGrid({
    required this.heroHeight,
    required this.pinnedHeight,
    required this.sectionHeight,
    required this.crossAxisCount,
    required this.childAspectRatio,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
    required this.horizontalPadding,
    required this.bottomPadding,
    required this.hero,
    required this.pinnedHeader,
    required this.sectionHeader,
    required this.empty,
    required this.children,
  });

  final double heroHeight;
  final double pinnedHeight;
  final double sectionHeight;
  final int crossAxisCount;
  final double childAspectRatio;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final double horizontalPadding;
  final double bottomPadding;
  final Widget? hero;
  final Widget? pinnedHeader;
  final Widget? sectionHeader;
  final Widget? empty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final heroWidget = hero;
    final pinnedWidget = pinnedHeader;
    final sectionWidget = sectionHeader;
    final emptyWidget = empty;
    return CustomScrollView(
      slivers: [
        if (heroWidget != null && heroHeight > 0)
          SliverToBoxAdapter(
            child: SizedBox(height: heroHeight, child: heroWidget),
          ),
        if (pinnedWidget != null && pinnedHeight > 0)
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedHeaderDelegate(
              height: pinnedHeight,
              child: pinnedWidget,
            ),
          ),
        if (sectionWidget != null && sectionHeight > 0)
          SliverToBoxAdapter(
            child: SizedBox(height: sectionHeight, child: sectionWidget),
          ),
        if (children.isEmpty)
          SliverToBoxAdapter(child: emptyWidget ?? const SizedBox.shrink())
        else
          SliverPadding(
            padding: EdgeInsets.only(
              left: horizontalPadding,
              right: horizontalPadding,
              bottom: bottomPadding,
            ),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                childAspectRatio: childAspectRatio,
                mainAxisSpacing: mainAxisSpacing,
                crossAxisSpacing: crossAxisSpacing,
              ),
              delegate: SliverChildListDelegate(children),
            ),
          ),
      ],
    );
  }
}

class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedHeaderDelegate({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox(height: height, child: child);
  }

  @override
  bool shouldRebuild(_PinnedHeaderDelegate oldDelegate) {
    return oldDelegate.child != child || oldDelegate.height != height;
  }
}

class _PeekCarousel extends StatefulWidget {
  const _PeekCarousel({
    required this.height,
    required this.viewportFraction,
    required this.autoPlay,
    required this.autoPlayInterval,
    required this.showIndicators,
    required this.activeColor,
    required this.inactiveColor,
    required this.children,
  });

  final double height;
  final double viewportFraction;
  final bool autoPlay;
  final double autoPlayInterval;
  final bool showIndicators;
  final Color? activeColor;
  final Color? inactiveColor;
  final List<Widget> children;

  @override
  State<_PeekCarousel> createState() => _PeekCarouselState();
}

class _PeekCarouselState extends State<_PeekCarousel> {
  late final PageController _controller;
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: widget.viewportFraction);
    _startTimer();
  }

  @override
  void didUpdateWidget(_PeekCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.autoPlay != widget.autoPlay ||
        oldWidget.autoPlayInterval != widget.autoPlayInterval) {
      _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    if (!widget.autoPlay || widget.children.length < 2) return;
    _timer = Timer.periodic(
      Duration(milliseconds: (widget.autoPlayInterval * 1000).round()),
      (_) {
        if (!mounted || !_controller.hasClients) return;
        final next = (_page + 1) % widget.children.length;
        _controller.animateToPage(
          next,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          PageView(
            controller: _controller,
            onPageChanged: (page) => setState(() => _page = page),
            children: widget.children,
          ),
          if (widget.showIndicators)
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.children.length; i++)
                    Container(
                      width: i == _page ? 16 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: i == _page
                            ? widget.activeColor ?? Colors.white
                            : widget.inactiveColor ?? Colors.white54,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PeekGlass extends StatelessWidget {
  const _PeekGlass({
    required this.blur,
    required this.radius,
    required this.tintColor,
    required this.borderColor,
    required this.child,
  });

  final double blur;
  final double radius;
  final Color? tintColor;
  final Color? borderColor;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: tintColor ?? const Color(0x22FFFFFF),
            border: borderColor == null
                ? null
                : Border.all(color: borderColor!),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ImmersiveScaffold extends StatelessWidget {
  const _ImmersiveScaffold({
    required this.imageUrl,
    required this.primaryColor,
    required this.secondaryColor,
    required this.backgroundColor,
    required this.child,
  });

  final String imageUrl;
  final Color? primaryColor;
  final Color? secondaryColor;
  final Color? backgroundColor;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final background = backgroundColor ?? const Color(0xFF0D0D19);
    return Container(
      color: background,
      child: Stack(
        children: [
          if (imageUrl.isNotEmpty)
            Positioned.fill(
              child: Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox.shrink(),
              ),
            ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    (primaryColor ?? background).withValues(alpha: 0.35),
                    background.withValues(alpha: 0.55),
                    background,
                  ],
                ),
              ),
            ),
          ),
          if (child != null) Positioned.fill(child: child!),
        ],
      ),
    );
  }
}

class _ImmersiveHero extends StatelessWidget {
  const _ImmersiveHero({
    required this.imageUrl,
    required this.primaryColor,
    required this.secondaryColor,
    required this.backgroundColor,
    required this.fit,
    required this.child,
  });

  final String imageUrl;
  final Color? primaryColor;
  final Color? secondaryColor;
  final Color? backgroundColor;
  final BoxFit fit;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final background = backgroundColor ?? const Color(0xFF0D0D19);
    return Stack(
      children: [
        if (imageUrl.isNotEmpty)
          Positioned.fill(
            child: Image.network(
              imageUrl,
              fit: fit,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  (primaryColor ?? background).withValues(alpha: 0.25),
                  background.withValues(alpha: 0.75),
                ],
              ),
            ),
          ),
        ),
        if (child != null) Positioned.fill(child: child!),
      ],
    );
  }
}

class _ImmersiveBackdrop extends StatelessWidget {
  const _ImmersiveBackdrop({
    required this.imageUrl,
    required this.primaryColor,
    required this.secondaryColor,
    required this.backgroundColor,
    required this.child,
  });

  final String imageUrl;
  final Color? primaryColor;
  final Color? secondaryColor;
  final Color? backgroundColor;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final background = backgroundColor ?? const Color(0xFF0D0D19);
    return Stack(
      children: [
        if (imageUrl.isNotEmpty)
          Positioned.fill(
            child: Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  (primaryColor ?? background).withValues(alpha: 0.3),
                  background,
                ],
              ),
            ),
          ),
        ),
        if (child != null) Positioned.fill(child: child!),
      ],
    );
  }
}
