import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

// ============================================================

class DanmuItem {
  final double time; // 秒
  final String text;
  final Color color;
  final int mode; // 1 滚动, 4 顶部, 5 底部
  DanmuItem(this.time, this.text, this.color, this.mode);
}

String _decodeXmlText(String raw) {
  if (raw.isEmpty) return raw;
  return raw
      .replaceAll(RegExp(r'&lt;', caseSensitive: false), '<')
      .replaceAll(RegExp(r'&gt;', caseSensitive: false), '>')
      .replaceAll(RegExp(r'&quot;', caseSensitive: false), '"')
      .replaceAll(RegExp(r'&apos;', caseSensitive: false), "'")
      .replaceAll(RegExp(r'&amp;', caseSensitive: false), '&')
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  }).replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
}

/// 解析弹幕响应体：兼容
/// - Logvr-danmu / 弹弹play JSON（data 数组, 元素含 p/m 或 time/text 或 timepoint/ct/content 或 progress/mode/content）
/// - B站 XML（<d p="...">text</d>）
List<DanmuItem> parseDanmuBody(String body) {
  final items = <DanmuItem>[];
  try {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return items;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final decoded = jsonDecode(trimmed);
      List<dynamic> arr = [];
      if (decoded is List) {
        arr = decoded;
      } else if (decoded is Map) {
        if (decoded['data'] is List) arr = decoded['data'] as List;
        else if (decoded['comments'] is List) arr = decoded['comments'] as List;
        else if (decoded['danmaku'] is List) arr = decoded['danmaku'] as List;
      }
      for (final e in arr) {
        if (e is! Map) continue;
        double? t;
        String? text;
        var color = 0xFFFFFFFF;
        var mode = 1;
        var modeFromP = false;
        var colorFromP = false;
        // 新格式 progress/mode/content
        if (e['progress'] is num) t = (e['progress'] as num) / 1000.0;
        // DPlayer time/text
        if (e['time'] is num) t = (e['time'] as num).toDouble();
        if (e['time'] is String) t = double.tryParse(e['time'] as String);
        // 弹弹play t / timepoint：注释与文档均为**毫秒**，必须 /1000 成秒
        // 否则 t=125000 会当成 125000 秒，弹幕永不出现
        if (e['t'] is num) {
          final tv = (e['t'] as num).toDouble();
          // 弹弹play 为毫秒；部分源为秒 —— >10000 视为毫秒
          t = tv > 10000 ? tv / 1000.0 : tv;
        }
        if (e['timepoint'] is num) {
          final tp = (e['timepoint'] as num).toDouble();
          // 部分源 timepoint 已是秒；>10000 视为毫秒
          t = tp > 10000 ? tp / 1000.0 : tp;
        }
        // p 属性（弹弹play: 时间,模式,颜色,...）——权威字段
        final p = e['p'];
        if (p is String) {
          final parts = p.split(',');
          if (parts.isNotEmpty) {
            final pt = double.tryParse(parts[0].trim());
            if (pt != null) t = pt;
          }
          if (parts.length > 1) {
            final pm = int.tryParse(parts[1].trim());
            if (pm != null) {
              mode = pm;
              modeFromP = true;
            }
          }
          if (parts.length > 2) {
            final c = int.tryParse(parts[2].trim());
            if (c != null) {
              color = c | 0xFF000000;
              colorFromP = true;
            }
          }
        }
        // mode：p 未给时才用独立字段，避免被后面的 ct 覆盖
        if (!modeFromP && e['mode'] is num) {
          mode = (e['mode'] as num).toInt();
        }
        // ct 各家语义不一：小整数当 mode，大整数当颜色
        if (e['ct'] is num) {
          final ct = (e['ct'] as num).toInt();
          if (ct >= 1 && ct <= 9) {
            if (!modeFromP) mode = ct;
          } else if (ct > 10 && !colorFromP) {
            color = (ct & 0xFFFFFF) | 0xFF000000;
          }
        }
        if (!colorFromP && e['color'] is num) {
          color = ((e['color'] as num).toInt() & 0xFFFFFF) | 0xFF000000;
        }
        text = e['text']?.toString() ??
            e['m']?.toString() ??
            e['content']?.toString() ??
            e['c']?.toString();
        if (t != null && text != null && text.isNotEmpty) {
          items.add(DanmuItem(t, text, Color(color), mode));
        }
      }
    } else if (trimmed.startsWith('<')) {
      // B站 XML：兼容单/双引号、空内容、实体；p 属性为逗号分隔
      final re = RegExp(
        r'''<d\s+[^>]*p\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</d>''',
        caseSensitive: false,
      );
      for (final m in re.allMatches(trimmed)) {
        final parts = m.group(1)!.split(',');
        final t = double.tryParse(parts[0].trim());
        final mode = parts.length > 1 ? (int.tryParse(parts[1].trim()) ?? 1) : 1;
        var color = 0xFFFFFFFF;
        if (parts.length > 3) {
          final c = int.tryParse(parts[3].trim());
          if (c != null) color = c | 0xFF000000;
        }
        final text = _decodeXmlText(m.group(2) ?? '');
        if (t != null && text.isNotEmpty) {
          items.add(DanmuItem(t, text, Color(color), mode));
        }
      }
    }
  } catch (e) {
    // 解析失败丢弃本批，避免半截数据上屏
    // ignore: avoid_print
    print('[Danmu] parseDanmuBody failed: $e');
  }
  return items;
}

