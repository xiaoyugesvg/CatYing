import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'; // compute（弹幕解析丢 isolate）
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

/// 触发 isolate 解析的响应体长度阈值（字符）。
///
/// ⚠️ 不能设太小：isolate 冷启动本身有开销，几十 KB 的响应体
///   在主线程 `jsonDecode` 只要 1~2ms，开 isolate 反而更慢。
///   经验值：80KB ≈ 一两千条弹幕，此时主线程解析已能感知到掉帧 ✓。
const int _parseIsolateThreshold = 80000;

/// **异步解析弹幕**：响应体较大时丢到 isolate 执行，避免主线程
/// `jsonDecode` 阻塞造成掉帧；小响应体直接同步解析（省冷启动开销）。
///
/// 调用方（播放器）请一律走这个入口 —— [parseDanmuBody] 保留给
/// 单测/同步场景。
Future<List<DanmuItem>> parseDanmuBodyAsync(String body) async {
  if (body.length < _parseIsolateThreshold) return parseDanmuBody(body);
  return _flatToDanmu(await compute(_parseDanmuFlat, body));
}

/// [isolate 入口] 用 [parseDanmuBody] 做**唯一**解析（不重复一套逻辑），
/// 最后摊平成 `[[time, text, colorInt, mode], ...]` ——
/// 纯基本类型，跨 isolate **一定可发送**，不必依赖 `Color` 的可发送性。
List<Object?> _parseDanmuFlat(String body) {
  final items = parseDanmuBody(body);
  final out = <Object?>[];
  for (final d in items) {
    out.add(<Object?>[d.time, d.text, d.color.value, d.mode]);
  }
  return out;
}

/// 把 [_parseDanmuFlat] 的扁平数据还原为 [DanmuItem]（O(n) 轻量构造）。
List<DanmuItem> _flatToDanmu(List<Object?> flat) {
  final out = <DanmuItem>[];
  for (final e in flat) {
    final l = e as List;
    out.add(DanmuItem(
      (l[0] as num).toDouble(),
      l[1] as String,
      Color((l[2] as num).toInt()),
      (l[3] as num).toInt(),
    ));
  }
  return out;
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

  /// 按类型屏蔽：分别屏蔽 滚动(1) / 顶部(4) / 底部(5)
  final bool blockScroll;
  final bool blockTop;
  final bool blockBottom;

  /// 显示区域占比：1.0 = 全屏；越小越靠上（从顶部往下排）
  /// ⚠️ 已被 [topPadding] / [bottomPadding] 取代，保留仅为向后兼容。
  /// 新代码请直接用 [topPadding] / [bottomPadding] 分别控制上下边距。
  final double areaRatio;

  /// 弹幕区域顶部间距（占视频高度的百分比，0.0 ~ 0.5）。
  /// 比如 0.08 = 弹幕从视频顶部往下 8% 的位置开始，
  /// 用来避开播放器顶部的标题/返回栏。
  final double topPadding;

  /// 弹幕区域底部间距（占视频高度的百分比，0.0 ~ 0.5）。
  /// 比如 0.12 = 弹幕在视频底部往上 12% 的位置结束，
  /// 用来避开播放器底部的进度条/控制栏。
  final double bottomPadding;

  /// 行间距系数（1.0 ~ 3.0）：轨道间距 = 字号 × 本系数 + 基础间距
  final double lineSpacing;

  /// 描边宽度（0 ~ 3）：用 4 向投影模拟描边，0 时不描边
  final double strokeWidth;

  /// 字体粗细（w400 / w500 / w600 / w700）
  final FontWeight fontWeight;

  /// 弹幕延迟（秒）：正数 = 弹幕比画面晚出现，负数 = 提前
  final double delaySeconds;

  /// 强制统一颜色：null = 使用弹幕自带色；有值 = 所有弹幕都显示这个颜色
  /// （对应设置页「弹幕颜色」的「统一白色」「自定义」）。
  final Color? forceColor;

  const DanmuLayer({
    super.key,
    required this.danmus,
    required this.positionOf,
    this.fontSize = 14,
    this.opacity = 1,
    this.speed = 150,
    this.trackCount = 4,
    this.blockScroll = false,
    this.blockTop = false,
    this.blockBottom = false,
    this.areaRatio = 1.0,
    this.topPadding = 0.0,
    this.bottomPadding = 0.0,
    this.lineSpacing = 1.6,
    this.strokeWidth = 1.5,
    this.fontWeight = FontWeight.w500,
    this.delaySeconds = 0.0,
    this.forceColor,
  });

  @override
  State<DanmuLayer> createState() => _DanmuLayerState();
}

