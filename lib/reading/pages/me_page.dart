
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/settings_service.dart';
import '../services/theme_switch.dart';
import '../services/zlibrary_service.dart';
import '../theme/jelly_palette.dart';
import 'general_settings_page.dart';
import '../theme/jelly_theme.dart';
import '../widgets/bookshelf_icon.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/me_account_quick_entries.dart';
import '../widgets/staggered_entrance.dart';
import 'book_search_page.dart';
import 'bookshelf_page.dart';
import 'browse_history_page.dart';
import 'custom_theme_editor_page.dart';
import 'display_settings_page.dart';
import 'download_page.dart';
import 'download_settings_page.dart';
import 'favorites_page.dart';
import 'notes_and_journey_page.dart';
import 'reading_plan_page.dart';
import 'reading_settings_page.dart';
import 'search_page.dart';
import 'book_source_repo_page.dart';
import 'source_repo_page.dart';
import 'tts_engine_page.dart';
import 'zlibrary_auth_page.dart';
import '../../common/theme.dart';
import '../../widgets/app_icon_button.dart';
import '../../widgets/app_page_header.dart';
import 'about_page.dart';

/// "我的"页：菜单（下载设置等）+ 右上角暗色模式切换 + 版本信息
class MePage extends StatefulWidget {
  final bool isActive;

  const MePage({super.key, this.isActive = false});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  int _session = 0; // 首次切到"我的" tab 时 +1，触发卡片入场动画
  bool _hasShownEntrance = false; // 是否已播过首次入场动画
  final GlobalKey _themeToggleKey = GlobalKey(); // 暗色模式切换按钮（量取圆形扩散动画起点）
  String? _switchingTo; // 主题切换中（主题风格面板内 loading 遮罩用）

  /// 账号卡顶部让位高度：右上角快捷条从这里"露出上沿"（见 [_buildAccountCard]）
  static const double _quickPeek = 28;

