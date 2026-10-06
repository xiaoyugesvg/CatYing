import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_reading_progress_service.dart';
import 'reading_progress_service.dart';
import 'reading_time_service.dart';

/// 阅读计划类型 ✓（对齐截图 IMG_8635 的两个分段 ✓）
enum ReadingPlanKind {
  /// 读完一本 ✓（目标：把某本书/漫画读完 ✓，用阅读进度算百分比 ✓）
  finishBook,

  /// 每日阅读 ✓（目标：每天读满 N 分钟 ✓，用 [ReadingTimeService] 的当天秒数算 ✓）
  dailyReading,
}

/// 一条阅读计划 ✓（对齐截图 IMG_8635：选一本书 + 完成日期 + 每日目标 ✓）
@immutable
class ReadingPlan {
  const ReadingPlan({
    required this.id,
    required this.kind,
    required this.title,
    this.itemId = '',
    this.totalChapters = 0,
    this.pathWord = '',
    required this.createdAt,
    required this.deadline,
    this.dailyMinutes = 30,
  });

  /// 唯一 id ✓（`plan_<毫秒>_<序号>` ✓）
  final String id;

  final ReadingPlanKind kind;

  /// 显示名 ✓（书名 / 漫画名 ✓）
  final String title;

  /// 关联的作品 id ✓（"读完一本"用 ✓，与书架/收藏的 id 同一套 ✓）
  final String itemId;

  /// 总话/章数 ✓（>0 时进度可按"章"估算 ✓；=0 则只按阅读进度 ✓）
  final int totalChapters;

  /// ✅ **漫画进度的查询键** ✓（`ReadingProgressService.getProgress(pathWord)` 要的就是它 ✓；
  ///   图书走 [itemId] ✓）—— 为什么必须单独存 ✗：`Comic` 的 `id` 与 `pathWord` **不是同一个值** ✓
  ///   （`models/comic.dart:3` 是 `id` ✓，`:13` 才是 `pathWord` ✓），而漫画进度服务按 `pathWord` 存 ✓
  ///   （`reading_progress_service.dart:195` ✓）。老数据无此字段 ✓ → `tryParse` 回退空串 ✓ →
  ///   该计划显示「尚未开始」✓（不报错 ✓ 不假装 ✓）。
  final String pathWord;

  final DateTime createdAt;

  /// 完成日期 ✓（截图里的「14 天后」= createdAt + N 天 ✓）
  final DateTime deadline;

  /// 每日目标分钟数 ✓（截图里的「30 分钟」✓；仅 [ReadingPlanKind.dailyReading] 用 ✓）
  final int dailyMinutes;

  /// 剩余天数 ✓（<0 视作 0 ✓）
  int daysLeft([DateTime? now]) {
    final n = now ?? DateTime.now();
    final d = deadline.difference(DateTime(n.year, n.month, n.day)).inDays;
    return d < 0 ? 0 : d;
  }

  bool get isDaily => kind == ReadingPlanKind.dailyReading;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'itemId': itemId,
        'totalChapters': totalChapters,
        'pathWord': pathWord,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'deadline': deadline.millisecondsSinceEpoch,
        'dailyMinutes': dailyMinutes,
      };

  /// 宽容解析 ✓：字段缺失/类型不对一律回退默认 ✓（与 `site_config` 的容错风格一致 ✓）
  static ReadingPlan? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString();
    if (id.isEmpty) return null;
    final kindName = (raw['kind'] ?? '').toString();
    final kind = ReadingPlanKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => ReadingPlanKind.finishBook,
    );
    int ms(Object? v, int fallback) =>
        v is num ? v.toInt() : (int.tryParse('$v') ?? fallback);
    final now = DateTime.now().millisecondsSinceEpoch;
    return ReadingPlan(
      id: id,
      kind: kind,
      title: (raw['title'] ?? '').toString(),
      itemId: (raw['itemId'] ?? '').toString(),
      totalChapters: ms(raw['totalChapters'], 0),
      // ✅ 漫画进度键 ✓（旧数据无此字段 → 空串 ✓ 表示"尚未开始"✓）
      pathWord: (raw['pathWord'] ?? '').toString(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(ms(raw['createdAt'], now)),
      deadline: DateTime.fromMillisecondsSinceEpoch(ms(raw['deadline'], now)),
      dailyMinutes: ms(raw['dailyMinutes'], 30),
    );
  }
}

/// 阅读计划存储 ✓（**新增功能** ✓ —— 截图 IMG_8634/8635 的那个页面此前在本仓库
/// **完全不存在** ✗：`阅读计划` 只作为「我的」页的一个入口标签存在 ✓）。
///
/// 设计取舍 ✓：
///   · 落盘只用 `shared_preferences` + JSON ✓（与 `custom_themes` / `reading_seconds_*`
///     的既有做法一致 ✓，**不引新依赖** ✓ —— 本机 TrollStore 侧载不能新增原生插件 ✗）
///   · 进度**不在本服务里算** ✓：`finishBook` 要读书架/收藏的阅读进度 ✓、
///     `dailyReading` 要读 [ReadingTimeService] ✓ —— 都由**页面**注入计算 ✓，
///     避免本服务反向依赖一堆业务单例 ✗（也避免循环依赖 ✓）
///   · 变更后 `notifyListeners()` ✓，页面用 `ListenableBuilder` 订阅 ✓（与
///     `TrimPresetService` / `BookFavoritesService` 同款 ✓）
class ReadingPlanService extends ChangeNotifier {
  ReadingPlanService._();
  static final ReadingPlanService instance = ReadingPlanService._();

  static const String _key = 'reading_plans';
  static const int _maxPlans = 20;