class _DanmuLayerState extends State<DanmuLayer> {
  late List<DanmuItem> _sorted;
  final List<_ActiveDanmu> _active = [];
  int _nextIndex = 0;
  Timer? _timer;
  /// Minimum gap between two scrolling danmaku on the same track (px).
  static const double _trackGap = 24.0;

  /// 同时活跃弹幕上限：超过后从最旧的开始丢。
  /// 高密度弹幕源（一集上千条）每帧可能 spawn 十几条，
  /// 不设上限的话 Stack 里 Positioned 越来越多 → 渲染越来越卡。
  static const int _maxActive = 60;

  /// 文本宽度缓存：同一条文本（同字号）只 layout 一次。
  /// `TextPainter.layout()` 是弹幕热路径里最贵的单点开销，
  /// 高密度时同一句弹幕会反复出现，缓存能省掉绝大部分。
  final Map<String, double> _widthCache = {};
  static const int _widthCacheLimit = 500;

  /// 绘制用 TextPainter 缓存（CustomPaint 模式）：同文案同样式只 layout 一次。
  /// ⚠️ 跟 `_widthCache` 是两个东西：`_widthCache` 只存宽度（用于轨道碰撞），
  ///   这里存完整的 TextPainter（用于 Canvas 绘制，含阴影/颜色）。
  final Map<String, TextPainter> _paintCache = {};

  double get _speed => widget.speed;
  int get _trackCount => widget.trackCount.clamp(2, 8);

  /// 上一次的播放位置（秒）。既用来检测 seek 跳变，**也是动画时钟**。
  double? _lastPosSec;

  /// 上一帧累计到的播放位置。**动画推进量 = 播放位置的前进量**。
  ///
  /// ── 🔴 为什么不用 `Stopwatch`（真实时钟）──────────────────────────
  /// 原实现用 `Stopwatch` 做动画时钟，于是它**完全不知道播放器是否在播**：
  /// `positionOf()` 在暂停时是冻结的，但真实时间还在流逝 →
  /// **暂停后弹幕继续往前飘** ✗（实测：暂停 600ms 后 left 从 400 → 396.33）
  ///
  /// 改用播放位置驱动后，**暂停 = 位置不动 = 弹幕冻结**，
  /// 而且"倍速播放时弹幕同比变快"这件事**天然成立**
  ///（位置前进得快，弹幕也走得快），不需要 `_danmuSyncSpeed` 那套额外补偿。
  double _lastTickPos = 0;
  bool _lastTickPosInit = false;
  /// Viewport width from LayoutBuilder; used for track collision checks.
  double _viewportWidth = 0;
  /// Viewport height from LayoutBuilder; used to shrink track count on
  /// short players (embedded detail player) so danmaku never overlap.
  double _viewportHeight = 0;

