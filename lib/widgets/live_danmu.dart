import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 一条「实时弹幕」：来自房间聊天，不绑播放进度。
///
/// 与 [DanmuItem]（lib/widgets/danmaku.dart）的区别：
///   · [DanmuItem] 的 `time` 是**视频时间轴上的秒数**，靠播放位置驱动；
///   · 这里的消息是**此刻刚发生的**，没有时间轴可言（大家一起看直播/边看边聊），
///     所以按真实时钟推进 —— 暂停视频时聊天弹幕仍然继续飘。
class LiveDanmuItem {
  const LiveDanmuItem({
    required this.id,
    required this.text,
    this.color = Colors.white,
    this.mode = 1,
  });

  final String id;
  final String text;
  final Color color;

  /// 1 = 滚动（目前只做滚动）
  final int mode;
}

/// 「一起看」房间聊天的弹幕层。
///
/// 用法：把房间的聊天消息映射成 [LiveDanmuItem] 传进来，控件自己按 id 去重，
/// 只把**新出现**的消息变成弹幕 —— 所以外部可以放心传整个历史列表。
class LiveDanmuOverlay extends StatefulWidget {
  const LiveDanmuOverlay({
    super.key,
    required this.items,
    this.enabled = true,
    this.fontSize = 15,
    this.speed = 110,
    this.opacity = 0.92,
    this.strokeWidth = 1.4,
    this.maxTracks = 5,
    this.topPadding = 8,
    this.bottomPadding = 8,
    this.showAuthor = true,
  });

  final List<LiveDanmuItem> items;
  final bool enabled;
  final double fontSize;

  /// 横向速度（px/s）
  final double speed;
  final double opacity;
  final double strokeWidth;
  final int maxTracks;
  final double topPadding;
  final double bottomPadding;

  /// 是否给每条加一层浅色描边（压在亮画面上也看得清）
  final bool showAuthor;

  @override
  State<LiveDanmuOverlay> createState() => _LiveDanmuOverlayState();
}

class _LiveItem {
  _LiveItem({
    required this.text,
    required this.color,
    required this.track,
    required this.x,
    required this.width,
  });

  final String text;
  final Color color;
  final int track;
  double x;
  final double width;
}

