import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/jelly_theme.dart';
import 'browse_history_page.dart';

/// ── 笔记与历程计划（参考 cmbok「我的」页引导 1/5）───────────────
/// 三块：
///   · 阅读足迹：漫画 & 图书浏览历史（复用 BrowseHistoryPage）
///   · 每日阅读打卡：设置每日目标分钟数，当天打卡，统计连续天数
///   · 划线笔记：阅读器划线功能后续接入时在此集中管理（当前占位说明）
class NotesAndJourneyPage extends StatefulWidget {
  const NotesAndJourneyPage({super.key});

  @override
  State<NotesAndJourneyPage> createState() => _NotesAndJourneyPageState();
}

class _NotesAndJourneyPageState extends State<NotesAndJourneyPage> {
  static const _goalKey = 'reading_daily_goal_minutes';
  static const _streakKey = 'reading_checkin_streak';
  static const _lastCheckinKey = 'reading_checkin_last_date';
  static const _checkinDaysKey = 'reading_checkin_total_days';

  SharedPreferences? _sp;
  int _goalMinutes = 30;
  int _streak = 0;
  bool _checkedToday = false;
  int _totalCheckinDays = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    _sp = sp;
    final today = _todayKey();
    final last = sp.getString(_lastCheckinKey);
    _goalMinutes = sp.getInt(_goalKey) ?? 30;
    _streak = sp.getInt(_streakKey) ?? 0;
    _checkedToday = sp.getBool('reading_checkin_$today') ?? false;
    _totalCheckinDays = sp.getInt(_checkinDaysKey) ?? 0;
    if (!_checkedToday && last != null && last != _yesterdayKey()) {
      // 昨天没打卡 → 连续天数中断
      _streak = 0;
      await sp.setInt(_streakKey, 0);
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  String _todayKey() {
    final n = DateTime.now();
    return '${n.year}${n.month.toString().padLeft(2, '0')}${n.day.toString().padLeft(2, '0')}';
  }

  String _yesterdayKey() {
    final n = DateTime.now().subtract(const Duration(days: 1));
    return '${n.year}${n.month.toString().padLeft(2, '0')}${n.day.toString().padLeft(2, '0')}';
  }

  Future<void> _checkIn() async {
    if (_checkedToday) return;
    final sp = _sp!;
    final today = _todayKey();
    final yesterday = _yesterdayKey();
    final last = sp.getString(_lastCheckinKey);
    final newStreak = (last == yesterday) ? _streak + 1 : 1;
    await sp.setBool('reading_checkin_$today', true);
    await sp.setString(_lastCheckinKey, today);
    await sp.setInt(_streakKey, newStreak);
    await sp.setInt(_checkinDaysKey, _totalCheckinDays + 1);
    if (!mounted) return;
    setState(() {
      _checkedToday = true;
      _streak = newStreak;
      _totalCheckinDays += 1;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('今日打卡成功，已连续 $newStreak 天'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _setGoal(int minutes) async {
    await _sp!.setInt(_goalKey, minutes);
    if (!mounted) return;
    setState(() => _goalMinutes = minutes);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final card = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final subColor = JellyTheme.textSecondary;

    return Scaffold(
      appBar: AppBar(title: const Text('笔记与历程计划')),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: JellyTheme.primary),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                // ── 每日阅读打卡 ─────────────────────────────
                _sectionTitle('每日阅读打卡', isDark),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: JellyTheme.primary.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.local_fire_department_rounded,
                              color: JellyTheme.primary,
                              size: 24,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '连续打卡 $_streak 天',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: labelColor,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '累计打卡 $_totalCheckinDays 天',
                                  style: TextStyle(
                                      fontSize: 12, color: subColor),
                                ),
                              ],
                            ),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: JellyTheme.primary,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor:
                                  JellyTheme.primary.withValues(alpha: 0.3),
                            ),
                            onPressed: _checkedToday ? null : _checkIn,
                            child: Text(_checkedToday ? '今日已打卡' : '今日打卡'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text('每日目标时长', style: TextStyle(fontSize: 13, color: subColor)),
                      const SizedBox(height: 8),
                      Row(
                        children: [15, 30, 45, 60].map((m) {
                          final selected = _goalMinutes == m;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap: () => _setGoal(m),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? JellyTheme.primary
                                      : (isDark
                                          ? JellyTheme.backgroundDark
                                          : JellyTheme.backgroundLight),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  '$m 分钟',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: selected
                                        ? Colors.white
                                        : subColor,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // ── 阅读足迹 ─────────────────────────────────
                _sectionTitle('阅读足迹', isDark),
                _entryCard(
                  isDark: isDark,
                  icon: Icons.history_rounded,
                  title: '浏览历史',
                  subtitle: '漫画 & 图书阅读时间线足迹',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const BrowseHistoryPage(showTabs: false),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── 划线笔记 ─────────────────────────────────
                _sectionTitle('划线笔记', isDark),
                _entryCard(
                  isDark: isDark,
                  icon: Icons.edit_note_rounded,
                  title: '全书库划线笔记',
                  subtitle: '集中管理在阅读器里划线的内容（划线功能接入后可用）',
                  onTap: () {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text('阅读器划线功能尚未接入，敬请期待'),
                          duration: Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                  },
                ),
                const SizedBox(height: 24),
                Center(
                  child: Text(
                    '坚持每天阅读一点点',
                    style: TextStyle(fontSize: 12, color: subColor),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
        ),
      ),
    );
  }

  Widget _entryCard({
    required bool isDark,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final card = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: JellyTheme.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: JellyTheme.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: labelColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: JellyTheme.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