  @override
  void initState() {
    super.initState();
    _sorted = _sortedOf(widget.danmus);
    // ⚠️ 定时器只做两件事：
    //   ① 位置驱动之外的兜底刷新（固定弹幕到期、seek 清屏）
    //   ② 在播放位置停止更新时（暂停）让"该消失的"仍能消失
    // **动画推进量取自播放位置**，不取自这个定时器（见 `_lastTickPos` 的说明）。
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  @override
  void didUpdateWidget(covariant DanmuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    // ⚠️ 位置驱动：父级（播放器）每次重建都顺带推进一帧弹幕。
    //    放在最前，这样即使后面因为"列表变了"而清屏，本帧也算推进过了。
    _onPositionChanged();

    // 「按类型屏蔽」变化 → 立刻按新过滤重建（清屏避免已上屏的类型残留）
    final filtersChanged = oldWidget.blockScroll != widget.blockScroll ||
        oldWidget.blockTop != widget.blockTop ||
        oldWidget.blockBottom != widget.blockBottom;
    if (filtersChanged) {
      _sorted = _sortedOf(widget.danmus);
      _active.clear();
      _nextIndex = 0;
      _lastPosSec = null;
      return;
    }

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

  /// 按「类型屏蔽」过滤后再按时间排序。
  ///
  /// mode 语义：1 = 滚动，4 = 顶部固定，5 = 底部固定。
  /// 三者可分别屏蔽；全屏蔽时返回空列表（渲染层自然什么都不显示）。
  bool _modePasses(DanmuItem d) {
    switch (d.mode) {
      case 4:
        return !widget.blockTop;
      case 5:
        return !widget.blockBottom;
      case 1:
      default:
        return !widget.blockScroll;
    }
  }

  List<DanmuItem> _sortedOf(List<DanmuItem> source) {
    return (List<DanmuItem>.of(source)..sort((a, b) => a.time.compareTo(b.time)))
        .where(_modePasses)
        .toList();
  }

  /// 可用高度越少，轨道数越少（避免弹幕挤在窄条里重叠）。
  /// 同时考虑 areaRatio（旧 API）、topPadding/bottomPadding（新 API）
  /// 和**实际可用高度**（详情页内嵌播放器等高不够的场景）。
  int get _effectiveTrackCount {
    final base = _trackCount;
    // 新参数优先：topPadding + bottomPadding 决定可用比例
    final padTop = widget.topPadding.clamp(0.0, 0.5);
    final padBottom = widget.bottomPadding.clamp(0.0, 0.5);
    final available = 1.0 - padTop - padBottom;
    if (available <= 0) return 1;
    // 兼容旧 areaRatio：取更小的那个（更保守）
    final effectiveRatio = available < widget.areaRatio
        ? available
        : widget.areaRatio;
    int scaled;
    if (effectiveRatio >= 0.99) {
      scaled = base;
    } else {
      scaled = (base * effectiveRatio).floor();
    }
    // 🔴 按实际可用高度再压一遍（px 级）：
    //    比如详情页内嵌播放器 4:3、屏宽 390 → 高约 292，
    //    减去上下安全距后只剩 ~244px，字号 14 时行距 22px 只能放 11 行；
    //    但用户设了 8 轨道时若不压，行与行直接叠在一起 ✗。
    if (_viewportHeight > 0) {
      final topPx = _viewportHeight * padTop + 24.0;
      final bottomPx = _viewportHeight * padBottom + 24.0;
      final usableH = _viewportHeight - topPx - bottomPx;
      if (usableH > 0) {
        final byHeight = (usableH / _trackStep).floor().clamp(1, base);
        if (byHeight < scaled) scaled = byHeight;
      }
    }
    return scaled.clamp(1, base);
  }

  /// 由 `didUpdateWidget`（位置变化）与兜底定时器共同驱动。
  void _tick() {
    if (!mounted) return;

    final pos = widget.positionOf().inMilliseconds / 1000.0;
    final last = _lastPosSec;

    // ── ① seek 跳变 → 清屏 + 重定位游标 ──────────────────────────
    //
    // 阈值 0.4s：正常播放相邻两次位置差远小于它，
    // 而用户拖动/跳转至少是这个量级。
    if (last != null && (pos - last).abs() > 0.4) {
      // `_resetToPosition` 内部已把 `_lastTickPos` / `_lastTickPosInit` 对齐，
      // 这里只需补 `_lastPosSec`（seek 检测用的基准）
      _resetToPosition(pos);
      _lastPosSec = pos;
      setState(() {});
      return;
    }

    // ── ② 动画推进量 = **播放位置的前进量**（这是修暂停飘动的关键）──
    var dt = 0.0;
    if (_lastTickPosInit) {
      dt = pos - _lastTickPos;
      // 位置倒退（小幅回跳）/ 停滞 → 不推进。
      // ⚠️ 这里是"暂停时弹幕冻结"的实现点：位置不变 → dt = 0 → 什么都不动。
      if (dt < 0) dt = 0;
      // 卡顿保护：单帧最多按 0.5s 推进，避免一次跳一大截
      if (dt > 0.5) dt = 0.5;
    }
    _lastTickPos = pos;
    _lastTickPosInit = true;
    _lastPosSec = pos;

    // ── ③ 生成到期的弹幕 ────────────────────────────────────────
    //
    // ⚡ 先重建「每轨道最右边缘」数组（**一次 O(active)** ✓）——
    //   `_pickTrack` 里再遍历全量 `_active` 的话是 O(tracks × active) ✗，
    //   密集弹幕源下每帧 spawn 十几条会明显掉帧 ✓。
    //   这里重建比"增量维护"简单且不会漏更新（弹幕回收是整批 `removeWhere` ✓）。
    _rebuildTrackEdges();
    var spawned = false;
    while (_nextIndex < _sorted.length &&
        _sorted[_nextIndex].time <= pos + 0.25) {
      // 前跳后不"补播"已经过去的那批（否则 seek 会把历史弹幕一次性倒出来）
      if (_sorted[_nextIndex].time >= pos - 0.6) {
        _spawn(_sorted[_nextIndex]);
        spawned = true;
      }
      _nextIndex++;
    }

    // ── ④ 推进 / 回收 ───────────────────────────────────────────
    //
    // ⚠️ 即使 `_active` 为空也要走完并可能 `setState`：
    //    最后一帧"移除"必须真正重建一次，否则最后一条弹幕会**残留在屏上**
    //    （`_active` 已空 → 下次 tick 直接 return → 那帧就不刷新了）。
    if (dt > 0) {
      for (final a in _active) {
        if (a.item.mode == 1) {
          a.x -= _speed * dt;
        } else {
          a.remaining -= dt;
        }
      }
    }
    final before = _active.length;
    _active.removeWhere(
        (a) => a.item.mode == 1 ? a.x + a.width < -16 : a.remaining <= 0);

    // 位置在前进（dt>0）说明画面还在动 → 需要重绘；
    // 或本帧有增减（生成/回收）→ 也需要重绘。
    if (spawned || dt > 0 || before != _active.length) {
      setState(() {});
    }
  }

  /// 位置变化时被调用（父级每帧重建）→ 让弹幕动画跟上，而不是等 100ms 定时器。
  ///
  /// 这样弹幕是**每帧**推进的（60fps 顺滑），而定时器只作兜底
  ///（处理"暂停时固定弹幕到期"这类位置不变但仍需刷新的情况）。
  void _onPositionChanged() => _tick();

  /// seek 后把游标重定位到 `pos`，并清空屏上弹幕。
  ///
  /// ⚠️ 游标停在"**第一条时间 > pos** 的弹幕"，所以**恰好等于 pos 的那条
  ///    不会补播**（它算"已经过去"）。
  ///    这是有意的：否则用户每拖动一次进度条，目标点上那条就会被重播一次。
  ///    代价是"seek 到某条弹幕的精确时刻"时它不显示 —— 但相邻的照常出现，
  ///    用户感知不到（生成窗口本来就向前看 0.25s）。
  void _resetToPosition(double pos) {
    _active.clear();
    _trackRightEdge.clear(); // 清屏后轨道全空，重建一次即可
    var i = 0;
    while (i < _sorted.length && _sorted[i].time <= pos) {
      i++;
    }
    _nextIndex = i;
    _lastTickPos = pos;
    _lastTickPosInit = true;
  }

  void _spawn(DanmuItem item) {
    final width = _textWidth(item.text, widget.fontSize);
    // ⚠️ 滚动弹幕的**初始 x 必须立刻置为右边缘**（且标记已定位）：
    //    原实现把 x 留成 0，指望 build 里的 `positioned=false` 去补写 ——
    //    但本帧稍后的推进循环会先把它从 0 往左推，
    //    于是它**从屏幕左外侧进场**（等于第一条弹幕凭空少一段行程）✗
    final startX = _viewportWidth > 0 ? _viewportWidth : 0.0;
    if (item.mode == 4) {
      final lane = _pickFixedLane(top: true);
      // ✅ 修复：轨道全满时**丢弃**本条（原来返回 0 → 和第 0 条叠在一起 ✗），
      //   与滚动弹幕"全忙就丢弃"的策略保持一致 ✓。
      if (lane < 0) return;
      _active.add(_ActiveDanmu(item,
          topFixed: true, width: width, track: lane));
    } else if (item.mode == 5) {
      final lane = _pickFixedLane(top: false);
      if (lane < 0) return;
      _active.add(_ActiveDanmu(item,
          bottomFixed: true, width: width, track: lane));
    } else {
      final track = _pickTrack();
      // 轨道全忙且都会重叠 → 丢弃本条（宁可少一条，不让弹幕叠在一起）
      if (track < 0) return;
      _active.add(_ActiveDanmu(item,
          track: track,
          width: width,
          x: startX,
          positioned: true));
      // ⚡ 同步更新轨道最右边缘（供同帧后续 spawn 判断，见 `_rebuildTrackEdges`）
      if (track < _trackRightEdge.length) {
        _trackRightEdge[track] = startX + width;
      }
    }
    // 🔴 活跃数量上限：超出后从最旧的开始丢（滚动弹幕先上屏，先丢它们）。
    //    不设上限时高密度源能把 _active 堆到几百条，每帧全量重建直接卡死。
    if (_active.length > _maxActive) {
      _active.removeRange(0, _active.length - _maxActive);
    }
  }

  /// 重建「每轨道最右边缘」数组。
  ///
  /// ⚡ 性能：`_pickTrack` 需要知道每条轨道上最靠右的弹幕在哪，
  ///   原来在 `_pickTrack` 内部**双层遍历**（O(tracks × active) ✗）；
  ///   这里每帧**单次遍历** `_active` 建好数组（O(active) ✓），
  ///   `_pickTrack` 只读数组（O(tracks) ✓）。
  void _rebuildTrackEdges() {
    final tracks = _effectiveTrackCount;
    // 轨道数可能随视口高度变化（窄播放器会压缩），先对齐长度
    while (_trackRightEdge.length < tracks) {
      _trackRightEdge.add(double.negativeInfinity);
    }
    for (var t = 0; t < tracks; t++) {
      _trackRightEdge[t] = double.negativeInfinity;
    }
    for (final a in _active) {
      if (a.item.mode != 1) continue;
      if (a.track < 0 || a.track >= tracks) continue;
      final right = a.x + a.width;
      if (right > _trackRightEdge[a.track]) {
        _trackRightEdge[a.track] = right;
      }
    }
  }

  /// Top/bottom fixed danmaku: stack in vertical lanes.
  ///
  /// ✅ 修复：轨道数改为跟随 `_effectiveTrackCount`（原来写死 4 ✗ ——
  ///   用户设 8 轨道时顶部/底部固定弹幕仍只有 4 条可用；
  ///   而窄播放器下滚动轨道会被压缩到 3 条，固定弹幕却还是 4 条、会溢出 ✓）。
  ///   全满时返回 **-1**（让调用方丢弃本条，不再叠在第 0 条上 ✗）。
  int _pickFixedLane({required bool top}) {
    final maxLanes = _effectiveTrackCount.clamp(1, 6);
    for (var t = 0; t < maxLanes; t++) {
      final busy = _active.any((a) =>
          (top ? a.topFixed : a.bottomFixed) && a.track == t);
      if (!busy) return t;
    }
    return -1; // 全满 → 丢弃（与滚动弹幕同策略）
  }

  /// 每轨道最右边缘（滚动弹幕的 `x + width`）。
  /// 用数组替代 `_pickTrack` 里的双层遍历，把 O(tracks × active)
  /// 降到 O(tracks) —— 密集弹幕下省很多。
  final List<double> _trackRightEdge = [];

  /// Choose a scrolling track where the previous item has cleared enough
  /// that a new item entering at x=_viewportWidth will not collide.
  /// Same speed => relative gap stays constant, so we only check spawn time.
  /// Returns -1 when every track would overlap the incoming item.
  int _pickTrack() {
    final w = _viewportWidth;
    // 用 effective（受「显示区域」压缩），避免弹幕落到被裁掉的高度上
    final tracks = _effectiveTrackCount;
    // 确保数组长度够（轨道数可能随视口高度变化）
    while (_trackRightEdge.length < tracks) {
      _trackRightEdge.add(double.negativeInfinity);
    }
    // Prefer an empty / available track.
    var best = -1;
    var bestRight = double.infinity;
    for (var t = 0; t < tracks; t++) {
      final right = _trackRightEdge[t];
      // 轨道空闲（最右在左边界外）→ 直接用
      if (right <= -16) return t;
      // 右侧间隙够 → 可用
      if (w > 0 && right + _trackGap <= w) return t;
      // 都不够时，选最靠左的（稍后用来判断是否全丢）
      if (right < bestRight) {
        bestRight = right;
        best = t;
      }
    }
    // 🔴 所有轨道上最近一条的右边缘都还没让出足够的间隙 →
    //    新弹幕进场必然追尾重叠。返回 -1 让 _spawn 丢弃本条。
    if (best < 0 || bestRight + _trackGap > w) return -1;
    return best;
  }

  double _textWidth(String text, double fontSize) {
    final key = '$fontSize|$text';
    final cached = _widthCache[key];
    if (cached != null) return cached;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        // 🔴 必须用**实际渲染的字重**：原实现写死 w500，
        //    用户把弹幕设为 w600/w700 时渲染更宽、而宽度被低估 →
        //    轨道避让判断失真 → 弹幕追尾重叠 ✗
        style: TextStyle(fontSize: fontSize, fontWeight: widget.fontWeight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width;
    if (_widthCache.length >= _widthCacheLimit) _widthCache.clear();
    _widthCache[key] = w;
    return w;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 轨道纵向步长：字号 × 行间距系数（下限 22，避免小字号挤在一起）
  double get _trackStep {
    final v = widget.fontSize * widget.lineSpacing;
    return v < 22 ? 22 : v;
  }

  /// 用 4 向投影模拟描边（Flutter 的 TextStyle 没有 stroke 属性）。
  /// strokeWidth 为 0 时退化为一点柔和阴影，保证暗色画面下仍可读。
  List<Shadow> _strokeShadows() {
    final w = widget.strokeWidth;
    if (w <= 0.01) {
      return const [Shadow(blurRadius: 2, color: Colors.black87)];
    }
    // 偏移量越大显得描边越粗；blurRadius 保持 0 才是实边
    return [
      Shadow(offset: Offset(-w, 0), color: Colors.black),
      Shadow(offset: Offset(w, 0), color: Colors.black),
      Shadow(offset: Offset(0, -w), color: Colors.black),
      Shadow(offset: Offset(0, w), color: Colors.black),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          _viewportWidth = w;
          _viewportHeight = h;
          // Seed initial x once width is known (not x==0 sentinel).
          for (final a in _active) {
            if (a.item.mode == 1 && !a.positioned) {
              a.x = w;
              a.positioned = true;
            }
          }
          // 弹幕区域的上下边距（px）：
          //   · topPadding / bottomPadding 是用户设置的百分比
          //   · 再叠加 24px 基础安全距（防止贴边）
          final topPx = h * widget.topPadding.clamp(0.0, 0.5) + 24.0;
          final bottomPx = h * widget.bottomPadding.clamp(0.0, 0.5) + 24.0;

          // ✅ 用户 2026-10-08：「出来一卡一卡的」——
          //   原来用 `Stack + for (final a in _active) Positioned + Text`，
          //   60 条活跃弹幕 = 60 个 widget 每帧全量重建 + 60 次 layout ✗ → 严重掉帧 ✓。
          //   现在：**单个 `CustomPaint`**，所有弹幕在同一个 Canvas 上用
          //   预布局好的 `TextPainter` 直接画 ✓ —— widget 重建 0 个、
          //   layout 只在新弹幕进来时做一次 ✓，帧率能稳很多。
          //   ⚠️ ClipRect 仍然保留：弹幕进出画面时裁掉边缘 ✓。
          return ClipRect(
            child: CustomPaint(
              size: Size(w, h),
              painter: _DanmuPainter(
                active: _active,
                topPx: topPx,
                bottomPx: bottomPx,
                trackStep: _trackStep,
                forceColor: widget.forceColor,
                opacity: widget.opacity,
                painterCache: _paintCache,
                fontSize: widget.fontSize,
                fontWeight: widget.fontWeight,
                strokeWidth: widget.strokeWidth,
                strokeShadows: _strokeShadows(),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 弹幕画布：把所有活跃弹幕一次性画到同一个 Canvas 上。
///
/// 为什么用 `CustomPainter` 而不是 `Stack`：
///   · 60 条弹幕 = 60 个 `Positioned + Text` widget，每帧 setState 全量重建
///     → widget 树 diff + layout + paint 全部重走，掉帧严重。
///   · `CustomPainter` 只做一次 paint 调用，内部用 `TextPainter`
///     （已预布局）直接平移绘制，开销是 1/N。
class _DanmuPainter extends CustomPainter {
  /// 绘制缓存上限（与 state 侧共用同一个 map，这里只读它做容量判断）
  static const int cacheLimit = 500;

  final List<_ActiveDanmu> active;
  final double topPx;
  final double bottomPx;
  final double trackStep;
  final Color? forceColor;
  final double opacity;
  final Map<String, TextPainter> painterCache;
  final double fontSize;
  final FontWeight fontWeight;
  final double strokeWidth;
  final List<Shadow> strokeShadows;

  _DanmuPainter({
    required this.active,
    required this.topPx,
    required this.bottomPx,
    required this.trackStep,
    required this.forceColor,
    required this.opacity,
    required this.painterCache,
    required this.fontSize,
    required this.fontWeight,
    required this.strokeWidth,
    required this.strokeShadows,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in active) {
      final color = (forceColor ?? a.item.color).withValues(alpha: opacity);
      final key =
          '$fontSize|$fontWeight|$strokeWidth|${color.value}|${a.item.text}';
      var tp = painterCache[key];
      if (tp == null) {
        tp = TextPainter(
          text: TextSpan(
            text: a.item.text,
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: fontWeight,
              shadows: strokeShadows,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          textScaler: TextScaler.noScaling,
        )..layout();
        if (painterCache.length >= _DanmuPainter.cacheLimit) {
          painterCache.clear();
        }
        painterCache[key] = tp;
      }

      final double dy;
      final double dx;
      if (a.bottomFixed) {
        // 底部固定：从 bottomPx 往上排
        dy = size.height - bottomPx - trackStep * (a.track + 1);
        dx = (size.width - tp.width) / 2;
      } else if (a.topFixed) {
        // 顶部固定
        dy = topPx + a.track * trackStep;
        dx = (size.width - tp.width) / 2;
      } else {
        // 滚动
        dy = topPx + a.track * trackStep;
        dx = a.x;
      }
      tp.paint(canvas, Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(covariant _DanmuPainter oldDelegate) {
    // 任何参数变化都重绘（位置/列表都在变，每帧都要重画）
    return true;
  }
}
