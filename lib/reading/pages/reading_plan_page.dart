import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../services/browse_history_service.dart';
import '../services/reading_checkin_service.dart';
import '../services/reading_plan_service.dart';
import '../theme/jelly_theme.dart';

/// 阅读计划页 ✓（参考截图 **IMG_8634 / IMG_8635** ✓）。
///
/// ⚠️ 为什么要有这一页 ✓：此前「我的 → 阅读计划」入口（`me_page.dart:171-181`）
/// **指向的是「我的笔记」同一个页面** ✗✗（`NotesAndJourneyPage` ✓ 与 :155 重复 ✓）
/// —— 也就是说"阅读计划"这个功能**根本没有页面** ✗。本页把它补上 ✓✓：
///   · 空态 ✓：还没有阅读计划 + 「创建阅读计划」（截图原文 ✓）
///   · 列表 ✓：每条计划一张卡（标题 ✓ 剩余天数 ✓ 进度条 ✓ 删除 ✓）
///   · 创建弹层 ✓（IMG_8635 ✓）：读完一本 / 每日阅读 ✓ + 选择最近阅读 ✓ + 完成日期 ✓ + 每日目标 ✓
///
/// 进度从哪来 ✓：
///   · 「每日阅读」→ `ReadingPlanService.dailyProgress` ✓（= 今日分钟 ÷ 每日目标 ✓）
///     今日分钟由**两个阅读器**在离开/保存时写入 `ReadingTimeService` ✓（本轮刚接好 ✓✓）
class ReadingPlanPage extends StatefulWidget {
  const ReadingPlanPage({super.key});

  @override
  State<ReadingPlanPage> createState() => _ReadingPlanPageState();
}

class _ReadingPlanPageState extends State<ReadingPlanPage> {
  bool _loading = true;
  /// 最近在读书名（给空态那句"最近常读《X》…"用 ✓；没有就回落到通用文案 ✓）
  String _recentTitle = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ReadingPlanService.instance.load();
    await ReadingCheckinService.instance.load();
    // 最近阅读：图书 + 漫画各取第一条（数据源与「阅读历程」同一套，不新增存储）
    String recent = '';
    try {
      final books = BrowseHistoryService().books;
      final comics = BrowseHistoryService().comics;
      if (books.isNotEmpty) {
        recent = books.first.title;
      } else if (comics.isNotEmpty) {
        recent = comics.first.title;
      }
    } catch (e) {
      debugPrint('[ReadingPlan] 读取最近阅读失败（空态用通用文案）: $e');
    }
    if (!mounted) return;
    setState(() {
      _recentTitle = recent;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? JellyTheme.backgroundDark
          : JellyTheme.backgroundLight,
      appBar: AppBar(
        title: const Text('阅读计划'),
        actions: [
          IconButton(
            tooltip: '新建计划',
            icon: const Icon(Icons.add_rounded),
            onPressed: () => _showCreateSheet(isDark),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: Listenable.merge([
                ReadingPlanService.instance,
                ReadingCheckinService.instance,
              ]),
              builder: (context, _) {
                final plans = ReadingPlanService.instance.plans;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    // ── 每日阅读打卡（从旧「笔记与历程」页搬来这里）──
                    _buildCheckinCard(isDark),
                    const SizedBox(height: 16),
                    if (plans.isEmpty)
                      _buildEmpty(isDark)
                    else
                      for (final p in plans) ...[
                        _PlanCard(
                          plan: p,
                          isDark: isDark,
                          onDelete: () =>
                              ReadingPlanService.instance.remove(p.id),
                        ),
                        const SizedBox(height: 12),
                      ],
                  ],
                );
              },
            ),
    );
  }

