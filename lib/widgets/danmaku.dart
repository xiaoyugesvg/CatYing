import 'dart:convert';

import 'package:flutter/foundation.dart'; // compute（弹幕解析丢 isolate）
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart'; // Ticker（每帧推进弹幕）
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================

/// 弹幕滚动速度（px/s）的默认值与可调范围。
///
/// 旧默认 150px/s 在手机上约 2.6 秒就穿屏，用户 2026-10-18 反馈「太快了」，
/// 统一放慢到 90（约 4.5 秒穿屏），范围收窄到 50~200。
/// 播放器与设置页共用这几个常量，避免两处默认值/范围漂移。
const String kDanmuSpeedPrefKey = 'danmu_speed';
const double kDanmuSpeedDefault = 90;
const double kDanmuSpeedMin = 50;
const double kDanmuSpeedMax = 200;

/// 一次性迁移标记：老存档里的 150 是旧默认值（不是用户主动调的），统一降到 90。
const String _kDanmuSpeedMigrated = 'danmu_speed_slower_v1';

/// 读取滚动速度（含一次性放慢迁移）。
Future<double> loadDanmuSpeed(SharedPreferences prefs) async {
  var v = (prefs.getDouble(kDanmuSpeedPrefKey) ?? kDanmuSpeedDefault)
      .clamp(kDanmuSpeedMin, kDanmuSpeedMax)
      .toDouble();
  if (prefs.getBool(_kDanmuSpeedMigrated) != true) {
    // 只迁移"旧默认值 150"—— 用户真的手动拖到 150 的概率极低，
    // 而其他数值（自己调过的）保持不动。
    if ((v - 150).abs() < 0.5) v = kDanmuSpeedDefault;
    await prefs.setBool(_kDanmuSpeedMigrated, true);
    await prefs.setDouble(kDanmuSpeedPrefKey, v);
  }
  return v;
}

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
  /// 预解析好的绘制对（fill + 可选描边），spawn 时从缓存取，
  /// paint 帧直接用 —— 避免每帧每条拼 key 查 map（60 条 × 60fps 的
  /// 字符串拼接都在热路径上）。样式参数变化时由 didUpdateWidget 置空重建。
  _DanmuPaint? paint;
  _ActiveDanmu(
    this.item, {
    this.track = 0,
    this.x = 0,
    this.width = 0,
    this.topFixed = false,
    this.bottomFixed = false,
    this.remaining = 4.0,
    this.positioned = false,
    this.paint,
  });
}

/// 一条弹幕的绘制对：填充层 + 可选描边层（描边画在填充下面）。
///
/// ── 为什么不是 TextStyle.shadows（旧方案）────────────────────────
/// 旧实现用 4 向投影模拟描边：Skia 对带 N 个 shadow 的文本要
/// **N+1 次全量光栅化**（4 shadow + 1 主体，且 shadow 带 blur 更贵），
/// 60 条弹幕 = 每帧 ~300 次文本绘制 —— 这是弹幕卡顿的最大单点。
/// 改成 stroke（PaintingStyle.stroke）画一遍黑边 + fill 画一遍主体，
/// 每条固定 **2 次无 blur 绘制**，视觉等效、开销约降 60%。
class _DanmuPaint {
  final TextPainter fill;
  final TextPainter? stroke; // null = 无描边（strokeWidth=0）
  const _DanmuPaint(this.fill, this.stroke);

