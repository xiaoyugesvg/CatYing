import 'package:flutter/material.dart';
import '../services/book_view_mode.dart';
import '../pet/pet_center_page.dart';
import '../pet/pet_service.dart';
import '../services/reading_layout.dart';
import '../services/settings_service.dart';
import '../services/view_mode.dart';
import '../theme/jelly_theme.dart';
import '../widgets/bookshelf_icon.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/reading_view_toggle.dart';
import '../../common/theme.dart';

/// 显示设置页：漫画/图书搜索页视图 + 启动默认首页。
/// 与搜索页右上角的视图切换共用 ViewMode / BookViewMode，二者同步并持久化。
class DisplaySettingsPage extends StatefulWidget {
  const DisplaySettingsPage({super.key});

  @override
  State<DisplaySettingsPage> createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends State<DisplaySettingsPage> {
  // ⚠️ 用户 2026-10-07：「将视图按钮只在我的里面的显示设置里面就行」
  //   ⇒ 视图换成了与页面共用的**同一个选择表**（列表 / 宫格·3/4/5 列），
  //     这里不再需要两个 2 段的 TabController 做动画切换 ✓
  //   ⇒ 同时补上**书源页视图**（原来只有漫画/图书两项）✓

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('显示设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCard(
            isDark,
            title: '启动默认首页',
            subtitle: 'App 启动时直接进入的页面',
            trailing: ListenableBuilder(
              listenable: SettingsService(),
              builder: (context, _) => _buildHomeDropdown(isDark),
            ),
          ),
          const SizedBox(height: 12),
          // 悬浮导航栏开关（第二位）
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildFloatingNavBarCard(isDark),
          ),
          const SizedBox(height: 12),
          // 导航栏显示设置（第三位）
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildNavBarVisibilityCard(isDark),
          ),
          const SizedBox(height: 12),
          // 页面分类跟随导航栏开关
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildPageTabsFollowNavCard(isDark),
          ),
          const SizedBox(height: 12),
          // 默认显示内容（漫画/图书）
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildDefaultContentCard(isDark),
          ),
          const SizedBox(height: 12),
          // ── 书架 / 收藏 卡片外观（用户 2026-10-15：显示设置新增 3 项）──
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildCard(
              isDark,
              title: '列表密度',
              subtitle: '书架 / 收藏页卡片之间的松紧',
              trailing: _buildChoiceTrailing(
                isDark,
                labels: const ['紧凑', '标准', '宽松'],
                index: SettingsService().listDensity,
                onPick: (i) => SettingsService().setListDensity(i),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildCard(
              isDark,
              title: '封面圆角',
              subtitle: '书架 / 收藏页封面的圆角大小',
              trailing: _buildChoiceTrailing(
                isDark,
                labels: const ['小', '中', '大'],
                index: SettingsService().coverRadius,
                onPick: (i) => SettingsService().setCoverRadius(i),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildCard(
              isDark,
              title: '卡片信息',
              subtitle: '封面上的进度 / 来源 / 更新角标',
              trailing: Switch.adaptive(
                value: SettingsService().cardInfo,
                onChanged: (v) => SettingsService().setCardInfo(v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // ── 桌宠中心（用户 2026-10-18：从「我的」页挪到这里）──────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PetCenterPage()),
            ),
            child: _buildCard(
              isDark,
              title: '桌宠中心',
              subtitle: '养成 · 图鉴 · 换装 · 自定义 PNG / GIF',
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // ── 悬浮桌宠（用户 2026-10-18）：显示 / 隐藏 + 大小 ──────────
          ListenableBuilder(
            listenable: PetService.instance,
            builder: (context, _) => _buildCard(
              isDark,
              title: '悬浮桌宠',
              subtitle: '在页面角落显示 / 隐藏宠物',
              trailing: Switch.adaptive(
                value: PetService.instance.enabled,
                onChanged: (v) => PetService.instance.setEnabled(v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _PetSizeCard(isDark: isDark),
          const SizedBox(height: 12),
          _buildViewCard(
            isDark,
            title: '漫画搜索页视图',
            subtitle: '漫画搜索与漫画收藏页的卡片布局',
            mode: ViewMode(),
            isGridOf: () => ViewMode().isGrid,
            setGrid: (g) => ViewMode().set(g),
          ),
          const SizedBox(height: 12),
          _buildViewCard(
            isDark,
            title: '图书搜索页视图',
            subtitle: '图书搜索与图书收藏页的卡片布局',
            mode: BookViewMode(),
            isGridOf: () => BookViewMode().isGrid,
            setGrid: (g) => BookViewMode().set(g),
          ),
          const SizedBox(height: 12),
          // 书源页视图（本轮新增：原来只有漫画/图书两项）
          _buildViewCard(
            isDark,
            title: '书源页视图',
            subtitle: '书源搜索结果的卡片布局',
            mode: SourceViewMode(),
            isGridOf: () => SourceViewMode().isGrid,
            setGrid: (g) => SourceViewMode().set(g),
          ),
        ],
      ),
    );
  }

  /// 三档分段选择（「列表密度 / 封面圆角」用）：
  /// 选中的一段用主色实底 + 白字，未选中是极浅灰底，与页面卡片风格一致。
  Widget _buildChoiceTrailing(
    bool isDark, {
    required List<String> labels,
    required int index,
    required ValueChanged<int> onPick,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          GestureDetector(
            onTap: () => onPick(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: i == index
                    ? JellyTheme.primary
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.05)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                  color: i == index
                      ? Colors.white
                      : (isDark ? Colors.white70 : JellyTheme.textPrimaryLight),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 视图卡片：右侧显示当前选择，点一下弹出与页面**共用**的「视图」选择表
  /// （列表 / 宫格·一排 3 个 / 4 个 / 5 个）✓
  ///
  /// 用户 2026-10-07：「将视图按钮只在我的里面的显示设置里面就行」
  ///   ⇒ 三个页面的顶栏都不再放视图按钮，统一到这里选 ✓
  Widget _buildViewCard(
    bool isDark, {
    required String title,
    required String subtitle,
    required Listenable mode,
    required bool Function() isGridOf,
    required void Function(bool) setGrid,
  }) {
    return ListenableBuilder(
      // 同时听视图模式 + 宫格列数（列数变了要立刻更新右侧文案）
      listenable: Listenable.merge([mode, ReadingLayout()]),
      builder: (context, _) {
        final grid = isGridOf();
        final label =
            grid ? '宫格 · 一排 ${ReadingLayout().columns} 个' : '列表';
        return _buildCard(
          isDark,
          title: title,
          subtitle: subtitle,
          trailing: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ReadingViewToggle.showSheet(
              context,
              isDark: isDark,
              isGrid: grid,
              onChanged: (g, cols) {
                ReadingLayout().setColumns(cols);
                setGrid(g);
              },
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: JellyTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  grid
                      ? Icons.grid_view_rounded
                      : Icons.view_list_rounded,
                  size: 18,
                  color: JellyTheme.primary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 悬浮导航栏开关卡片
  Widget _buildFloatingNavBarCard(bool isDark) {
    final s = SettingsService();
    return _buildCard(
      isDark,
      title: '悬浮导航栏',
      subtitle: '胶囊型毛玻璃悬浮样式，关闭为底部固定样式',
      trailing: Switch(
        value: s.navFloating,
        onChanged: (v) => s.setNavFloating(v),
        activeColor: JellyTheme.primary,
      ),
    );
  }

  /// 导航栏显示设置卡片（多行开关）
  Widget _buildNavBarVisibilityCard(bool isDark) {
    final s = SettingsService();
    final visible = s.visibleNavTabs.toSet();
    final contentTabs = <(NavTab, Widget Function(Color, double), String)>[
      (
        NavTab.manga,
        (c, s) => Icon(Icons.palette_rounded, color: c, size: s),
        '漫画',
      ),
      (
        NavTab.book,
        (c, s) => Icon(Icons.book_rounded, color: c, size: s),
        '图书',
      ),
      (NavTab.bookshelf, (c, s) => BookshelfIcon(color: c, size: s), '书架'),
      (
        NavTab.favorites,
        (c, s) => Icon(Icons.favorite_rounded, color: c, size: s),
        '收藏',
      ),
    ];
    // 内容类 tab 中已选的数量，用于判断最后一个不可取消
    final selectedContentCount = contentTabs
        .where((t) => visible.contains(t.$1))
        .length;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 卡片标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '导航栏显示',
                        style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '自定义底部导航栏显示的页面（"我的"固定显示）',
                        style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 内容类 tab 开关
          ...contentTabs.map((t) {
            final selected = visible.contains(t.$1);
            // 只剩一个内容类 tab 时不可取消
            final disabled = selected && selectedContentCount <= 1;
            return _buildSwitchRow(
              isDark,
              icon: t.$2,
              label: t.$3,
              value: selected,
              disabled: disabled,
              onChanged: (v) {
                final newList = <NavTab>{...visible};
                if (v) {
                  newList.add(t.$1);
                } else {
                  newList.remove(t.$1);
                }
                s.setVisibleNavTabs(newList.toList());
              },
            );
          }),
          // "我的"固定显示
          _buildSwitchRow(
            isDark,
            icon: (c, s) => Icon(Icons.person_rounded, color: c, size: s),
            label: '我的',
            value: true,
            disabled: true,
            onChanged: (_) {},
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 页面分类跟随导航栏开关卡片
  Widget _buildPageTabsFollowNavCard(bool isDark) {
    final s = SettingsService();
    return _buildCard(
      isDark,
      title: '页面分类跟随导航栏',
      subtitle: '收藏/书架/下载页隐藏导航栏已关闭的漫画或图书分类',
      trailing: Switch(
        value: s.pageTabsFollowNav,
        onChanged: (v) => s.setPageTabsFollowNav(v),
        activeColor: JellyTheme.primary,
      ),
    );
  }

  /// 默认显示内容卡片（漫画/图书切换）
  Widget _buildDefaultContentCard(bool isDark) {
    final s = SettingsService();
    return _buildCard(
      isDark,
      title: '默认显示',
      subtitle: '收藏/书架/下载页进入时默认显示的分类',
      trailing: JellySegmentedToggle(
        index: s.pageDefaultContent == PageDefaultContent.manga ? 0.0 : 1.0,
        onChanged: (i) {
          s.setPageDefaultContent(
            i == 0 ? PageDefaultContent.manga : PageDefaultContent.book,
          );
        },
        segments: const [
          JellySegmentData(icon: Icons.palette_rounded, label: '漫画'),
          JellySegmentData(icon: Icons.book_rounded, label: '图书'),
        ],
      ),
    );
  }

  /// 单行开关：左图标+文字，右 Switch
  Widget _buildSwitchRow(
    bool isDark, {
    required Widget Function(Color, double) icon,
    required String label,
    required bool value,
    required bool disabled,
    required ValueChanged<bool> onChanged,
  }) {
    final fgColor = disabled
        ? (isDark ? Colors.white38 : Colors.black38)
        : (isDark ? Colors.white : JellyTheme.textPrimaryLight);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          icon(fgColor, 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: AppTheme.fontBody, color: fgColor)),
          ),
          Switch(
            value: value,
            onChanged: disabled ? null : onChanged,
            activeColor: JellyTheme.primary,
          ),
        ],
      ),
    );
  }

  /// 启动默认首页下拉选择（仅显示当前可见的 tab）
  Widget _buildHomeDropdown(bool isDark) {
    final s = SettingsService();
    final icons = <NavTab, Widget Function(Color, double)>{
      NavTab.manga: (c, s) => Icon(Icons.palette_rounded, color: c, size: s),
      NavTab.book: (c, s) => Icon(Icons.book_rounded, color: c, size: s),
      NavTab.bookshelf: (c, s) => BookshelfIcon(color: c, size: s),
      NavTab.favorites: (c, s) =>
          Icon(Icons.favorite_rounded, color: c, size: s),
      NavTab.me: (c, s) => Icon(Icons.person_rounded, color: c, size: s),
    };
    const labels = <NavTab, String>{
      NavTab.manga: '漫画',
      NavTab.book: '图书',
      NavTab.bookshelf: '书架',
      NavTab.favorites: '收藏',
      NavTab.me: '我的',
    };
    final visible = s.visibleNavTabs;
    final currentTab = s.defaultHomePage.toNavTab();
    return DropdownButton<NavTab>(
      value: visible.contains(currentTab) ? currentTab : visible.first,
      underline: const SizedBox(),
      isDense: true,
      style: TextStyle(
        fontSize: AppTheme.fontBody,
        fontWeight: FontWeight.w600,
        color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
      ),
      dropdownColor: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      items: visible
          .map(
            (t) => DropdownMenuItem(
              value: t,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icons[t]!(JellyTheme.primary, 18),
                  const SizedBox(width: 6),
                  Text(labels[t]!),
                ],
              ),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) {
          s.setDefaultHomePage(v.toDefaultHomePage());
        }
      },
    );
  }

  /// 通用设置卡片：左侧标题+副标题，右侧控件
  Widget _buildCard(
    bool isDark, {
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}

/// 桌宠大小卡片：**滑动 + 输入数值**两种方式（72~160px）。
///
/// 用户 2026-10-18：「可以滑动或输入尺寸调整大小」。
class _PetSizeCard extends StatefulWidget {
  const _PetSizeCard({required this.isDark});

  final bool isDark;

  @override
  State<_PetSizeCard> createState() => _PetSizeCardState();
}

class _PetSizeCardState extends State<_PetSizeCard> {
  final _pet = PetService.instance;
  final _ctl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctl.text = _pet.size.round().toString();
    _pet.addListener(_onPet);
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _pet.removeListener(_onPet);
    _focus.dispose();
    _ctl.dispose();
    super.dispose();
  }

  void _onPet() {
    if (!mounted) return;
    // 滑动时同步输入框；用户正在输入时不打断
    if (!_focus.hasFocus) {
      _ctl.text = _pet.size.round().toString();
    }
    setState(() {});
  }

  void _onFocus() {
    if (!_focus.hasFocus) _apply(_ctl.text);
  }

  void _apply(String raw) {
    final v = double.tryParse(raw.trim());
    if (v == null) {
      _ctl.text = _pet.size.round().toString();
      return;
    }
    _pet.setSize(v);
    _ctl.text = _pet.size.round().toString();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final labelColor =
        isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '桌宠大小',
                      style: TextStyle(
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.bold,
                        color: labelColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '滑动或输入数值（${PetService.minSize.round()}–'
                      '${PetService.maxSize.round()}px）',
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '${_pet.size.round()} px',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w700,
                  color: JellyTheme.primary,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: _pet.size
                      .clamp(PetService.minSize, PetService.maxSize)
                      .toDouble(),
                  min: PetService.minSize,
                  max: PetService.maxSize,
                  divisions:
                      (PetService.maxSize - PetService.minSize).round(),
                  activeColor: JellyTheme.primary,
                  onChanged: (v) => _pet.setSize(v),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: TextField(
                  controller: _ctl,
                  focusNode: _focus,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: labelColor),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 8, horizontal: 6),
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.04),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: _apply,
                  onTapOutside: (_) => _focus.unfocus(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