  /// 今日阅读 / 打卡 / 连续天数 / 每日目标。
  Widget _buildCheckinCard(bool isDark) {
    final svc = ReadingCheckinService.instance;
    final card = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final sub = JellyTheme.textSecondary;
    return Container(
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
                child: Icon(Icons.local_fire_department_rounded,
                    color: JellyTheme.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '连续打卡 ${svc.streak} 天',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: labelColor),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '累计 ${svc.totalCheckinDays} 天',
                      style: TextStyle(fontSize: 12, color: sub),
                    ),
                    const SizedBox(height: 2),
                    FutureBuilder<int>(
                      future: svc.todayMinutes(),
                      builder: (context, snap) {
                        final mins = snap.data ?? 0;
                        final goal = svc.goalMinutes;
                        return Text(
                          '今日已读 $mins 分钟'
                          '${goal > 0 ? ' / 目标 $goal 分钟' : ''}',
                          style: TextStyle(fontSize: 12, color: sub),
                        );
                      },
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
                onPressed: svc.checkedToday
                    ? null
                    : () async {
                        final added = await svc.checkIn();
                        if (!context.mounted || !added) return;
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(SnackBar(
                            content:
                                Text('今日打卡成功，已连续 ${svc.streak} 天'),
                            duration: const Duration(seconds: 2),
                            behavior: SnackBarBehavior.floating,
                          ));
                      },
                child: Text(svc.checkedToday ? '今日已打卡' : '今日打卡'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 今日目标进度条
          FutureBuilder<int>(
            future: svc.todayMinutes(),
            builder: (context, snap) {
              final mins = snap.data ?? 0;
              final goal = svc.goalMinutes <= 0 ? 30 : svc.goalMinutes;
              final v = (mins / goal).clamp(0.0, 1.0);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: v,
                      minHeight: 8,
                      color: JellyTheme.primary,
                      backgroundColor:
                          JellyTheme.primary.withValues(alpha: 0.12),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    v >= 1
                        ? '今日目标已完成 🎉'
                        : '今天还差 ${(goal - mins).clamp(0, goal)} 分钟',
                    style: TextStyle(fontSize: 12, color: sub),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Text('每日目标时长', style: TextStyle(fontSize: 13, color: sub)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [15, 30, 45, 60].map((m) {
              final selected = svc.goalMinutes == m;
              return GestureDetector(
                onTap: () => svc.setGoal(m),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                      color: selected ? Colors.white : sub,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  /// 空态（作为 ListView 的一个子项，不再用 Center 撑满全屏）。
  Widget _buildEmpty(bool isDark) {
    final sub = _recentTitle.isEmpty
        ? '从「阅读历程」里选一本常读的书，为它定一个小目标。'
        : '最近常读《$_recentTitle》，可以为它创建一个小目标。';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.event_available_rounded,
            size: 56,
            color: isDark ? Colors.white24 : Colors.black26,
          ),
          const SizedBox(height: 16),
          Text(
            '还没有阅读计划',
            style: TextStyle(
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              color: JellyTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: JellyTheme.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () => _showCreateSheet(isDark),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('创建阅读计划'),
          ),
        ],
      ),
    );
  }

  /// 创建弹层 ✓（IMG_8635 ✓）
  Future<void> _showCreateSheet(bool isDark) async {
    var kind = ReadingPlanKind.finishBook;
    var days = 14;
    var minutes = 30;
    var pickedTitle = _recentTitle;
    var pickedId = '';
    // 漫画进度按 pathWord 存（与 id 不是同一个值）；图书走 itemId。
    var pickedPathWord = '';
    final titleCtl = TextEditingController(text: pickedTitle);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? JellyTheme.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget stepper(String label, String value, VoidCallback minus,
                  VoidCallback plus) =>
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label,
                          style: const TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_rounded),
                      onPressed: minus,
                    ),
                    Text(value,
                        style: const TextStyle(
                            fontSize: AppTheme.fontBody,
                            fontWeight: FontWeight.w600)),
                    IconButton(
                      icon: const Icon(Icons.add_rounded),
                      onPressed: plus,
                    ),
                  ],
                ),
              );

          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('创建阅读计划',
                      style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  // 分段：读完一本 / 每日阅读 ✓
                  SegmentedButton<ReadingPlanKind>(
                    segments: const [
                      ButtonSegment(
                          value: ReadingPlanKind.finishBook,
                          label: Text('读完一本')),
                      ButtonSegment(
                          value: ReadingPlanKind.dailyReading,
                          label: Text('每日阅读')),
                    ],
                    selected: {kind},
                    onSelectionChanged: (s) =>
                        setSheet(() => kind = s.first),
                  ),
                  const SizedBox(height: 16),
                  const Text('选择最近阅读',
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: titleCtl,
                    decoration: const InputDecoration(
                      hintText: '书名 / 漫画名',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => pickedTitle = v,
                  ),
                  const SizedBox(height: 8),
                  // 最近阅读快选（数据源与「阅读历程」一致）
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      ...BrowseHistoryService().books.take(3).map(
                            (b) => ActionChip(
                              label: Text(b.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              onPressed: () => setSheet(() {
                                pickedTitle = b.title;
                                pickedId = b.id;
                                pickedPathWord = '';
                                titleCtl.text = b.title;
                              }),
                            ),
                          ),
                      ...BrowseHistoryService().comics.take(3).map(
                            (c) => ActionChip(
                              label: Text(c.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              onPressed: () => setSheet(() {
                                pickedTitle = c.title;
                                pickedId = c.id;
                                pickedPathWord = c.pathWord.isNotEmpty
                                    ? c.pathWord
                                    : c.id;
                                titleCtl.text = c.title;
                              }),
                            ),
                          ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  stepper(
                    '完成日期',
                    '$days 天后',
                    () => setSheet(() => days = days > 1 ? days - 1 : 1),
                    () => setSheet(() => days = days < 365 ? days + 1 : 365),
                  ),
                  if (kind == ReadingPlanKind.dailyReading)
                    stepper(
                      '每日目标',
                      '$minutes 分钟',
                      () =>
                          setSheet(() => minutes = minutes > 5 ? minutes - 5 : 5),
                      () => setSheet(
                          () => minutes = minutes < 240 ? minutes + 5 : 240),
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: JellyTheme.primary,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () async {
                        final title = titleCtl.text.trim();
                        if (title.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('请先选择或填写要读的书')),
                          );
                          return;
                        }
                        final now = DateTime.now();
                        await ReadingPlanService.instance.add(
                          kind: kind,
                          title: title,
                          itemId: pickedId,
                          pathWord: pickedPathWord,
                          deadline:
                              DateTime(now.year, now.month, now.day + days),
                          dailyMinutes: minutes,
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('创建计划'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 一张计划卡 ✓（标题 + 剩余天数 + 进度 + 删除 ✓）
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.isDark,
    required this.onDelete,
  });

  final ReadingPlan plan;
  final bool isDark;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final sub = isDark ? JellyTheme.textSecondary : JellyTheme.textSecondary;
    final left = plan.daysLeft();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                plan.isDaily
                    ? Icons.today_rounded
                    : Icons.menu_book_rounded,
                size: 18,
                color: JellyTheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  plan.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: label),
                ),
              ),
              IconButton(
                tooltip: '删除',
                icon: Icon(Icons.delete_outline_rounded, size: 20, color: sub),
                onPressed: onDelete,
              ),
            ],
          ),
          Text(
            plan.isDaily
                ? '每日阅读 ${plan.dailyMinutes} 分钟 · 剩 $left 天'
                : '读完一本 · 剩 $left 天',
            style: TextStyle(fontSize: AppTheme.fontFootnote, color: sub),
          ),
          const SizedBox(height: 10),
          // 真实进度：每日阅读 = 今日分钟/目标；读完一本 = 阅读器里的真实进度
          // （漫画按 pathWord、图书按 bookId，见 ReadingPlanService.progressOf）
          FutureBuilder<({double percent, String label})>(
            future: ReadingPlanService.instance.progressOf(plan),
            builder: (context, snap) {
              final data = snap.data;
              final v = (data?.percent ?? 0).clamp(0.0, 1.0);
              final text = data?.label ?? '统计中…';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: v,
                      minHeight: 6,
                      color: v >= 1 ? Colors.green : JellyTheme.primary,
                      backgroundColor:
                          isDark ? Colors.white12 : Colors.black12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$text${data == null ? '' : ' · ${(v * 100).round()}%'}',
                    style:
                        TextStyle(fontSize: AppTheme.fontFootnote, color: sub),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
