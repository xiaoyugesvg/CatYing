/// RFW 主题的**预览**能力。
///
/// ── 为什么要有这一层（2026-10-30）──────────────────────────────
/// 用户：「RFW 主题加个预览和可视化呢」。
/// 之前主题列表只有一行「图标 + 名字 + 内置/导入」，选之前完全不知道
/// 那套主题长什么样 —— 只能先选中、退出设置、回首页看、不满意再回来换。
///
/// 这里做两件事：
///   1. [RfwThemeThumb]：列表里的**实时缩略图**。不是截图，是真的用
///      `RfwThemeHost` 渲染一遍首页（假数据），所以配色会跟着「外观 → 配色」
///      一起变，换配色时缩略图立刻跟着换。
///   2. [RfwThemePreviewPage]：全屏预览，可以切显示样式、看完直接「用这个主题」。
///
/// ⚠️ 预览只喂**假数据**（[sampleRfwHomeInput]），不碰真实源、不发网络请求。
/// 封面图统一给空串，走 `T4Image` 的占位块 —— 预览不需要真海报，
/// 有真海报反而会让"看版式"变成"看封面"。
library;

import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/movie_sort.dart';
import 'package:tvbox/rfw_theme/rfw_theme_data.dart';
import 'package:tvbox/rfw_theme/rfw_theme_host.dart';
import 'package:tvbox/rfw_theme/rfw_theme_library.dart';
import 'package:tvbox/rfw_theme/rfw_theme_store.dart';


/// 预览用的手机逻辑尺寸（iPhone 14 一类的竖屏）。
const Size kRfwPreviewSize = Size(390, 844);

/// 预览用的假首页数据。
///
/// 刻意凑齐主题会用到的每个槽位：
/// 分类 3 个（不触发 `hasManyClasses` 的折叠分支）、推荐 2 条（轮播）、
/// 片单 8 条（够铺满两行网格）、筛选项 1 组（顶栏筛选按钮可见）。
RfwHomeDataInput sampleRfwHomeInput({
  required String themeId,
  String displayStyle = 'grid',
  bool showFilters = false,
}) {
  const titles = [
    '夜行列车',
    '雾港谜案',
    '山海拾遗',
    '第七封信',
    '雨夜霓虹',
    '白塔之下',
    '长街旧梦',
    '星轨之外',
  ];
  const notes = ['更新至12集', '全24集', '2024', 'HD', '更新至8集', '完结'];
  return RfwHomeDataInput(
    categories: const [
      SortData(id: '1', name: '推荐'),
      SortData(id: '2', name: '电影'),
      SortData(id: '3', name: '剧集'),
    ],
    category: '1',
    items: [
      for (var i = 0; i < titles.length; i++)
        Video(
          id: 'sample-$i',
          name: titles[i],
          pic: '',
          note: notes[i % notes.length],
        ),
    ],
    recommend: [
      Video(id: 'sample-r1', name: '本週热播', pic: '', note: '2024 · 剧情'),
      Video(id: 'sample-r2', name: '编辑推荐', pic: '', note: '2024 · 悬疑'),
    ],
    filters: const [
      SortFilter(
        key: 'year',
        name: '年份',
        values: [
          SortFilterValue(n: '2024', v: '2024'),
          SortFilterValue(n: '2023', v: '2023'),
          SortFilterValue(n: '2022', v: '2022'),
        ],
      ),
    ],
    selectedFilters: const {},
    displayStyle: displayStyle,
    showFilters: showFilters,
    totalLabel: '128',
    sourceName: '示例源',
    themeId: themeId,
  );
}

/// 主题文本的内存缓存。
///
/// 列表里 5 套主题各要读一次资源文件；每次 `setState` 都重读一遍既慢又
/// 会闪。这里按 id 缓存 `Future`，同一套主题只读一次。
class RfwThemeTextCache {
  RfwThemeTextCache._();

  static final Map<String, Future<String?>> _futures = {};

  static Future<String?> load(RfwThemeEntry entry) {
    return _futures.putIfAbsent(entry.id, () => loadRfwThemeText(entry));
  }

  /// 导入 / 删除主题后必须清掉，否则同名主题改完内容还是旧预览。
  static void evict(String id) => _futures.remove(id);

  static void clear() => _futures.clear();
}

/// 把主题渲染成一块手机屏幕（逻辑尺寸 [kRfwPreviewSize]）。
///
/// [interactive] = false 时套一层 `IgnorePointer`：缩略图不该抢走外层
/// 列表项的手势（否则点缩略图选不中主题）。
class RfwThemeScreen extends StatelessWidget {
  const RfwThemeScreen({
    super.key,
    required this.themeText,
    required this.themeId,
    this.displayStyle = 'grid',
    this.showFilters = false,
    this.interactive = false,
  });