  final List<ReadingPlan> _plans = [];
  List<ReadingPlan> get plans => List.unmodifiable(_plans);

  bool _loaded = false;
  bool get isLoaded => _loaded;

  SharedPreferences? _sp;

  Future<SharedPreferences> _prefs() async =>
      _sp ??= await SharedPreferences.getInstance();

  /// 首次进入计划页时调用 ✓（幂等 ✓，重复调用不重复解析 ✓）
  Future<void> load() async {
    if (_loaded) return;
    try {
      final sp = await _prefs();
      final raw = sp.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final arr = jsonDecode(raw);
        if (arr is List) {
          for (final e in arr) {
            final p = ReadingPlan.tryParse(e);
            if (p != null) _plans.add(p);
          }
        }
      }
      _loaded = true;
      notifyListeners();
    } catch (e) {
      _loaded = true; // 解析失败也标记已加载 ✓（否则页面会一直转圈 ✗）
      _log('读取阅读计划失败（按空列表继续）: $e');
      notifyListeners();
    }
  }

  /// 新建计划 ✓（返回新 id ✓；超过 [_maxPlans] 时挤掉最旧的一条 ✓）
  Future<String> add({
    required ReadingPlanKind kind,
    required String title,
    String itemId = '',
    int totalChapters = 0,
    required DateTime deadline,
    int dailyMinutes = 30,
  }) async {
    final now = DateTime.now();
    final id = 'plan_${now.millisecondsSinceEpoch}_${_plans.length}';
    _plans.add(ReadingPlan(
      id: id,
      kind: kind,
      title: title,
      itemId: itemId,
      totalChapters: totalChapters,
      createdAt: now,
      deadline: deadline,
      dailyMinutes: dailyMinutes,
    ));
    while (_plans.length > _maxPlans) {
      _plans.removeAt(0);
    }
    await _persist();
    notifyListeners();
    return id;
  }

  /// 删除一条 ✓
  Future<void> remove(String id) async {
    final before = _plans.length;
    _plans.removeWhere((p) => p.id == id);
    if (_plans.length == before) return;
    await _persist();
    notifyListeners();
  }

  /// 清空全部 ✓（页面里的"清空"入口用 ✓）
  Future<void> clear() async {
    if (_plans.isEmpty) return;
    _plans.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final sp = await _prefs();
      await sp.setString(
        _key,
        jsonEncode(_plans.map((p) => p.toJson()).toList()),
      );
    } catch (e) {
      _log('保存阅读计划失败: $e');
    }
  }

  /// ✅ **「读完一本」的真实进度** ✓（截图 IMG_8634 卡片上的进度条 ✓）。
  ///
  /// 数据源**不是新造的** ✗，而是两条**既有**管线 ✓（符号都逐一核对过 ✓）：
  ///   · **漫画** → `ReadingProgressService().getProgress(pathWord)` ✓（按 `pathWord` 存 ✓）
  ///       `finished == true` → **100%** ✓；否则按 `seenChapterIds.length / totalChapters` ✓
  ///   · **图书** → `BookReadingProgressService().getProgress(bookId)` ✓（按 `bookId` 存 ✓）
  ///       `pageIndex / pageTotal`（`pageTotal == 0` = 还没分页过 ✓ → 视为尚未开始 ✓）
  ///   · 两条都取不到 → **「尚未开始」** ✓（**绝不编数字** ✗✓，与今天一律的"不假装"原则一致 ✓）
  ///
  /// ⚠️ 两个 `getProgress` 都是**同步**方法 ✓（返回可空对象 ✓，不是 Future ✓）。
  Future<({double percent, String label})> progressOf(ReadingPlan plan) async {
    if (plan.kind == ReadingPlanKind.dailyReading) {
      final v = await dailyProgress(plan);
      final mins = await ReadingTimeService.instance.todayMinutes();
      return (percent: v, label: '今日 $mins/${plan.dailyMinutes} 分钟');
    }
    // ── 漫画：进度按 pathWord 存 ✓ ──
    if (plan.pathWord.isNotEmpty) {
      try {
        final r = ReadingProgressService().getProgress(plan.pathWord);
        if (r != null) {
          if (r.finished) return (percent: 1.0, label: '已读完 ✓');
          final total = plan.totalChapters;
          final seen = r.seenChapterIds.length;
          if (total > 0) {
            final v = seen / total;
            return (
              percent: v.clamp(0.0, 1.0),
              label: '已看 $seen/$total 话',
            );
          }
          if (seen > 0) return (percent: 0.0, label: '已看 $seen 话');
        }
      } catch (e) {
        _log('读取漫画进度失败（按尚未开始处理）: $e');
      }
    }
    // ── 图书：进度按 bookId 存 ✓ ──
    if (plan.itemId.isNotEmpty) {
      try {
        final b = BookReadingProgressService().getProgress(plan.itemId);
        if (b != null && b.pageTotal > 0) {
          final v = b.pageIndex / b.pageTotal;
          return (
            percent: v.clamp(0.0, 1.0),
            label: '已读 ${(v * 100).round()}%',
          );
        }
      } catch (e) {
        _log('读取图书进度失败（按尚未开始处理）: $e');
      }
    }
    return (percent: 0.0, label: '尚未开始');
  }


  /// 今天的阅读分钟数 ÷ 每日目标 ✓；目标非法时返回 0 ✓。
  Future<double> dailyProgress(ReadingPlan plan) async {
    final goal = plan.dailyMinutes;
    if (goal <= 0) return 0;
    final mins = await ReadingTimeService.instance.todayMinutes();
    final r = mins / goal;
    return r < 0 ? 0 : (r > 1 ? 1 : r);
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[ReadingPlan] $msg');
  }
}
