import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../services/browse_history_service.dart';
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
    // 最近阅读：图书 + 漫画各取第一条 ✓（数据源与「阅读经历」同一套 ✓，不新增存储 ✓）
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
              listenable: ReadingPlanService.instance,
              builder: (context, _) {
                final plans = ReadingPlanService.instance.plans;
                if (plans.isEmpty) return _buildEmpty(isDark);
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: plans.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _PlanCard(
                    plan: plans[i],
                    isDark: isDark,
                    onDelete: () =>
                        ReadingPlanService.instance.remove(plans[i].id),
                  ),
                );
              },
            ),
    );
  }

  /// 空态 ✓（截图原文：还没有阅读计划 / 最近常读《X》，可以为它创建一个 小目标。/ + 创建阅读计划 ✓）
  Widget _buildEmpty(bool isDark) {
    final sub = _recentTitle.isEmpty
        ? '从「阅读经历」里选一本常读的书，为它定一个小目标。'
        : '最近常读《$_recentTitle》，可以为它创建一个 小目标。';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
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
                color: isDark
                    ? JellyTheme.textSecondary
                    : JellyTheme.textSecondary,
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
                  // 最近阅读快选 ✓（数据源与「阅读经历」一致 ✓）
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
          // 进度：每日阅读 → 今日分钟 ÷ 目标 ✓（数据来自两个阅读器的真实记录 ✓）
          if (plan.isDaily)
            FutureBuilder<double>(
              future: ReadingPlanService.instance.dailyProgress(plan),
              builder: (context, snap) {
                final v = (snap.data ?? 0).clamp(0.0, 1.0);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: v,
                        minHeight: 6,
                        backgroundColor: isDark
                            ? Colors.white12
                            : Colors.black12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '今日 ${(v * 100).round()}%',
                      style:
                          TextStyle(fontSize: AppTheme.fontFootnote, color: sub),
                    ),
                  ],
                );
              },
            )
          else
            Text(
              '进度按阅读进度统计（读完一本即完成）',
              style: TextStyle(fontSize: AppTheme.fontFootnote, color: sub),
            ),
        ],
      ),
    );
  }
}