  final String themeText;
  final String themeId;
  final String displayStyle;
  final bool showFilters;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final screen = SizedBox(
      width: kRfwPreviewSize.width,
      height: kRfwPreviewSize.height,
      child: RfwThemeHost(
        themeText: themeText,
        homeData: buildRfwHomeData(
          sampleRfwHomeInput(
            themeId: themeId,
            displayStyle: displayStyle,
            showFilters: showFilters,
          ),
        ),
        onAction: (_) {},
      ),
    );
    if (interactive) {
      return RfwPreviewScope(enabled: false, child: screen);
    }
    return IgnorePointer(
      child: RfwPreviewScope(enabled: true, child: screen),
    );
  }
}

/// 列表里的**实时缩略图**。
///
/// 做法：按真实手机尺寸渲染一遍，再用 `FittedBox(fit: cover)` 缩到卡片大小。
/// 为什么不直接给个小尺寸渲染：主题里到处是写死的像素（字号、圆角、间距），
/// 缩小画布会让版式完全走形 —— 缩略图就失去"预览"的意义了。
class RfwThemeThumb extends StatefulWidget {
  const RfwThemeThumb({
    super.key,
    required this.entry,
    this.width = 64,
    this.height = 108,
    this.displayStyle = 'grid',
    this.radius = 10,
  });

  final RfwThemeEntry entry;
  final double width;
  final double height;
  final String displayStyle;
  final double radius;

  @override
  State<RfwThemeThumb> createState() => _RfwThemeThumbState();
}

class _RfwThemeThumbState extends State<RfwThemeThumb> {
  String? _text;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RfwThemeThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id) {
      _text = null;
      _load();
    }
  }

  Future<void> _load() async {
    final text = await RfwThemeTextCache.load(widget.entry);
    if (!mounted) return;
    setState(() => _text = text);
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: text == null
            ? ColoredBox(color: AppTheme.backgroundTertiary)
            : FittedBox(
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                child: RfwThemeScreen(
                  themeText: text,
                  themeId: widget.entry.id,
                  displayStyle: widget.displayStyle,
                ),
              ),
      ),
    );
  }
}

/// 全屏预览：看版式 → 切显示样式 → 直接应用。
class RfwThemePreviewPage extends StatefulWidget {
  const RfwThemePreviewPage({
    super.key,
    required this.entry,
    this.initialDisplayStyle,
  });

  final RfwThemeEntry entry;
  final String? initialDisplayStyle;

  @override
  State<RfwThemePreviewPage> createState() => _RfwThemePreviewPageState();
}

class _RfwThemePreviewPageState extends State<RfwThemePreviewPage> {
  static const _styles = <String, String>{
    'grid': '网格',
    'largeGrid': '大网格',
    'banner': '横幅',
    'list': '列表',
    'textList': '纯文字',
    'card': '卡片',
  };

  String? _text;
  bool _failed = false;
  late String _style;

  @override
  void initState() {
    super.initState();
    _style = widget.initialDisplayStyle ?? rfwDisplayStyleNotifier.value;
    _load();
  }

  Future<void> _load() async {
    final text = await RfwThemeTextCache.load(widget.entry);
    if (!mounted) return;
    setState(() {
      _text = text;
      _failed = text == null;
    });
  }

  Future<void> _apply() async {
    await saveRfwThemeId(widget.entry.id);
    await saveRfwThemeMode(true);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          widget.entry.name,
          style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontTitle3),
        ),
      ),
      body: Column(
        children: [
          Expanded(child: Center(child: _screen())),
          _stylePicker(),
          _bottomBar(),
        ],
      ),
    );
  }

  Widget _screen() {
    final text = _text;
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '这套主题读不出来（文件可能被删了，或解析失败）',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textTertiary, fontSize: AppTheme.fontSubhead),
        ),
      );
    }
    if (text == null) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: AspectRatio(
        aspectRatio: kRfwPreviewSize.width / kRfwPreviewSize.height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppTheme.borderLight, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(21),
            child: FittedBox(
              fit: BoxFit.contain,
              child: RfwThemeScreen(
                themeText: text,
                themeId: widget.entry.id,
                displayStyle: _style,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stylePicker() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final e in _styles.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => setState(() => _style = e.key),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: _style == e.key
                        ? AppTheme.accentColor
                        : AppTheme.backgroundTertiary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    e.value,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: _style == e.key
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: _style == e.key
                          ? (AppTheme.accentColor.computeLuminance() > 0.5
                              ? Colors.black
                              : Colors.white)
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '预览用的是示例数据，实际显示以你的源为准',
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: AppTheme.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _failed ? null : _apply,
              child: const Text('用这个主题'),
            ),
          ],
        ),
      ),
    );
  }
}