  /// 构造一条弹幕的绘制对：填充层 + 可选描边层（黑边画在填充下面）。
  ///
  /// 描边用 `PaintingStyle.stroke` 一次画成（替代旧 4 向阴影投影的
  /// 5 次光栅化）；`strokeWidth` ×2 等效原投影外扩的视觉粗细。
  static _DanmuPaint build({
    required DanmuItem item,
    required Color color,
    required double fontSize,
    required FontWeight fontWeight,
    required double strokeWidth,
  }) {
    final base = TextStyle(fontSize: fontSize, fontWeight: fontWeight);
    final fill = TextPainter(
      text: TextSpan(text: item.text, style: base.copyWith(color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: TextScaler.noScaling,
    )..layout();
    TextPainter? stroke;
    if (strokeWidth > 0.01) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = Colors.black;
      stroke = TextPainter(
        text:
            TextSpan(text: item.text, style: base.copyWith(foreground: paint)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        textScaler: TextScaler.noScaling,
      )..layout();
    }
    return _DanmuPaint(fill, stroke);
  }
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

  /// 同时活跃弹幕上限（可调；高密度源调低更流畅，调高更热闹）。
  /// 高密度弹幕源（一集上千条）每帧可能 spawn 十几条，
  /// 不设上限的话活跃列表越来越多 → 渲染越来越卡。
  final int maxActive;

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
    this.maxActive = 60,
  });

  @override
  State<DanmuLayer> createState() => _DanmuLayerState();
}

