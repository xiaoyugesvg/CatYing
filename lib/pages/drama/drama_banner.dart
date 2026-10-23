import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../models/movie.dart';
import 'drama_entry.dart';

/// 短剧页顶部的循环幻灯片。
///
/// 与影视首页的轮播同思路：
///   · `PageView` 用无限索引 + 取模 → 左右都能一直滑，不会停在头/尾
///   · 4 秒自动翻页；用户手动滑动后重新计时（不会刚滑完就被自动切走）
///   · 底部渐变 + 标题/备注，右下角圆点指示当前页
///
/// 只拿有封面的条目，最多 8 张；不足 2 张时自动关闭轮播。
class DramaBanner extends StatefulWidget {
  const DramaBanner({
    super.key,
    required this.videos,
    required this.isDark,
  });

  final List<Video> videos;
  final bool isDark;

  @override
  State<DramaBanner> createState() => _DramaBannerState();
}

class _DramaBannerState extends State<DramaBanner> {
  static const _autoPlay = Duration(seconds: 4);

  late final PageController _controller = PageController(
    viewportFraction: 0.9,
    // 从一个很大的页码开始，保证往左也能一直滑
    initialPage: 400,
  );

  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant DramaBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videos.length != widget.videos.length) {
      _index = 0;
      _restartTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    if (widget.videos.length <= 1) return;
    _timer = Timer.periodic(_autoPlay, (_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.nextPage(
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.videos;
    if (items.isEmpty) return const SizedBox.shrink();
    final n = items.length;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Column(
        children: [
          SizedBox(
            height: 168,
            child: PageView.builder(
              controller: _controller,
              padEnds: false,
              onPageChanged: (i) {
                setState(() => _index = i % n);
                // 手动滑动后重新计时：避免刚滑到想看的那页就被自动翻走
                _restartTimer();
              },
              itemBuilder: (context, i) => _slide(items[i % n]),
            ),
          ),
          if (n > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(n, (i) {
                final active = i == _index;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 16 : 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: active
                        ? AppTheme.accentColor
                        : (widget.isDark ? Colors.white24 : Colors.black26),
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ],
        ],
      ),
    );
  }

  Widget _slide(Video v) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => DramaEntry.openDetail(v),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              v.pic.isEmpty
                  ? Container(
                      color: widget.isDark
                          ? Colors.white10
                          : Colors.black.withValues(alpha: 0.06),
                    )
                  : CachedNetworkImage(
                      imageUrl: v.pic,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: widget.isDark
                            ? Colors.white10
                            : Colors.black.withValues(alpha: 0.06),
                      ),
                    ),
              // 底部渐变：保证标题在任何封面上都能看清
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.78),
                    ],
                    stops: const [0.42, 1],
                  ),
                ),
              ),
              Positioned(
                left: 12,
                top: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.accentColor.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    '短剧',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    if (v.note.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        v.note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