class _ActiveDanmu {
  final DanmuItem item;
  int track;
  double x; // scrolling danmaku current x
  double width;
  bool topFixed;
  bool bottomFixed;
  double remaining; // top/bottom fixed remaining seconds
  /// Whether initial x has been written. Do NOT use x==0 as sentinel:
  /// a scrolling item's x can land exactly on 0 mid-flight.
  bool positioned;
  _ActiveDanmu(
    this.item, {
    this.track = 0,
    this.x = 0,
    this.width = 0,
    this.topFixed = false,
    this.bottomFixed = false,
    this.remaining = 4.0,
    this.positioned = false,
  });
}

/// Danmaku layer: emit by playback position; scroll / top / bottom.
class DanmuLayer extends StatefulWidget {
  final List<DanmuItem> danmus;
  final Duration Function() positionOf;
  final double fontSize;
  final double opacity;
  final double speed; // px/s
  final int trackCount;
  const DanmuLayer({
    super.key,
    required this.danmus,
    required this.positionOf,
    this.fontSize = 14,
    this.opacity = 1,
    this.speed = 150,
    this.trackCount = 4,
  });

  @override
  State<DanmuLayer> createState() => DanmuLayerState();
}

class DanmuLayerState extends State<DanmuLayer> {
  late List<DanmuItem> _sorted;
  final List<_ActiveDanmu> _active = [];
  int _nextIndex = 0;
  Timer? _timer;
  /// Minimum gap between two scrolling danmaku on the same track (px).
  static const double _trackGap = 24.0;

  double get _speed => widget.speed;
  int get _trackCount => widget.trackCount.clamp(2, 8);

  /// Previous tick position in seconds; used to detect seek jumps.
  double? _lastPosSec;
  /// Real elapsed clock so UI jank does not slow scrolling.
  final Stopwatch _clock = Stopwatch();
  double _lastTickSec = 0;
  /// Viewport width from LayoutBuilder; used for track collision checks.
  double _viewportWidth = 0;

  @override
  void initState() {
    super.initState();
    _sorted = _sortedOf(widget.danmus);
    _clock.start();
    _timer = Timer.periodic(const Duration(milliseconds: 100), _onTick);
  }

  @override
  void didUpdateWidget(covariant DanmuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Episode / reload changed the list: rebuild index and clear screen.
    if (!identical(oldWidget.danmus, widget.danmus)) {
      final oldLen = _sorted.length;
      final oldHead = oldLen > 0 ? _sorted.first : null;
      final newSorted = _sortedOf(widget.danmus);
      final newHead = newSorted.isNotEmpty ? newSorted.first : null;
      final contentChanged = oldLen != newSorted.length ||
          oldHead?.text != newHead?.text ||
          oldHead?.time != newHead?.time;
      if (contentChanged) {
        _sorted = newSorted;
        _active.clear();
        _nextIndex = 0;
        _lastPosSec = null;
      }
    }
  }

  List<DanmuItem> _sortedOf(List<DanmuItem> source) {
    return List<DanmuItem>.of(source)
      ..sort((a, b) => a.time.compareTo(b.time));
  }

