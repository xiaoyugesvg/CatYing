import 'package:flutter/material.dart';

/// 瀑布式入场动画：卡片创建时按 index 错开延迟淡入 + 上滑
class StaggeredEntrance extends StatefulWidget {
  final int index;
  final Widget child;

  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
  });

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  // 两个 CurvedAnimation 都存成字段：它们要显式 dispose（复核报告 N5）。
  late final CurvedAnimation _fadeCurve;
  late final CurvedAnimation _slideCurve;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _fadeCurve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideCurve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _fade = _fadeCurve;
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(_slideCurve);
    // 按 index 错开延迟，形成瀑布效果
    final delay = (widget.index % 20) * 45;
    Future.delayed(Duration(milliseconds: delay), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _fadeCurve.dispose();
    _slideCurve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