  @override
  void didUpdateWidget(covariant MePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅首次切到"我的" tab 时重播入场动画，之后切回不再触发（避免闪烁）
    if (widget.isActive && !oldWidget.isActive && !_hasShownEntrance) {
      _hasShownEntrance = true;
      setState(() => _session++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    // 导航栏被隐藏的 tab（在"下载记录"下方依次补入口）
    final hiddenTabs = NavTab.values
        .where(
          (t) =>
              t != NavTab.me && !SettingsService().visibleNavTabs.contains(t),
        )
        .toList();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.only(
            left: 12,
            right: 12,
            top: 0,
            bottom: 8 + JellyNavBar.contentBottomAvoid,
          ),
          children: [
            // 标题 + 右上角暗色模式切换
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 12),
              child: Row(
                children: [
                  // 标题：坐标与其它顶栏页对齐（原来这里多包了一层
                  // `Padding(left: 4)`，于是「我的」比别页标题右移 4px）
                  AppPageTitle('我的', color: titleColor),
                  const Spacer(),
                  // ── 右上角三个圆形图标（按参考图 IMG_8564 的位置与顺序）──
                  //   1. 扫码     → 去「书源仓库」扫码/口令导入
                  //   2. 帮助（问号）→ 关于 / 使用帮助
                  //   3. 明暗切换 → 月亮/太阳（跟随系统时点它=退出跟随并反转）
                  _buildCircleIcon(
                    isDark: isDark,
                    icon: Icons.qr_code_scanner_rounded,
                    tooltip: '扫码导入书源',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BookSourceRepoPage(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildCircleIcon(
                    isDark: isDark,
                    icon: Icons.help_outline_rounded,
                    tooltip: '帮助',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AboutPage(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildThemeToggle(isDark),
                ],
              ),
            ),
            // ── 我的笔记 / 阅读经历 / 阅读计划 ─────────────────────
            //    原来是登录卡下方**独立一行**（图标 + 常驻文字 label）。
            //    用户 2026 反馈：「那三个（我的笔记、阅读经历、阅读计划**只留图标**）
            //    图标**并排放在那个登录（也就是第一个卡片）的右上角**」✓
            //    ⇒ 三个入口已**只留图标**、去掉文字，并搬进 [ _buildAccountCard ]
            //      的卡片右上角（`Stack` + `Positioned`），
            //      实现在 `widgets/me_account_quick_entries.dart`。
            //    这里删掉的正是原来那一整块 `Padding + Row + _iconEntry×3`。
            _buildAccountCard(isDark),
            LayoutBuilder(
              builder: (context, constraints) {
                final cols = _adaptiveCols(constraints.maxWidth);
                const spacing = 12.0;
                final itemWidth =
                    (constraints.maxWidth - spacing * (cols - 1)) / cols;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    // 1. 主题风格
                    StaggeredEntrance(
                      key: ValueKey('${_session}_theme_style'),
                      index: 0,
                      child: SizedBox(
                        width: itemWidth,
                        child: ListenableBuilder(
                          listenable: SettingsService(),
                          builder: (context, _) => _buildMenuItem(
                            isDark,
                            icon: Icons.palette_rounded,
                            iconBg: JellyTheme.primary,
                            title: '主题风格',
                            subtitle:
                                '当前：${SettingsService().currentThemeInfo.name}',
                            onTap: _showThemePresetSheet,
                          ),
                        ),
                      ),
                    ),
                    // 2. 显示设置
                    StaggeredEntrance(
                      key: ValueKey('${_session}_5'),
                      index: 1,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.tune_rounded,
                          iconBg: JellyTheme.primary,
                          title: '显示设置',
                          subtitle: '搜索页视图 · 默认首页 · 封面与书架样式',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DisplaySettingsPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 3. 阅读设置
                    StaggeredEntrance(
                      key: ValueKey('${_session}_4'),
                      index: 2,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.auto_stories_rounded,
                          iconBg: JellyTheme.primary,
                          title: '阅读设置',
                          subtitle: '漫画 / 图书阅读模式：翻页 · 上下',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ReadingSettingsPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 4. 漫画源仓库 —— 服务**漫画**（SiteConfig 网页源，取图片）
                    // 与下面的「书源仓库」是两个独立体系，别合并
                    StaggeredEntrance(
                      key: ValueKey('${_session}_source_repo'),
                      index: 3,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.source_rounded,
                          iconBg: JellyTheme.primary,
                          title: '漫画源仓库',
                          subtitle: '启用源 · 云端配置',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SourceRepoPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 5. 书源仓库 —— 服务**小说**（Legado BookSource，取文字）
                    //
                    // 与「漫画源仓库」是**两套独立体系**：
                    //   漫画源 = SiteConfig（取图片）
                    //   书源   = Legado BookSource（取文字，一个 JSON 描述一个小说站）
                    // 老桌面版也是分开的两项，这里保持一致。
                    StaggeredEntrance(
                      key: ValueKey('${_session}_book_source_repo'),
                      index: 4,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.library_books_rounded,
                          iconBg: JellyTheme.primary,
                          title: '书源仓库',
                          subtitle: '导入书源 · 口令 · 排序',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const BookSourceRepoPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 6. 下载设置
                    StaggeredEntrance(
                      key: ValueKey('${_session}_2'),
                      index: 5,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.download_for_offline_rounded,
                          iconBg: JellyTheme.primary,
                          title: '下载设置',
                          subtitle: '通用 · 图书 · 书源 · 漫画',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DownloadSettingsPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 7. 下载记录
                    StaggeredEntrance(
                      key: ValueKey('${_session}_download_record'),
                      index: 6,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.download_done_rounded,
                          iconBg: JellyTheme.primary,
                          title: '下载记录',
                          subtitle: '漫画 & 图书下载管理',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DownloadPage(
                                isActive: true,
                                showBackButton: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 8. 足迹（原「浏览记录」入口，跳转不变）
                    StaggeredEntrance(
                      key: ValueKey('${_session}_browse_history'),
                      index: 7,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.history_rounded,
                          iconBg: JellyTheme.primary,
                          title: '足迹',
                          subtitle: '漫画 & 图书浏览历史',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const BrowseHistoryPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // ── 以下为原有开关 / 入口：仅调整位置，逻辑与跳转全部保留 ──
                    StaggeredEntrance(
                      key: ValueKey('${_session}_0'),
                      index: 8,
                      child: SizedBox(
                        width: itemWidth,
                        child: ListenableBuilder(
                          listenable: SettingsService(),
                          builder: (context, _) => _buildSwitchTile(
                            isDark,
                            icon: Icons.lock_person_rounded,
                            iconBg: JellyTheme.primary,
                            title: '图书使用内置账号',
                            subtitle: '关闭后需登录才能下载',
                            value: SettingsService().useBuiltinAccount,
                            onChanged: SettingsService().setUseBuiltinAccount,
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_theme_follow'),
                      index: 9,
                      child: SizedBox(
                        width: itemWidth,
                        child: ListenableBuilder(
                          listenable: SettingsService(),
                          builder: (context, _) => _buildSwitchTile(
                            isDark,
                            icon: Icons.brightness_auto_rounded,
                            iconBg: JellyTheme.primary,
                            title: '主题跟随系统',
                            subtitle: '随系统明暗自动切换',
                            value: SettingsService().themeFollowSystem,
                            onChanged: SettingsService().setThemeFollowSystem,
                          ),
                        ),
                      ),
                    ),
                    // AI 听书：多角色配音（easyVoice），音源/引擎管理
                    StaggeredEntrance(
                      key: ValueKey('${_session}_ai_tts'),
                      index: 10,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.record_voice_over_rounded,
                          iconBg: JellyTheme.primary,
                          title: 'AI 听书',
                          subtitle: '多角色配音 · 音源管理',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const TtsEnginePage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 被隐藏导航 tab 入口（导航栏关闭某 tab 时，依次补在这里）
                    for (var i = 0; i < hiddenTabs.length; i++)
                      StaggeredEntrance(
                        key: ValueKey(
                          '${_session}_hidden_${hiddenTabs[i].name}',
                        ),
                        index: 11 + i,
                        child: SizedBox(
                          width: itemWidth,
                          child: _buildHiddenTabItem(isDark, hiddenTabs[i]),
                        ),
                      ),
                  ],
                );
              },
            ),
            // 底部附注：三项可点文字链接（同步与备份 · 软件日志 · 缓存清理）
            _buildFooterLinks(isDark),
          ],
        ),
      ),
    );
  }

  /// 顶部账号卡（参考目标设计）：
  ///   左侧：圆形头像（描边 + 右下角相机角标）
  ///   中间：用户名（加粗）+ 小号灰字「z-library」；下一行邮箱灰字
  ///   右侧：`>` 箭头
  ///   右下角：灰字小号「今日可下 N/N 本」（取不到限额时隐藏该行）
  ///   卡片右上角**后方**：一条横向快捷条（我的笔记 / 阅读经历 / 阅读计划），
  ///     用 `Stack` 让它"压在卡片后面露出一部分"（顶部让位 [_quickPeek]）。
  ///
  /// ── 分层顺序 ────────────────────────────────────────────────
  /// `Stack.children` 的**绘制顺序 = 先后顺序**：快捷条在前（下层，被压），
  /// 账号卡在后（上层）。卡片用 `Padding(top: _quickPeek)` 整体下移，
  /// 于是快捷条上沿在卡片上方**露出** `_quickPeek` 高的一段 ✓。
  ///
  /// ⚠️ 账号字段（用户名 / 邮箱 / 限额）全部取自 [ZlibraryService] 的现有
  ///    状态，**取不到的字段就隐藏或退回状态文案**，绝不编造。
  Widget _buildAccountCard(bool isDark) {
    return ListenableBuilder(
      listenable: ZlibraryService(),
      builder: (context, _) {
        final z = ZlibraryService();
        final logged = z.isLoggedIn;
        final limit = logged
            ? (z.serverDownloadsLimit ?? ZlibraryService.loggedDailyLimit)
            : ZlibraryService.builtinDailyLimit;
        final used = logged ? z.loggedCountToday : z.builtinCountToday;
        final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
        final sub = isDark
            ? Colors.white.withValues(alpha: 0.55)
            : JellyTheme.textSecondary;
        final cardColor = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
        // 头像描边：深色下淡白、浅色下淡黑，两种主题下都能看清一圈
        final avatarRing = isDark
            ? Colors.white.withValues(alpha: 0.18)
            : Colors.black.withValues(alpha: 0.10);
        // 今日可下载量（限额取不到 / ≤0 时隐藏这一行）
        final showQuota = limit > 0;
        final remaining = (limit - used).clamp(0, limit);

        final name = logged
            ? (z.username.isNotEmpty
                ? z.username
                : (z.email.isNotEmpty ? z.email : '已登录'))
            : '还未登录';
        final secondLine = logged
            ? (z.email.isNotEmpty ? z.email : '点击管理账号')
            : '登录后可下载更多图书';

        final card = Material(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const ZlibraryAuthPage(),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // 圆形头像（描边 + 右下角相机编辑角标）
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: logged
                                  ? JellyTheme.primary
                                  : (isDark
                                      ? Colors.white.withValues(alpha: 0.10)
                                      : const Color(0xFFEDEEF0)),
                              border: Border.all(color: avatarRing, width: 2),
                            ),
                            child: logged
                                ? Image.asset(
                                    'assets/icons/user.png',
                                    width: 52,
                                    height: 52,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(
                                      Icons.person_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  )
                                : Icon(
                                    Icons.person_rounded,
                                    color: sub,
                                    size: 32,
                                  ),
                          ),
                          // 相机角标（编辑头像入口）
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: JellyTheme.primary,
                                border: Border.all(color: cardColor, width: 2),
                              ),
                              child: const Icon(
                                Icons.photo_camera_rounded,
                                size: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 14),
                      // 账号信息：用户名 + z-library 标签 / 邮箱
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Flexible(
                                  child: Text(
                                    name,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: fg,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (logged) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    'z-library',
                                    style: TextStyle(fontSize: 12, color: sub),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              secondLine,
                              style: TextStyle(fontSize: 13, color: sub),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.chevron_right_rounded, color: sub, size: 24),
                    ],
                  ),
                  // ── 右下角：今日可下载量（灰字小号）──
                  if (showQuota) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        '今日可下 $remaining/$limit 本',
                        style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: sub,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );

        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 快捷条：先绘制 ⇒ 在卡片下层，被卡片压住下半部，只露出上沿
              Positioned(
                top: 0,
                right: 16,
                child: MeAccountQuickEntries(
                  // 测试用的稳定锚点（`find.byKey`）
                  key: const ValueKey('me_account_quick_entries'),
                  isDark: isDark,
                  onNotes: () => _push(const NotesAndJourneyPage()),
                  onJourney: () => _push(
                    const BrowseHistoryPage(showTabs: false),
                  ),
                  // ⚠️ 「阅读计划」接线保持指向 `ReadingPlanPage`（跳转目标未变）
                  onPlan: () => _push(const ReadingPlanPage()),
                ),
              ),
              // 账号卡：后绘制 ⇒ 压住快捷条下半部；顶部让位 [_quickPeek]
              Padding(
                padding: const EdgeInsets.only(top: _quickPeek),
                child: card,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 卡片内跳转（三个图标入口共用）
  void _push(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  /// 底部附注：三项可点文字链接（同步与备份 · 软件日志 · 缓存清理）。
  ///
  /// ⚠️ 降级说明（"能跳的就跳"）：
  ///   · 「软件日志」有独立公开页 [AppLogPage] ⇒ 直接跳它；
  ///   · 「同步与备份」「缓存清理」在代码里是 [GeneralSettingsPage] 的**私有**
  ///     入口（`_showSyncSheet` / `_CacheCleanupPage`），无法单跳到子项，
  ///     这里统一跳到承载它们的 [GeneralSettingsPage]（未丢失入口）。
  Widget _buildFooterLinks(bool isDark) {
    final style = TextStyle(
      fontSize: AppTheme.fontCaption,
      color: isDark
          ? Colors.white.withValues(alpha: 0.45)
          : JellyTheme.textSecondary,
    );
    Widget link(String label, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Text(label, style: style),
        );
    final dot = Text(' · ', style: style);
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          link('同步与备份', () => _push(const GeneralSettingsPage())),
          dot,
          link('软件日志', () => _push(const AppLogPage())),
          dot,
          link('缓存清理', () => _push(const GeneralSettingsPage())),
        ],
      ),
    );
  }

  // -------------------- 暗色模式切换 --------------------
  /// 顶栏右上角那三个图标按钮。
  ///
  /// 与 [_buildThemeToggle] 同一套外观：38×38 白色圆 + 居中图标，
  /// 这样三个图标并排时尺寸一致（截图里它们是一样大的圆）。
  /// 明暗切换那个不能复用本方法 —— 它要挂 `_themeToggleKey` 做
  /// 圆形扩散动画的起点，所以单独实现。
  ///
  /// ⚠️ 实现已抽到 [AppIconButton]（B 档：图标按钮统一）。
  ///
  /// 这里原来用的是 **`JellyTheme.cardDark` 实底**，而其余三个页面
  /// （书架/图书搜索/收藏）用的是**白 10% 淡底** —— 同一个概念两种观感。
  /// 现在统一成淡底（`AppIconButton` 的默认形态）。
  /// 尺寸仍是 38（比别处的 36 大一档，是「我的」页原本的规格，保留）。
  Widget _buildCircleIcon({
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return AppIconButton(
      icon: icon,
      tooltip: tooltip,
      onTap: onTap,
      isDark: isDark,
      size: 38,
    );
  }

  /// 右上角明暗模式切换图标：暗色显太阳、亮色显月亮（内置图标），颜色区分明暗
  Widget _buildThemeToggle(bool isDark) {
    return ListenableBuilder(
      listenable: SettingsService(),
      builder: (context, _) {
        final dark = SettingsService().isDarkMode;
        return Material(
          key: _themeToggleKey,
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              // 以图标中心作为主题切换圆形扩散动画的起点
              final ro = _themeToggleKey.currentContext?.findRenderObject();
              if (ro is RenderBox && ro.hasSize) {
                ThemeSwitch.origin = ro.localToGlobal(
                  ro.size.center(Offset.zero),
                );
              }
              final s = SettingsService();
              if (s.themeFollowSystem) {
                // 跟随系统时手动切换：退出跟随，并切到与当前生效相反的明暗
                s.setThemeFollowSystem(false);
                s.setDarkMode(!s.isDarkMode);
              } else {
                s.setDarkMode(!s.isDarkMode);
              }
            },
            child: SizedBox(
              width: 38,
              height: 38,
              child: Center(
                child: Icon(
                  dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  size: 20,
                  color: dark ? Colors.amber.shade600 : Colors.indigo.shade400,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // -------------------- 通用 --------------------



  /// 打开 QQ 群名片（带加入按钮）；未安装 QQ 则复制群号


  Widget _buildMenuItem(
    bool isDark, {
    IconData? icon,
    JellyIconBuilder? iconBuilder,
    required Color iconBg,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    assert(icon != null || iconBuilder != null);
    return Material(
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconBg.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: iconBuilder != null
                    ? iconBuilder(iconBg, 20)
                    : Icon(icon, color: iconBg, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.white
                            : JellyTheme.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(height: 2),
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
              Icon(
                Icons.chevron_right_rounded,
                color: isDark ? Colors.white38 : Colors.black26,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------- 主题风格选择 --------------------

  /// 主题预设选择底部 sheet：3 套预设卡（名称 + 主色/强调色/背景色块），选中打勾
  void _showThemePresetSheet() {
    _switchingTo = null;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            final isDark = Theme.of(sheetCtx).brightness == Brightness.dark;
            final switching = _switchingTo != null;
            return ListenableBuilder(
              listenable: SettingsService(),
              builder: (sheetCtx, _) {
                final current = SettingsService().themePreset;
                return Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? JellyTheme.cardDark
                            : JellyTheme.cardLight,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(24),
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: Container(
                              width: 36,
                              height: 4,
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: isDark ? Colors.white24 : Colors.black12,
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Text(
                                '主题风格',
                                style: TextStyle(
                                  fontSize: AppTheme.fontTitle3,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? Colors.white
                                      : JellyTheme.textPrimaryLight,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '省电',
                                style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                              ),
                              Transform.scale(
                                scale: 0.75,
                                child: Switch(
                                  value: SettingsService().frameRateReduced,
                                  onChanged: switching
                                      ? null
                                      : (v) => SettingsService()
                                            .setFrameRateReduced(v),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '动画',
                                style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                              ),
                              Transform.scale(
                                scale: 0.75,
                                child: Switch(
                                  value: SettingsService().backgroundAnimation,
                                  onChanged: switching
                                      ? null
                                      : (v) => SettingsService()
                                            .setBackgroundAnimation(v),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.of(sheetCtx).size.height * 0.55,
                            ),
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 预设：圆点网格（每主题一颗大圆点 + 名称）
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 14,
                                    children: [
                                      for (final p in themePresets)
                                        _buildPresetDot(
                                          p,
                                          p.id == current,
                                          isDark,
                                          switching
                                              ? null
                                              : () async {
                                                  setSheetState(
                                                    () => _switchingTo = p.id,
                                                  );
                                                  // ✗ 原来在 await 之后写 `if (mounted) Navigator.pop(context)`：
                                                  //   `context` 是 MePage 的，`mounted` 也只保证 MePage 还
                                                  //   活着（它常驻 IndexedStack，恒为 true）—— 弹层被用户点
                                                  //   暗区 / 返回键提前关掉后，这一 pop 弹掉的是它底下的
                                                  //   **根路由 ContentView** ✗ → 空栈黑屏 ✗。
                                                  // ✓ 现在在 await **之前**同步抓住弹层自己的
                                                  //   NavigatorState + ModalRoute（顺带避开
                                                  //   use_build_context_synchronously ✗），
                                                  //   500ms 后只有弹层仍是栈顶（isCurrent）才收面板 ✓。
                                                  final sheetNav = Navigator.of(sheetCtx);
                                                  final sheetRoute =
                                                      ModalRoute.of(sheetCtx);
                                                  await SettingsService()
                                                      .setThemePreset(p.id);
                                                  // 等圆形揭示动画（截图+重建+扩散）完成，再收面板避免抢帧卡顿
                                                  await Future.delayed(
                                                    const Duration(
                                                      milliseconds: 500,
                                                    ),
                                                  );
                                                  // 弹层已被用户关掉 → isCurrent=false → 什么都不做 ✓
                                                  if (sheetRoute != null &&
                                                      sheetRoute.isCurrent &&
                                                      sheetNav.mounted) {
                                                    sheetNav.pop();
                                                  }
                                                },
                                        ),
                                    ],
                                  ),
                                  if (SettingsService()
                                      .customThemes
                                      .isNotEmpty) ...[
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        4,
                                        14,
                                        4,
                                        8,
                                      ),
                                      child: Text(
                                        '我的自定义（长按可编辑/删除）',
                                        style: TextStyle(
                                          fontSize: AppTheme.fontSubhead,
                                          color: JellyTheme.textSecondary,
                                        ),
                                      ),
                                    ),
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 14,
                                      children: [
                                        for (final t
                                            in SettingsService().customThemes)
                                          _buildPresetDot(
                                            t,
                                            t.id == current,
                                            isDark,
                                            switching
                                                ? null
                                                : () async {
                                                    setSheetState(
                                                      () => _switchingTo = t.id,
                                                    );
                                                    // ✗ 同上：`Navigator.pop(context)` 用的是 MePage 的
                                                    //   context，弹层被用户提前关掉时这里弹的是底下的
                                                    //   根路由 ContentView ✗ → 空栈黑屏 ✗。
                                                    // ✓ 同样在 await 前同步抓弹层自己的
                                                    //   NavigatorState + ModalRoute，确认它仍是栈顶
                                                    //   （isCurrent）才 pop ✓。
                                                    final sheetNav =
                                                        Navigator.of(sheetCtx);
                                                    final sheetRoute =
                                                        ModalRoute.of(sheetCtx);
                                                    await SettingsService()
                                                        .setThemePreset(t.id);
                                                    await Future.delayed(
                                                      const Duration(
                                                        milliseconds: 500,
                                                      ),
                                                    );
                                                    // 弹层已被用户关掉 → isCurrent=false → 什么都不做 ✓
                                                    if (sheetRoute != null &&
                                                        sheetRoute.isCurrent &&
                                                        sheetNav.mounted) {
                                                      sheetNav.pop();
                                                    }
                                                  },
                                            deletable: true,
                                            onDelete: () =>
                                                _confirmDeleteCustom(t),
                                            editable: true,
                                            onEdit: () => _editCustom(t),
                                          ),
                                      ],
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  _buildCreateThemeButton(isDark),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (switching)
                      Positioned.fill(
                        child: AbsorbPointer(
                          child: Container(
                            decoration: BoxDecoration(
                              color: (isDark ? Colors.black : Colors.white)
                                  .withValues(alpha: 0.45),
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(24),
                              ),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(
                                    color: JellyTheme.primary,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    '应用中...',
                                    style: TextStyle(
                                      fontSize: AppTheme.fontBody,
                                      color: isDark
                                          ? Colors.white70
                                          : JellyTheme.textPrimaryLight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// 一个主题「圆点」（照用户截图的样式 + 复用统一主题页的画法）。
  ///
  /// ── 为什么改成"一个大圆点" ────────────────────────────────────
  /// 原来是**每个主题三个小圆点**（主色/强调色/浅色底）排一行、占满整宽。
  /// 用户对比后指出："这个圆点样式没有（统一主题页）这一排好看"。
  ///
  /// 统一主题页 `_presetDot` 的做法是 **一个 SweepGradient 四色环大圆点**：
  /// 颜色沿圆周扫过，像一颗小球 —— 比三个并排的小点更有"一颗主题"的整体感，
  /// 也更容易一眼分辨 7 套配色。这里照抄那个画法并把尺寸放大到 52。
  ///
  /// 自定义主题的「编辑 / 删除」放**长按菜单**（点按 = 应用主题）——
  /// 圆点式布局里没有合适的位置常驻两个图标，长按是 iOS 的常规交互。
  Widget _buildPresetDot(
    ThemePresetInfo preset,
    bool selected,
    bool isDark,
    VoidCallback? onTap, {
    bool deletable = false,
    VoidCallback? onDelete,
    bool editable = false,
    VoidCallback? onEdit,
  }) {
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final hintColor = JellyTheme.textSecondary;
    final canEdit = (editable && onEdit != null) || (deletable && onDelete != null);

    Future<void> showActions() async {
      if (!canEdit) return;
      final v = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text(
                      preset.name,
                      style: TextStyle(
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                  ],
                ),
              ),
              if (editable && onEdit != null)
                ListTile(
                  leading: const Icon(Icons.edit_outlined, size: 20),
                  title: const Text('编辑主题'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onEdit();
                  },
                ),
              if (deletable && onDelete != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded,
                      size: 20, color: Colors.redAccent),
                  title: const Text('删除主题',
                      style: TextStyle(color: Colors.redAccent)),
                  onTap: () {
                    Navigator.pop(ctx);
                    onDelete();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      // showModalBottomSheet 的返回值这里用不到（动作在 onTap 里已执行）
      if (v != null) return;
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: canEdit ? showActions : null,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                // 四色扫描渐变 —— 与统一主题页 _presetDot 同一画法
                gradient: SweepGradient(colors: [
                  preset.palette.backgroundLight,
                  preset.palette.primary,
                  preset.palette.backgroundDark,
                  preset.palette.accent,
                  preset.palette.backgroundLight,
                ]),
                shape: BoxShape.circle,
                // 选中：加粗描边 + 打勾；未选中：细描边
                border: Border.all(
                  color: selected ? labelColor : hintColor.withValues(alpha: 0.4),
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: selected
                  ? Icon(Icons.check,
                      size: 20,
                      color: preset.palette.backgroundLight.computeLuminance() >
                              0.5
                          ? Colors.black87
                          : Colors.white)
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              preset.name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                height: 1.15,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? labelColor : hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「新建自定义主题」按钮：跳转编辑器（保存后 addCustomTheme 已通知，sheet 自动刷新）
  ///
  /// 样式照用户给的截图：**中性描边圆角按钮**（不是主题色描边）——
  /// 面板里已经有 10 个主题色点了，按钮再用主题色会显得花；
  /// 中性灰/白描边让"新建"这个动作在视觉上退后一步，不与主题卡抢注意。
  Widget _buildCreateThemeButton(bool isDark) {
    final stroke = isDark
        ? Colors.white.withValues(alpha: 0.22)
        : Colors.black.withValues(alpha: 0.16);
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CustomThemeEditorPage()),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: stroke, width: 1.2),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_rounded, color: fg, size: 20),
                const SizedBox(width: 6),
                Text(
                  '新建自定义主题',
                  style: TextStyle(
                    color: fg,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 删除自定义主题二次确认；删的若是当前主题，deleteCustomTheme 会回退 jelly 并触发动画
  Future<void> _confirmDeleteCustom(ThemePresetInfo t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除主题'),
        content: Text('确定删除「${t.name}」？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: JellyTheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await SettingsService().deleteCustomTheme(t.id);
    }
  }

  /// 编辑自定义主题：打开编辑器（带 editing）。保存后 updateCustomTheme 通知，
  /// sheet 的 ListenableBuilder 自动刷新；当前主题的改动即时生效。
  void _editCustom(ThemePresetInfo t) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CustomThemeEditorPage(editing: t)),
    );
  }

  /// 被隐藏导航 tab 的入口（导航栏关闭该 tab 时，在"我的"补入口）
  Widget _buildHiddenTabItem(bool isDark, NavTab tab) {
    switch (tab) {
      case NavTab.manga:
        return _buildMenuItem(
          isDark,
          icon: Icons.palette_rounded,
          iconBg: JellyTheme.primary,
          title: '漫画',
          subtitle: '漫画搜索与阅读',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const SearchPage(isActive: true, showBackButton: true),
            ),
          ),
        );
      case NavTab.book:
        return _buildMenuItem(
          isDark,
          icon: Icons.book_rounded,
          iconBg: JellyTheme.primary,
          title: '图书',
          subtitle: '图书搜索与阅读',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const BookSearchPage(isActive: true, showBackButton: true),
            ),
          ),
        );
      case NavTab.favorites:
        return _buildMenuItem(
          isDark,
          icon: Icons.favorite_rounded,
          iconBg: JellyTheme.primary,
          title: '收藏',
          subtitle: '漫画 & 图书收藏',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const FavoritesPage(isActive: true, showBackButton: true),
            ),
          ),
        );
      case NavTab.bookshelf:
        return _buildMenuItem(
          isDark,
          iconBuilder: (color, size) => BookshelfIcon(color: color, size: size),
          iconBg: JellyTheme.primary,
          title: '书架',
          subtitle: '本地书架管理',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const BookshelfPage(isActive: true, showBackButton: true),
            ),
          ),
        );
      case NavTab.me:
        return const SizedBox.shrink(); // 不会出现（me 始终可见）
    }
  }

  /// 开关设置行（左图标 + 标题/副标题 + 右侧 Switch），一层设置不跳子页面
  Widget _buildSwitchTile(
    bool isDark, {
    required IconData icon,
    required Color iconBg,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Material(
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconBg.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconBg, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? Colors.white
                          : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  const SizedBox(height: 2),
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
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  /// 菜单卡片自适应列数：默认每行 1 个，宽度足够时自动增多
  int _adaptiveCols(double width) {
    var cols = (width / 360).floor();
    if (cols < 1) cols = 1;
    if (cols > 6) cols = 6;
    return cols;
  }
}
