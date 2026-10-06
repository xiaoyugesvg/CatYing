import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读时长统计（**按天累计** ✓）—— 为「阅读计划」与「阅读热力图」提供**数据地基** ✓。
///
/// ── 为什么需要它（今天核实的缺口 ✗）─────────────────────────────
/// 现有的「每日阅读打卡」只记**今天读没读**（`reading_checkin_<日期>` = bool ✓），
/// **不记读了几分钟** ✗ → 所以：
///   · 「阅读计划」里的「每日阅读 30 分钟」**算不出进度** ✗（恒 0% ✓）
///   · 「阅读热力图」（IMG_8633 ✓）**没有强度数据** ✗（只能显示"读过/没读过" ✓）
/// 本服务补的就是这一层 ✓：把"每个自然日读了多少**秒**"落盘 ✓。
///
/// ── 存储约定 ──────────────────────────────────────────────────
///   · `reading_seconds_<yyyy-MM-dd>` → int（当天累计秒数 ✓）
///   · 同时维护 `reading_time_last_date`，用于跨天时**自动换天** ✓（不写"昨天"的键 ✗）
///
/// ── 设计取舍 ──────────────────────────────────────────────────
///   · **不引第三方依赖** ✓（只用 `shared_preferences`，与全模块一致 ✓）
///   · **不做自动计时** ✗：调用方（阅读器）负责"进入/离开"两个时点并调用
///     [addSession] ✓ —— 本服务只做"累加 + 按天归集 + 读取"✓，逻辑最简单、最好测 ✓
///   · 只保留最近 [maxDaysKept] 天的键 ✓（避免 prefs 无限膨胀 ✗）
class ReadingTimeService {
  ReadingTimeService._();
  static final ReadingTimeService instance = ReadingTimeService._();

  /// 保留最近多少天的秒数键 ✓（热力图一个月足够 ✓；更久的历史不占空间 ✓）
  static const int maxDaysKept = 60;

  static const String _keyPrefix = 'reading_seconds_';
  static const String _lastDateKey = 'reading_time_last_date';

  SharedPreferences? _sp;

  Future<SharedPreferences> _prefs() async =>
      _sp ??= await SharedPreferences.getInstance();

  static String _dateOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _keyOf(DateTime d) => '$_keyPrefix${_dateOf(d)}';

  /// 记录一段阅读时长 ✓（调用方在**离开阅读界面**时调用 ✓）。
  ///
  /// [session] 为本次会话时长 ✓；[now] 仅便于测试注入 ✓。
  /// · 小于 1 秒的会话直接忽略 ✗（快速进出阅读器不该被记成"读过"✓）
  /// · 超过 [maxSession] 的按上限截断 ✓（防止"放着不管一整晚"污染统计 ✗）
  Future<void> addSession(Duration session, {DateTime? now}) async {
    final seconds = session.inSeconds;
    if (seconds < minSessionSeconds) return;
    final capped = seconds > maxSessionSeconds ? maxSessionSeconds : seconds;
    try {
      final sp = await _prefs();
      final today = now ?? DateTime.now();
      final key = _keyOf(today);
      await sp.setInt(key, (sp.getInt(key) ?? 0) + capped);
      await sp.setString(_lastDateKey, _dateOf(today));
      await _evictOldKeys(sp, today);
    } catch (e) {
      _log('记录阅读时长失败: $e');
    }
  }

  /// 某天已读秒数 ✓（默认今天 ✓）；无记录返回 0 ✓。
  Future<int> secondsOf(DateTime day) async {
    final sp = await _prefs();
    return sp.getInt(_keyOf(day)) ?? 0;
  }

  /// 某天已读**分钟**（向下取整 ✓ —— 界面上显示"读了 N 分钟"✓）。
  Future<int> minutesOf(DateTime day) async => (await secondsOf(day)) ~/ 60;

  Future<int> todayMinutes({DateTime? now}) =>
      minutesOf(now ?? DateTime.now());

  /// 最近 [days] 天的"每天秒数"✓（**升序** ✓，缺失的日期补 0 ✓）——
  /// 热力图（IMG_8633）直接用它当强度数组 ✓。
  Future<List<int>> recentDays(int days, {DateTime? now}) async {
    final sp = await _prefs();
    final today = now ?? DateTime.now();
    final out = <int>[];
    for (var i = days - 1; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      out.add(sp.getInt(_keyOf(d)) ?? 0);
    }
    return out;
  }

  /// 清理超出 [maxDaysKept] 的旧键 ✓（只删本服务自己的键 ✗，不碰打卡数据 ✓）
  Future<void> _evictOldKeys(SharedPreferences sp, DateTime today) async {
    final cutoff = today.subtract(const Duration(days: maxDaysKept));
    final cutoffStr = _dateOf(cutoff);
    for (final key in sp.getKeys().toList()) {
      if (!key.startsWith(_keyPrefix)) continue;
      final date = key.substring(_keyPrefix.length);
      if (date.compareTo(cutoffStr) < 0) await sp.remove(key);
    }
  }

  /// 两次会话之间的最短记秒数 ✓（1 秒以下不记 ✗）
  static const int minSessionSeconds = 1;

  /// 单次会话计入的**上限**（2 小时 ✓）—— 防止"忘记退出阅读器"把一天刷爆 ✗
  static const int maxSessionSeconds = 2 * 60 * 60;

  void _log(String msg) {
    if (kDebugMode) debugPrint('[ReadingTime] $msg');
  }
}