class _LiveDanmuOverlayState extends State<LiveDanmuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final List<_LiveItem> _active = [];
  final Set<String> _seen = {};

  /// 每条轨道的「最右边缘」—— 用来判断该轨道还能不能塞下一条
  final Map<int, double> _trackRight = {};

  double _width = 0;
  double _height = 0;
  double _lastMs = 0;

  /// 同时在屏上限：房间人多时消息刷得快，不设上限会一直涨
  static const int _maxActive = 40;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _lastMs = DateTime.now().millisecondsSinceEpoch.toDouble();
  }

  @override
  void didUpdateWidget(covariant LiveDanmuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.items, widget.items)) {
      _spawnNew(widget.items);
    }
    if (!widget.enabled && _active.isNotEmpty) {
      _active.clear();
      _trackRight.clear();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  int get _tracks =>
      widget.maxTracks.clamp(1, math.max(1, (_height / (_trackStep)).floor()));

  double get _trackStep => widget.fontSize * 1.9;

  void _onTick(Duration _) {
    final now = DateTime.now().millisecondsSinceEpoch.toDouble();
    var dt = (now - _lastMs) / 1000.0;
    _lastMs = now;
    if (dt <= 0) return;
    if (dt > 0.5) dt = 0.5;
    if (!widget.enabled || _active.isEmpty) return;
    final dx = widget.speed * dt;
    var changed = false;
    for (final item in _active) {
      item.x -= dx;
      changed = true;
    }
    _active.removeWhere((item) {
      final gone = item.x + item.width < -8;
      if (gone) {
        // 轨道空出来了：把它的右边缘重置，下一条可以立刻用
        _trackRight[item.track] = 0;
      }
      return gone;
    });
    if (changed) setState(() {});
  }

  /// 只把**没见过的 id** 变成弹幕（外部可以整列表传进来）
  void _spawnNew(List<LiveDanmuItem> items) {
    if (!widget.enabled || _width <= 0) {
      // 视口还没测量出来：先记账，等 build 里补
      return;
    }
    for (final it in items) {
      if (it.id.isEmpty || _seen.contains(it.id)) continue;
      _seen.add(it.id);
      if (it.text.trim().isEmpty) continue;
      _spawn(it);
    }
    if (_seen.length > 2000) {
      // 防止长房间无限增长：只保留最近的一批 id
      final keep = items.map((e) => e.id).toSet();
      _seen.removeWhere((id) => !keep.contains(id));
    }
  }

  void _spawn(LiveDanmuItem it) {
    final painter = _layout(it);
    final track = _pickTrack(painter.width);
    if (track < 0) return; // 所有轨道都还挤着：这条丢掉，别叠成一团
    final item = _LiveItem(
      text: it.text,
      color: it.color,
      track: track,
      x: _width,
      width: painter.width,
    );
    _trackRight[track] = _width + painter.width + 24;
    _active.add(item);
    while (_active.length > _maxActive) {
      _active.removeAt(0);
    }
    setState(() {});
  }

  TextPainter _layout(LiveDanmuItem it) {
    final tp = TextPainter(
      text: TextSpan(
        text: it.text,
        style: TextStyle(
          fontSize: widget.fontSize,
          fontWeight: FontWeight.w600,
          color: it.color.withValues(alpha: widget.opacity),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp;
  }

  /// 找一条「最后一条已经飘出去足够远」的轨道；没有就返回 -1
  int _pickTrack(double width) {
    final count = _tracks;
    for (var i = 0; i < count; i++) {
      final right = _trackRight[i] ?? 0;
      // 留 24px 间隔，避免两条首尾相接看起来像一条长句
      if (right <= _width - 24) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final firstMeasure = _width == 0;
        _width = constraints.maxWidth;
        _height = constraints.maxHeight;
        if (firstMeasure) {
          // 视口第一次测量完成：把已有消息补成弹幕
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _spawnNew(widget.items);
          });
        }
        return IgnorePointer(
          child: ClipRect(
            child: CustomPaint(
              painter: _LiveDanmuPainter(
                items: _active,
                fontSize: widget.fontSize,
                opacity: widget.opacity,
                strokeWidth: widget.strokeWidth,
                trackStep: _trackStep,
                topPadding: widget.topPadding,
                bottomPadding: widget.bottomPadding,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class _LiveDanmuPainter extends CustomPainter {
  _LiveDanmuPainter({
    required this.items,
    required this.fontSize,
    required this.opacity,
    required this.strokeWidth,
    required this.trackStep,
    required this.topPadding,
    required this.bottomPadding,
  });

  final List<_LiveItem> items;
  final double fontSize;
  final double opacity;
  final double strokeWidth;
  final double trackStep;
  final double topPadding;
  final double bottomPadding;

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty) return;
    final bottomLimit = size.height - bottomPadding - trackStep;
    for (final item in items) {
      final y = topPadding + item.track * trackStep;
      if (y > bottomLimit) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: item.text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            color: item.color.withValues(alpha: opacity),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      if (strokeWidth > 0) {
        // 4 向投影模拟描边：压在白亮画面上也读得清
        final stroke = TextPainter(
          text: TextSpan(
            text: item.text,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = strokeWidth
                ..color = Colors.black.withValues(alpha: 0.45 * opacity),
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        stroke.paint(canvas, Offset(item.x, y));
      }
      tp.paint(canvas, Offset(item.x, y));
    }
  }

  @override
  bool shouldRepaint(covariant _LiveDanmuPainter old) =>
      old.items != items ||
      old.fontSize != fontSize ||
      old.opacity != opacity ||
      old.trackStep != trackStep;
}
