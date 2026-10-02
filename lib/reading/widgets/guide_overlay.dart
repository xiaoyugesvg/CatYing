import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/jelly_theme.dart';

/// ── 新手引导系统（参考 cmbok 引导截图）──────────────────────────
/// 覆盖阅读模块 4 个页面共 16 条引导：
///   图书页 2 条 / 漫画页 4 条 / 书架页 5 条 / 我的页 5 条。
///
/// 交互：按步弹白色卡片弹窗（标题 + 说明 + 进度 x/y + 「跳过引导」
/// 「下一步 / 我知道了」）。点「跳过引导」整组标记完成；
/// 点「下一步」标记当前步完成并弹下一步；最后一步「我知道了」
/// 标记整组完成并关闭。
///
/// 触发策略：所在页面「首次被激活」（isActive 由 false→true）时触发，
/// 避免 IndexedStack 首屏同时弹多组；全局队列保证一次只展示一组。
class GuideStore {
  GuideStore._();

  static final GuideStore instance = GuideStore._();

  static const _prefix = 'reading_guide_done_';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// 某步是否已完成
  Future<bool> isStepDone(String group, int step) async {
    return (await _sp).getBool('$_prefix${group}_$step') ?? false;
  }

  /// 整组是否全部完成
  Future<bool> isGroupDone(String group, int steps) async {
    final sp = await _sp;
    for (var i = 1; i <= steps; i++) {
      if (!(sp.getBool('$_prefix${group}_$i') ?? false)) return false;
    }
    return true;
  }

  /// 标记某步完成
  Future<void> markStepDone(String group, int step) async {
    await (await _sp).setBool('$_prefix${group}_$step', true);
  }

  /// 整组完成（跳过 / 看完最后一步时调用）
  Future<void> markGroupDone(String group, int steps) async {
    final sp = await _sp;
    for (var i = 1; i <= steps; i++) {
      await sp.setBool('$_prefix${group}_$i', true);
    }
  }

  /// 重置整组（供「重新查看引导」等入口使用）
  Future<void> resetGroup(String group, int steps) async {
    final sp = await _sp;
    for (var i = 1; i <= steps; i++) {
      await sp.remove('$_prefix${group}_$i');
    }
  }
}

/// 一条引导步骤
class GuideStep {
  final String title;
  final String message;

  const GuideStep(this.title, this.message);
}

/// 一个引导组（对应一个页面的若干步骤）
class GuideGroup {
  final String id;
  final List<GuideStep> steps;

  const GuideGroup({required this.id, required this.steps});
}

/// 引导内容定义（与参考截图逐条对应）
class GuideGroups {
  /// 图书页 2 条
  static const book = GuideGroup(id: 'book', steps: [
    GuideStep(
      '下拉切换书源',
      '抓标题下方拉绳下拉，可在图书与书源两层间卷帘切换；'
      '切到书源层后，长按书源标签可唤起登录管理。',
    ),
    GuideStep(
      '长按快速续读',
      '长按底部「图书」图标，可直接打开阅读器快速续读最近一次阅读的图书。',
    ),
  ]);

  /// 漫画页 4 条
  static const manga = GuideGroup(id: 'manga', steps: [
    GuideStep(
      '分类筛选',
      '点指环保菜单里的「分类筛选」，可按题材、地区、进度等多维度筛选漫画。',
    ),
    GuideStep(
      '快捷入口叠卡',
      '顶部横向卡片收纳了漫画源管理、浏览历史、我的收藏与下载，'
      '点开即可直达；下滑卡片可展开自定义面板。',
    ),
    GuideStep(
      '聚搜与复搜',
      '点击「聚搜」标签可跨所有漫画源一键聚合搜索；'
      '在结果列表顶部下拉还可切换为多标签组合的「复搜」模式。',
    ),
    GuideStep(
      '长按快速续读',
      '长按底部「漫画」图标，可直接打开阅读器快速续读最近一次阅读的漫画。',
    ),
  ]);

  /// 书架页 5 条
  static const bookshelf = GuideGroup(id: 'bookshelf', steps: [
    GuideStep(
      '传输与本地导入',
      '点击打开导入与传输菜单，支持单文件与目录扫描导入本地图书/漫画，'
      '也可通过 WiFi 网页传输、WebDAV 备份同步或推送到 Kindle。',
    ),
    GuideStep(
      '书架管理与排序',
      '左侧第一个按钮为书架管理，可新建分类、排序与隐藏书架，'
      '内部右上角齿轮还可打开书架视觉与显示设置；'
      '第二个按钮可快捷切换书籍排序方式。',
    ),
    GuideStep(
      '批量删除与移出',
      '长按书架条目或进入书架管理，可批量删除选中项、'
      '移出当前书架或加入其他书架。',
    ),
    GuideStep(
      '移动书架',
      '选中条目后可批量移动至其他书架，方便整理归类。',
    ),
    GuideStep(
      '导航栏上滑多选',
      '在底部导航栏的「书架」图标向上滑动，'
      '即可快速唤起批量多选（批量删除、加入大文件夹、移动书架）。',
    ),
  ]);