  void _onTick(Timer _) {
    if (!mounted) return;
    final nowSec = _clock.elapsedMicroseconds / 1e6;
    var dt = nowSec - _lastTickSec;
    _lastTickSec = nowSec;
    // Clamp: debugger pauses / background stalls must not teleport danmaku.
    if (dt <= 0) dt = 0.1;
    if (dt > 0.5) dt = 0.5;

    final pos = widget.positionOf().inMilliseconds / 1000.0;

    // Seek jump -> reset cursor and clear on-screen items.
    final last = _lastPosSec;
    if (last != null && (pos - last).abs() > 0.4) {
      _resetToPosition(pos);
    }
    _lastPosSec = pos;

    var spawned = false;
    while (_nextIndex < _sorted.length &&
        _sorted[_nextIndex].time <= pos + 0.25) {
      // Do not dump the whole past after a forward seek.
      if (_sorted[_nextIndex].time >= pos - 0.6) {
        _spawn(_sorted[_nextIndex]);
        spawned = true;
      }
      _nextIndex++;
    }
    if (_active.isEmpty && !spawned) return;
    for (final a in _active) {
      if (a.item.mode == 1) {
        a.x -= _speed * dt;
      } else {
        a.remaining -= dt;
      }
    }
    final before = _active.length;
    _active.removeWhere(
        (a) => a.item.mode == 1 ? a.x + a.width < -16 : a.remaining <= 0);
    if (spawned || _active.isNotEmpty || before != _active.length) {
      setState(() {});
    }
  }

  void _resetToPosition(double pos) {
    _active.clear();
    var i = 0;
    while (i < _sorted.length && _sorted[i].time <= pos) {
      i++;
    }
    _nextIndex = i;
  }

  void _spawn(DanmuItem item) {
    final width = _textWidth(item.text, widget.fontSize);
    if (item.mode == 4) {
      final lane = _pickFixedLane(top: true);
      _active.add(_ActiveDanmu(item,
          topFixed: true, width: width, track: lane));
    } else if (item.mode == 5) {
      final lane = _pickFixedLane(top: false);
      _active.add(_ActiveDanmu(item,
          bottomFixed: true, width: width, track: lane));
    } else {
      final track = _pickTrack();
      _active.add(_ActiveDanmu(item, track: track, width: width));
    }
  }

  /// Top/bottom fixed danmaku: stack in vertical lanes (track * 28px).
  /// Reuse a lane only when the previous item there has expired.
  int _pickFixedLane({required bool top}) {
    const maxLanes = 4;
    for (var t = 0; t < maxLanes; t++) {
      final busy = _active.any((a) =>
          (top ? a.topFixed : a.bottomFixed) && a.track == t);
      if (!busy) return t;
    }
    return 0;
  }

  /// Choose a scrolling track where the previous item has cleared enough
  /// that a new item entering at x=_viewportWidth will not collide.
  /// Same speed => relative gap stays constant, so we only check spawn time.
  int _pickTrack() {
    final w = _viewportWidth;
    // Prefer an empty track.
    for (var t = 0; t < _trackCount; t++) {
      final busy = _active.any((a) => a.item.mode == 1 && a.track == t);
      if (!busy) return t;
    }
    // All busy: pick the track whose last item is furthest to the left
    // (largest free span on the right).
    var best = 0;
    var bestRight = double.infinity;
    for (var t = 0; t < _trackCount; t++) {
      double? maxRight;
      for (final a in _active) {
        if (a.item.mode != 1 || a.track != t) continue;
        final right = a.x + a.width;
        if (maxRight == null || right > maxRight) maxRight = right;
      }
      final right = maxRight ?? double.infinity;
      // Free enough if last right edge + gap <= spawn x (viewport width).
      if (w > 0 && right + _trackGap <= w) {
        return t;
      }
      if (right < bestRight) {
        bestRight = right;
        best = t;
      }
    }
    return best;
  }

  double _textWidth(String text, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          _viewportWidth = w;
          // Seed initial x once width is known (not x==0 sentinel).
          for (final a in _active) {
            if (a.item.mode == 1 && !a.positioned) {
              a.x = w;
              a.positioned = true;
            }
          }
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (final a in _active)
                Positioned(
                  left: a.item.mode == 1 ? a.x : 0,
                  top: a.item.mode == 1
                      ? 12.0 + a.track * 28.0
                      : (a.topFixed
                          ? 12.0 + a.track * 28.0
                          : h - 34.0 - a.track * 28.0),
                  child: Text(
                    a.item.text,
                    // 弹幕字号由用户单独设置，豁免全局字号缩放，
                    // 避免 textScaler 放大后与实际渲染宽度不一致
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      color: a.item.color.withValues(alpha: widget.opacity),
                      fontSize: widget.fontSize,
                      fontWeight: FontWeight.w500,
                      shadows: const [
                        Shadow(blurRadius: 2, color: Colors.black87),
                      ],
                    ),
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
