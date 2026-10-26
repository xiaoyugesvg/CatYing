import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/reading/services/book_reading_progress_service.dart';
import 'package:tvbox/reading/services/book_source_health_service.dart';
import 'package:tvbox/reading/services/book_source_service.dart';
import 'package:tvbox/reading/services/reading_checkin_service.dart';
import 'package:tvbox/reading/services/reading_progress_service.dart';
import 'package:tvbox/reading/services/reading_time_service.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';

/// 阅读统计页。
///
/// 数据来源都是现成的：
///   · 累计/7 天时长 → ReadingTimeService（按天秒数）
///   · 连续打卡      → ReadingCheckinService
///   · 读完本数      → 漫画 finished 标志 + 图书翻到最后一页
///   · 书源可用率    → 书源体检服务缓存（没体检过显示"未体检"）
class ReadingStatsPage extends StatefulWidget {
  const ReadingStatsPage({super.key});

  @override
  State<ReadingStatsPage> createState() => _ReadingStatsPageState();
}

class _ReadingStatsPageState extends State<ReadingStatsPage> {
  bool _loading = true;
  int _totalSeconds = 0;
  int _todaySeconds = 0;
  List<int> _last7 = const [];
  int _streak = 0;
  int _totalCheckinDays = 0;
  int _finishedComics = 0;
  int _finishedBooks = 0;
  int _sourceUsable = 0;
  int _sourceTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final time = ReadingTimeService.instance;
    final all = await time.recentDays(ReadingTimeService.maxDaysKept);
    final last7 = await time.recentDays(7);
    final today = await time.secondsOf(DateTime.now());

    final checkin = ReadingCheckinService.instance;
    if (!checkin.isLoaded) await checkin.load();

    var comics = 0;
    final comicSvc = ReadingProgressService();
    for (final p in comicSvc.pathWords) {
      if (comicSvc.getProgress(p)?.finished == true) comics++;
    }

    var books = 0;
    final bookSvc = BookReadingProgressService();
    for (final id in bookSvc.bookIds) {
      final p = bookSvc.getProgress(id);
      if (p != null && p.pageTotal > 0 && p.pageIndex + 1 >= p.pageTotal) {
        books++;
      }
    }

    final cache = BookSourceHealthService.instance.healthCache;
    final usable = cache.values
        .where((h) =>
            h.level == BookSourceHealthLevel.healthy ||
            h.level == BookSourceHealthLevel.partial)
        .length;

    if (!mounted) return;
    setState(() {
      _totalSeconds = all.fold<int>(0, (a, b) => a + b);
      _last7 = last7;
      _todaySeconds = today;
      _streak = checkin.streak;
      _totalCheckinDays = checkin.totalCheckinDays;
      _finishedComics = comics;
      _finishedBooks = books;
      _sourceUsable = usable;
      _sourceTotal = cache.length;
      _loading = false;
    });
  }

  String _fmt(int seconds) {
    final m = seconds ~/ 60;
    if (m < 60) return '$m 分钟';
    final h = m ~/ 60;
    final rest = m % 60;
    return rest == 0 ? '$h 小时' : '$h 小时 $rest 分';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          '阅读统计',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _summaryGrid(isDark),
                const SizedBox(height: 16),
                _weekCard(isDark),
                const SizedBox(height: 16),
                _tipCard(isDark),
              ],
            ),
    );
  }

  Widget _summaryGrid(bool isDark) {
    final cards = [
      _StatCard(
        icon: Icons.schedule_rounded,
        label: '累计阅读',
        value: _fmt(_totalSeconds),
        sub: '今日 ${_fmt(_todaySeconds)}',
        isDark: isDark,
      ),
      _StatCard(
        icon: Icons.local_fire_department_rounded,
        label: '连续打卡',
        value: '$_streak 天',
        sub: '累计 $_totalCheckinDays 天',
        isDark: isDark,
      ),
      _StatCard(
        icon: Icons.task_alt_rounded,
        label: '读完本数',
        value: '${_finishedComics + _finishedBooks} 本',
        sub: '漫画 $_finishedComics · 图书 $_finishedBooks',
        isDark: isDark,
      ),
      _StatCard(
        icon: Icons.verified_outlined,
        label: '书源可用率',
        value: _sourceTotal == 0
            ? '未体检'
            : '${(_sourceUsable * 100 / _sourceTotal).round()}%',
        sub: _sourceTotal == 0 ? '去书源体检跑一次' : '$_sourceUsable / $_sourceTotal 个',
        isDark: isDark,
      ),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.55,
      children: cards,
    );
  }

  Widget _weekCard(bool isDark) {
    final maxSeconds =
        _last7.isEmpty ? 0 : _last7.reduce((a, b) => a > b ? a : b);
    final weekTotal = _last7.fold<int>(0, (a, b) => a + b);
    final today = DateTime.now();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '最近 7 天',
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
              const Spacer(),
              Text(
                '合计 ${_fmt(weekTotal)}',
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: JellyTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 130,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: _bar(
                      isDark: isDark,
                      index: i,
                      seconds: i < _last7.length ? _last7[i] : 0,
                      maxSeconds: maxSeconds,
                      day: today.subtract(Duration(days: 6 - i)),
                      isToday: i == 6,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar({
    required bool isDark,
    required int index,
    required int seconds,
    required int maxSeconds,
    required DateTime day,
    required bool isToday,
  }) {
    final ratio = maxSeconds <= 0 ? 0.0 : seconds / maxSeconds;
    final h = ratio <= 0 ? 4.0 : 8 + ratio * 82;
    final label = const ['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            seconds <= 0 ? '' : '${seconds ~/ 60}',
            style: TextStyle(
              fontSize: 10,
              color: isToday ? JellyTheme.primary : JellyTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            height: h,
            decoration: BoxDecoration(
              color: isToday
                  ? JellyTheme.primary
                  : JellyTheme.primary.withValues(alpha: isDark ? 0.45 : 0.25),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isToday ? '今' : label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
              color: isToday ? JellyTheme.primary : JellyTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tipCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded,
              size: 18, color: JellyTheme.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '阅读时长按「每次离开阅读器」累计，单次最多计 2 小时；'
              '书源可用率来自最近一次书源体检结果（设置 → 书源体检）。',
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                height: 1.5,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    required this.isDark,
  });

  final IconData icon;
  final String label;
  final String value;
  final String sub;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: JellyTheme.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: JellyTheme.textSecondary,
                ),
              ),
            ],
          ),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: JellyTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