/// 仅用于驱动 `CustomPaint` 重绘的 `Listenable` —— 弹幕每帧都在动，
/// 用 `setState` 会**整棵子树重建** ✗；`CustomPaint(repaint:)` 只重跑 paint ✓。
class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _DanmuLayerState extends State<DanmuLayer>
    with SingleTickerProviderStateMixin {
  late List<DanmuItem> _sorted;
  final List<_ActiveDanmu> _active = [];
  int _nextIndex = 0;

  /// 🟢 **每帧推进弹幕**。
  ///
  /// ── 为什么需要它（修“卡卡卡卡”）────────────────────────────
  /// 原来只靠 `Timer.periodic(100ms)` 推进 ⇒ 弹幕约 **10fps** ✗。
  /// 之所以不能指望父级每帧重建：播放位置走 `ValueNotifier` **局部重建**，
  /// 播放器的 `build` 基本不跑 ⇒ `didUpdateWidget` 不触发 ✗。
  /// 现在用 `Ticker`（每帧回调）驱动，且推进量仍取自**播放位置**
  ///（见 `_lastTickPos`）⇒ 暂停冻结 / 倍速同步两个特性都不受影响 ✓。
  late final Ticker _ticker;

  /// 重绘通知器（见 [_Repaint]）。
  final _Repaint _repaint = _Repaint();
  /// Minimum gap between two scrolling danmaku on the same track (px).
  static const double _trackGap = 24.0;

  /// 同时活跃弹幕上限：超过后从最旧的开始丢。
  /// 默认 60，可在「设置 → 弹幕管理 → 同屏上限」调整。
  int get _maxActive => widget.maxActive.clamp(10, 200);

  /// 补播队列 + 每帧铺设上限：把"列表就绪瞬间几十条弹幕的文本布局"
  /// 分摊到连续几帧（每帧 2 条 ≈ 0.5ms），消除单次掉帧。
  ///
  /// ⚠️ 用户 2026-10-18：「一次出一堆，卡卡的」—— 原来每帧铺 10 条、
  ///   队列最多收 60 条 ⇒ 列表就绪后约 100ms 内整屏一起冒出来。
  ///   现在改成**小批量 + 批次间隔**（每帧最多 2 条、每批间隔 4 帧），
  ///   队列上限也降到 12 条，观感是陆续飘进来而不是"糊一屏"。
  final List<DanmuItem> _pendingCatchup = [];
  static const int _catchupPerFrame = 2;
  static const int _catchupMax = 12;
  static const int _catchupGapFrames = 4;
  int _catchupCooldown = 0;

  /// 正常生成路径的每帧上限：与补播对齐，防止密集场景下一帧 spawn 十几条
  /// 全部走 TextPainter.layout（每条 1~2ms）→ 单帧 20ms+ 掉帧。
  /// 超出部分留到下一帧继续（`_nextIndex` 不推进，条件仍满足）。
  static const int _spawnPerFrame = 8;

  /// 绘制用 TextPainter 缓存（CustomPaint 模式）：同文案同样式只 layout 一次。
  /// ⚠️ 与旧 `_widthCache` 合并：现在宽度直接取缓存里 fill 层的 `.width`，
  ///   一份缓存同时服务「轨道碰撞测宽」和「Canvas 绘制」两处。
  final Map<String, _DanmuPaint> _paintCache = {};
  static const int _paintCacheLimit = 500;

  /// 解析（或命中缓存）一条弹幕的绘制对。
  ///
  /// 🔴 只在 spawn / 补播 / 样式失效时调用 —— **绝不在 paint 帧里拼 key**
  ///   （paint 帧直接读 `_ActiveDanmu.paint`，见 [_DanmuPainter.paint]）。
  _DanmuPaint _painterFor(DanmuItem item) {
    final color =
        (widget.forceColor ?? item.color).withValues(alpha: widget.opacity);
    final key = '${widget.fontSize}|${widget.fontWeight}|'
        '${widget.strokeWidth}|${color.toARGB32()}|${item.text}';
    final hit = _paintCache[key];
    if (hit != null) return hit;
    final p = _DanmuPaint.build(
      item: item,
      color: color,
      fontSize: widget.fontSize,
      fontWeight: widget.fontWeight,
      strokeWidth: widget.strokeWidth,
    );
    // 🔴 满了不能整表 clear：60 条活跃弹幕下帧全部重 layout = 90ms 大卡顿。
    //   改为滑动淘汰最旧的一半（Dart Map 保插入序，keys 前半即最旧），
    //   把淘汰成本摊到后续帧的惰性重建上，单帧开销可控。
    if (_paintCache.length >= _paintCacheLimit) {
      final keys = _paintCache.keys.toList();
      final removeCount = (keys.length / 2).ceil();
      for (var i = 0; i < removeCount; i++) {
        _paintCache.remove(keys[i]);
      }
    }
    _paintCache[key] = p;
    return p;
  }

  /// 样式参数（字号/字重/描边/颜色/透明度）变化时：清缓存 + 置空已上屏
  /// 弹幕的绘制对，让下一帧按新参数惰性重建。
  void _invalidatePaints() {
    _paintCache.clear();
    for (final a in _active) {
      a.paint = null;
    }
  }

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
    // ✅ 用户 2026-10-10：「弹幕要视频一开始就出现」——
    //    弹幕列表是**异步加载**的，就绪时视频往往已经播了几秒；
    //    而正常生成逻辑会丢弃"过去超过 0.6s"的弹幕（防 seek 倒历史），
    //    于是首屏要空等到下一条到点 ⇒ 观感「半天没有弹幕」✗。
    //    首帧后（视口宽度已知）补播一次：把刚过去一小段窗口内的弹幕
    //    按"仿佛按时上屏"的虚拟位置直接摆上屏 ✓。
    if (_sorted.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _resetToPosition(
          widget.positionOf().inMilliseconds / 1000.0,
          catchup: true,
        );
        _repaint.notify();
      });
    }
    // 每帧推进（动画量取自播放位置，见 `_lastTickPos` 的说明）。
    // ⚠️ 暂停时 `dt == 0` ⇒ 不通知重绘 ⇒ 零额外开销 ✓。
    _ticker = createTicker((_) => _tick())..start();
  }

  @override
  void didUpdateWidget(covariant DanmuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    // ⚠️ 位置推进已由 Ticker 每帧驱动（见 `_tick`），这里**不再**调
    //   `_onPositionChanged`：父级每帧重建会让 didUpdateWidget 也每帧跑，
    //   再调一次 `_tick` 等于每帧双倍工作量（_rebuildTrackEdges / spawn 检查 /
    //   removeWhere / notify 全跑两遍），白白吃掉一帧预算。
    //   Ticker 在 initState 启动、dispose 销毁，期间始终每帧驱动，不依赖父级重建。

    // 「按类型屏蔽」变化 → 立刻按新过滤重建（清屏避免已上屏的类型残留）
    final filtersChanged = oldWidget.blockScroll != widget.blockScroll ||
        oldWidget.blockTop != widget.blockTop ||
        oldWidget.blockBottom != widget.blockBottom;
    if (filtersChanged) {
      _sorted = _sortedOf(widget.danmus);
      // ⚠️ 2026-10-14：这里**不能**把游标直接置 0（原实现）—— spawn 循环每帧
      //   只处理 `_spawnPerFrame` 条、且把"已过去"的整批丢弃 ⇒ 游标要从第 0 条
      //   一路"爬"到当前播放位置，播放中切一下屏蔽类型就会**空白一两秒**
      //   并空转 CPU。复用 seek 路径已验证的 `_resetToPosition` 精确重定位
      //  （它内部会清 `_active` / `_pendingCatchup` / 轨道边缘）。
      _resetToPosition(_lastPosSec ?? 0);
      return;
    }

    // 绘制样式变化 → 已上屏弹幕的绘制对全部失效（按新样式惰性重建）
    if (oldWidget.fontSize != widget.fontSize ||
        oldWidget.fontWeight != widget.fontWeight ||
        oldWidget.strokeWidth != widget.strokeWidth ||
        oldWidget.forceColor != widget.forceColor ||
        oldWidget.opacity != widget.opacity) {
      _invalidatePaints();
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
        // 换集/重新加载：同样补播，让新列表立刻铺满屏幕（不等下一条到点）
        _resetToPosition(
          widget.positionOf().inMilliseconds / 1000.0,
          catchup: true,
        );
        _lastPosSec = null;
        _repaint.notify();
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
      _repaint.notify();
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
    var spawnCount = 0;
    while (_nextIndex < _sorted.length &&
        _sorted[_nextIndex].time <= pos + 0.25 &&
        spawnCount < _spawnPerFrame) {
      // 前跳后不"补播"已经过去的那批（否则 seek 会把历史弹幕一次性倒出来）
      if (_sorted[_nextIndex].time >= pos - 0.6) {
        _spawn(_sorted[_nextIndex]);
        spawned = true;
      }
      _nextIndex++;
      spawnCount++;
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

    // 补播队列分帧铺开：每帧最多 `_catchupPerFrame` 条，且批次之间留几帧
    // 间隔 —— 避免"列表就绪瞬间整屏一起冒出来"（用户 2026-10-18 反馈）。
    var drained = 0;
    if (_pendingCatchup.isNotEmpty) {
      if (_catchupCooldown > 0) {
        _catchupCooldown--;
      } else {
        drained = _drainCatchup(pos, budget: _catchupPerFrame);
        if (drained > 0) _catchupCooldown = _catchupGapFrames;
      }
    }

    // 位置在前进（dt>0）说明画面还在动 → 需要重绘；
    // 或本帧有增减（生成/回收/补播）→ 也需要重绘。
    if (spawned || drained > 0 || dt > 0 || before != _active.length) {
      _repaint.notify();
    }
  }

  /// seek 后把游标重定位到 `pos`，并清空屏上弹幕。
  ///
  /// ⚠️ 游标停在"**第一条时间 > pos** 的弹幕"，所以**恰好等于 pos 的那条
  ///    不会补播**（它算"已经过去"）。
  ///    这是有意的：否则用户每拖动一次进度条，目标点上那条就会被重播一次。
  ///    代价是"seek 到某条弹幕的精确时刻"时它不显示 —— 但相邻的照常出现，
  ///    用户感知不到（生成窗口本来就向前看 0.25s）。
  void _resetToPosition(double pos, {bool catchup = false}) {
    _active.clear();
    _trackRightEdge.clear(); // 清屏后轨道全空，重建一次即可
    _pendingCatchup.clear(); // seek/换集时丢弃未铺完的补播
    _catchupCooldown = 0;
    var i = 0;
    while (i < _sorted.length && _sorted[i].time <= pos) {
      i++;
    }
    _nextIndex = i;
    _lastTickPos = pos;
    _lastTickPosInit = true;
    if (catchup) _enqueueCatchup(pos);
  }

  /// 把"刚过去一小段窗口"内的弹幕收进补播队列（时间正序）。
  ///
  /// ── 为什么用队列分帧铺 ─────────────────────────────────
  /// 一次性同步上屏几十条 ⇒ 同帧几十次文本布局 ⇒ 单次掉帧 ✗。
  /// 这里只**扫描收集**（不测宽度、零布局），由 `_drainCatchup`
  /// 每帧铺 `_catchupPerFrame` 条 ✓；布局成本被分摊到几帧里。
  void _enqueueCatchup(double pos) {
    _pendingCatchup.clear();
    if (_sorted.isEmpty || _nextIndex <= 0) return;
    final startX = _viewportWidth > 0 ? _viewportWidth : 0.0;
    // 补播窗口：速度越慢/屏越宽，弹幕在屏内停留越久，能补的窗口越长。
    // 封顶 6 秒 + 最多 12 条 —— 补太多会在就绪瞬间"糊一屏"（用户反馈）。
    final window =
        _speed > 0 ? ((startX + 240) / _speed).clamp(2.5, 6.0) : 4.0;
    // 从游标往前扫（时间倒序），超窗即停；头插 ⇒ 收完即时间正序
    for (var i = _nextIndex - 1; i >= 0; i--) {
      final d = _sorted[i];
      if (pos - d.time > window) break;
      if (_pendingCatchup.length >= _catchupMax) break;
      _pendingCatchup.insert(0, d);
    }
  }

  /// 每帧从补播队列铺最多 `_catchupPerFrame` 条上屏。
  /// 位置按**当前**播放位置现算（队列等待期间播放仍在走）✓。
  /// 返回本帧铺上屏的条数（>0 时需要重绘）。
  /// [budget]：本帧**总**新增预算（与正常 spawn 共用）。默认 `_catchupPerFrame`；
  /// 正常 spawn 已经用掉一部分时会传入更小的值，保证单帧合计不超过
  /// `_spawnPerFrame` 条。
  int _drainCatchup(double pos, {int? budget}) {
    final limit = (budget ?? _catchupPerFrame).clamp(0, _catchupPerFrame);
    final startX = _viewportWidth > 0 ? _viewportWidth : 0.0;
    var done = 0;
    var idx = 0;
    while (idx < _pendingCatchup.length && done < limit) {
      if (_active.length >= _maxActive) break;
      final d = _pendingCatchup[idx++];
      final elapsed = pos - d.time;
      if (d.mode == 4 || d.mode == 5) {
        final remaining = 4.0 - elapsed;
        if (remaining <= 0.5) continue; // 马上消失的没必要补
        final lane = _pickFixedLane(top: d.mode == 4);
        if (lane < 0) continue;
        final p = _painterFor(d);
        _active.add(_ActiveDanmu(d,
            topFixed: d.mode == 4,
            bottomFixed: d.mode == 5,
            width: p.fill.width,
            track: lane,
            remaining: remaining,
            paint: p));
        done++;
      } else {
        final p = _painterFor(d);
        final width = p.fill.width;
        final x = startX - _speed * elapsed;
        if (x + width < -16) continue; // 已飘出屏
        final track = _pickCatchupTrack(x, width);
        if (track < 0) continue; // 放哪都重叠 → 宁可少一条
        _active.add(_ActiveDanmu(d,
            track: track, width: width, x: x, positioned: true, paint: p));
        done++;
      }
    }
    if (idx >= _pendingCatchup.length) {
      _pendingCatchup.clear();
    } else {
      _pendingCatchup.removeRange(0, idx);
    }
    return done;
  }

  /// 补播专用的轨道选择：候选弹幕在虚拟位置 [x, x+width]，
  /// 找一条**当前不与其重叠**（含安全间隙）的滚动轨道。
  /// 同速滚动 ⇒ 相对位置不变 ⇒ 现在不重叠就永远不重叠 ✓。
  int _pickCatchupTrack(double x, double width) {
    final tracks = _effectiveTrackCount;
    while (_trackRightEdge.length < tracks) {
      _trackRightEdge.add(double.negativeInfinity);
    }
    for (var t = 0; t < tracks; t++) {
      var free = true;
      for (final a in _active) {
        if (a.item.mode != 1 || a.track != t) continue;
        if (x < a.x + a.width + _trackGap && x + width + _trackGap > a.x) {
          free = false;
          break;
        }
      }
      if (free) return t;
    }
    return -1;
  }

  void _spawn(DanmuItem item) {
    final p = _painterFor(item);
    final width = p.fill.width;
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
          topFixed: true, width: width, track: lane, paint: p));
    } else if (item.mode == 5) {
      final lane = _pickFixedLane(top: false);
      if (lane < 0) return;
      _active.add(_ActiveDanmu(item,
          bottomFixed: true, width: width, track: lane, paint: p));
    } else {
      final track = _pickTrack();
      // 轨道全忙且都会重叠 → 丢弃本条（宁可少一条，不让弹幕叠在一起）
      if (track < 0) return;
      _active.add(_ActiveDanmu(item,
          track: track,
          width: width,
          x: startX,
          positioned: true,
          paint: p));
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

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  /// 轨道纵向步长：字号 × 行间距系数（下限 22，避免小字号挤在一起）
  double get _trackStep {
    final v = widget.fontSize * widget.lineSpacing;
    return v < 22 ? 22 : v;
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
              // ✅ 只重绘、不重建 widget 树（每帧都会动）
              willChange: true,
              painter: _DanmuPainter(
                repaint: _repaint,
                active: _active,
                topPx: topPx,
                bottomPx: bottomPx,
                trackStep: _trackStep,
                fontSize: widget.fontSize,
                fontWeight: widget.fontWeight,
                strokeWidth: widget.strokeWidth,
                forceColor: widget.forceColor,
                opacity: widget.opacity,
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
  final List<_ActiveDanmu> active;
  final double topPx;
  final double bottomPx;
  final double trackStep;
  final double fontSize;
  final FontWeight fontWeight;
  final double strokeWidth;
  final Color? forceColor;
  final double opacity;

  _DanmuPainter({
    required Listenable repaint,
    required this.active,
    required this.topPx,
    required this.bottomPx,
    required this.trackStep,
    required this.fontSize,
    required this.fontWeight,
    required this.strokeWidth,
    required this.forceColor,
    required this.opacity,
  }) : super(repaint: repaint);

  /// 兜底：条目没有预解析的绘制对时（样式失效后的头一帧）就地重建并写回。
  /// 🔴 不走字符串 key 查缓存 —— 那是每帧 × 每条的热路径，直接省掉。
  _DanmuPaint _ensurePaint(_ActiveDanmu a) {
    var p = a.paint;
    if (p == null) {
      final color =
          (forceColor ?? a.item.color).withValues(alpha: opacity);
      p = _DanmuPaint.build(
        item: a.item,
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        strokeWidth: strokeWidth,
      );
      a.paint = p;
    }
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in active) {
      final p = _ensurePaint(a);

      final double dy;
      final double dx;
      if (a.bottomFixed) {
        // 底部固定：从 bottomPx 往上排
        dy = size.height - bottomPx - trackStep * (a.track + 1);
        dx = (size.width - p.fill.width) / 2;
      } else if (a.topFixed) {
        // 顶部固定
        dy = topPx + a.track * trackStep;
        dx = (size.width - p.fill.width) / 2;
      } else {
        // 滚动
        dy = topPx + a.track * trackStep;
        dx = a.x;
      }
      final offset = Offset(dx, dy);
      // 先描边后填充（描边在中线外扩，会被填充盖住内半圈）
      p.stroke?.paint(canvas, offset);
      p.fill.paint(canvas, offset);
    }
  }

  @override
  bool shouldRepaint(covariant _DanmuPainter oldDelegate) {
    // 任何参数变化都重绘（位置/列表都在变，每帧都要重画）
    return true;
  }
}