  /// 我的页 5 条
  static const me = GuideGroup(id: 'me', steps: [
    GuideStep(
      '笔记与历程计划',
      '集中管理全书库划线笔记、回顾每日阅读时间线足迹，'
      '并定制每日阅读打卡目标。',
    ),
    GuideStep(
      '显示设置（重点推荐）',
      '深度定制默认首页、搜索视图、封面质感及立体书架风格，'
      '建议仔细查看并定制专属视觉。',
    ),
    GuideStep(
      '阅读设置（重点推荐）',
      '涵盖漫画与图书翻页模式、轻量仿真动效、字距排版与手势触控区，'
      '强烈建议仔细阅读配置。',
    ),
    GuideStep(
      '下载设置（重点推荐）',
      '可配置多线程并发、整本/选章离线缓存、超时重试与存储目录，'
      '保障流畅离线阅读体验。',
    ),
    GuideStep(
      '通用设置（重点推荐）',
      '包含 WebDAV 全量数据同步备份、系统手势协同、调试日志与'
      '存储空间清理，保障数据安全。',
    ),
  ]);
}

/// 全局引导协调器：同一时间只展示一组（避免 IndexedStack 多页同时弹）
class GuideCoordinator {
  GuideCoordinator._();

  static final GuideCoordinator instance = GuideCoordinator._();

  bool _showing = false;
  final List<_GuideRequest> _queue = [];

  /// 请求展示一组引导（busy 时入队，展示完自动弹下一组）
  void request(
    BuildContext context, {
    required GuideGroup group,
    VoidCallback? onFinish,
  }) {
    _queue.add(_GuideRequest(context, group, onFinish));
    _pump();
  }

  Future<void> _pump() async {
    if (_showing || _queue.isEmpty) return;
    final req = _queue.removeAt(0);
    final ctx = req.context;
    if (!ctx.mounted) {
      _pump();
      return;
    }
    _showing = true;
    final steps = req.group.steps.length;
    // 整组已完成则直接跳过
    if (await GuideStore.instance.isGroupDone(req.group.id, steps)) {
      _showing = false;
      _pump();
      return;
    }
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => GuideOverlayDialog(
        group: req.group,
        onAllDone: () {
          req.onFinish?.call();
          _showing = false;
          _pump();
        },
      ),
    );
    // showDialog 关闭（用户可能在过渡动画中直接关闭）时兜底解锁
    _showing = false;
    _pump();
  }
}

class _GuideRequest {
  final BuildContext context;
  final GuideGroup group;
  final VoidCallback? onFinish;

  _GuideRequest(this.context, this.group, this.onFinish);
}

/// 引导弹窗（白色卡片，样式对齐参考截图）
class GuideOverlayDialog extends StatefulWidget {
  final GuideGroup group;
  final VoidCallback onAllDone;

  const GuideOverlayDialog({
    super.key,
    required this.group,
    required this.onAllDone,
  });

  @override
  State<GuideOverlayDialog> createState() => _GuideOverlayDialogState();
}

class _GuideOverlayDialogState extends State<GuideOverlayDialog> {
  int _current = 0; // 0-based，展示第 _current+1 步

  GuideStep get _step => widget.group.steps[_current];
  int get _total => widget.group.steps.length;

  Future<void> _skip() async {
    await GuideStore.instance.markGroupDone(widget.group.id, _total);
    if (mounted) Navigator.of(context).pop();
    widget.onAllDone();
  }

  Future<void> _next() async {
    await GuideStore.instance.markStepDone(widget.group.id, _current + 1);
    if (_current + 1 >= _total) {
      // 最后一步 → 整组完成
      if (mounted) Navigator.of(context).pop();
      widget.onAllDone();
      return;
    }
    if (mounted) {
      setState(() => _current += 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 弹窗固定白底深字（参考截图深色背景下弹窗也是白色）
    const cardColor = Color(0xFFFFFFFF);
    const titleColor = Color(0xFF1F1F1F);
    const bodyColor = Color(0xFF5A5A5A);
    final accent = isDark ? JellyTheme.primary : JellyTheme.primary;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    _step.title,
                    style: const TextStyle(
                      color: titleColor,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${_current + 1}/$_total',
                  style: const TextStyle(
                    color: Color(0xFF9A9A9A),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _step.message,
              style: const TextStyle(
                color: bodyColor,
                fontSize: 14,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: _skip,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF8A8A8A),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('跳过引导', style: TextStyle(fontSize: 14)),
                ),
                FilledButton(
                  onPressed: _next,
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: Text(
                    _current + 1 >= _total ? '我知道了' : '下一步',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 便捷触发：页面首次激活时调用（isActive false→true），自动排队
void maybeShowGuide(BuildContext context, GuideGroup group) {
  GuideCoordinator.instance.request(context, group: group);
}
