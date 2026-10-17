import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reading_time_service.dart';

/// 每日阅读打卡 / 目标 / 连续天数（从原 `NotesAndJourneyPage` 抽出的服务）。
///
/// 为什么抽出来：用户 2026-10-17 要求「笔记」「阅读历程」「阅读计划」三者
/// **各自独立**。打卡与目标属于阅读计划，不该再挂在笔记页里。
///
/// 键名沿用旧实现（`reading_daily_goal_minutes` 等），老用户数据不丢。
class ReadingCheckinService extends ChangeNotifier {
  ReadingCheckinService._();
  static final ReadingCheckinService instance = ReadingCheckinService._();

  static const _goalKey = 'reading_daily_goal_minutes';
  static const _streakKey = 'reading_checkin_streak';
  static const _lastCheckinKey = 'reading_checkin_last_date';
  static const _checkinDaysKey = 'reading_checkin_total_days';

  SharedPreferences? _sp;
  bool _loaded = false;

  int _goalMinutes = 30;
  int _streak = 0;
  int _totalCheckinDays = 0;
  bool _checkedToday = false;

  int get goalMinutes => _goalMinutes;
  int get streak => _streak;
  int get totalCheckinDays => _totalCheckinDays;
  bool get checkedToday => _checkedToday;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    final sp = _sp ??= await SharedPreferences.getInstance();
    final today = _todayKey();
    final last = sp.getString(_lastCheckinKey);
    _goalMinutes = sp.getInt(_goalKey) ?? 30;
    _streak = sp.getInt(_streakKey) ?? 0;
    _checkedToday = sp.getBool('reading_checkin_$today') ?? false;
    _totalCheckinDays = sp.getInt(_checkinDaysKey) ?? 0;
    // 昨天没打卡 → 连续天数中断（今天还没打的情况下）
    if (!_checkedToday && last != null && last != _yesterdayKey()) {
      _streak = 0;
      await sp.setInt(_streakKey, 0);
    }
    _loaded = true;
    notifyListeners();
  }

  Future<int> todayMinutes() => ReadingTimeService.instance.todayMinutes();

  Future<void> setGoal(int minutes) async {
    final v = minutes.clamp(5, 600);
    final sp = _sp ??= await SharedPreferences.getInstance();
    await sp.setInt(_goalKey, v);
    _goalMinutes = v;
    notifyListeners();
  }

  /// 打卡；返回是否本次新增（已打过返回 false）。
  Future<bool> checkIn() async {
    if (_checkedToday) return false;
    final sp = _sp ??= await SharedPreferences.getInstance();
    final today = _todayKey();
    final last = sp.getString(_lastCheckinKey);
    final newStreak = (last == _yesterdayKey()) ? _streak + 1 : 1;
    await sp.setBool('reading_checkin_$today', true);
    await sp.setString(_lastCheckinKey, today);
    await sp.setInt(_streakKey, newStreak);
    await sp.setInt(_checkinDaysKey, _totalCheckinDays + 1);
    _checkedToday = true;
    _streak = newStreak;
    _totalCheckinDays += 1;
    notifyListeners();
    return true;
  }

  String _todayKey() {
    final n = DateTime.now();
    return '${n.year}${n.month.toString().padLeft(2, '0')}'
        '${n.day.toString().padLeft(2, '0')}';
  }

  String _yesterdayKey() {
    final n = DateTime.now().subtract(const Duration(days: 1));
    return '${n.year}${n.month.toString().padLeft(2, '0')}'
        '${n.day.toString().padLeft(2, '0')}';
  }
}
