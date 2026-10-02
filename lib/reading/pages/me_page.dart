
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/settings_service.dart';
import '../services/theme_switch.dart';
import '../services/zlibrary_service.dart';
import '../theme/jelly_palette.dart';
import '../theme/jelly_theme.dart';
import '../widgets/bookshelf_icon.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/staggered_entrance.dart';
import 'book_search_page.dart';
import 'bookshelf_page.dart';
import 'browse_history_page.dart';
import 'custom_theme_editor_page.dart';
import 'display_settings_page.dart';
import 'download_page.dart';
import 'download_settings_page.dart';
import 'favorites_page.dart';
import 'reading_settings_page.dart';
import 'search_page.dart';
import 'book_source_repo_page.dart';
import 'source_repo_page.dart';
import 'zlibrary_auth_page.dart';
import '../../common/theme.dart';
import '../../widgets/app_icon_button.dart';
import '../../widgets/app_page_header.dart';

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
            bottom:
                8 +
                (SettingsService().navFloating
                    ? JellyNavBar.floatingTotalHeight + 8
                    : 0.0),
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
                  // ── 右上角三个圆形图标（按用户截图的位置与顺序）──────
                  //   1. 扫码     → 去「书源仓库」扫码/口令导入
                  //   2. 主题风格 → 直接开主题预设面板（与下面那张卡同一入口）
                  //   3. 明暗切换 → 月亮/太阳（跟随系统时点它=退出跟随并反转）
                  //
                  // 顺序不能反：截图里从左到右就是 扫码 / 星标 / 月亮。
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
                    icon: Icons.auto_awesome_rounded,
                    tooltip: '主题风格',
                    onTap: _showThemePresetSheet,
                  ),
                  const SizedBox(width: 8),
                  _buildThemeToggle(isDark),
                ],
              ),
            ),
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
                    StaggeredEntrance(
                      key: ValueKey('${_session}_0'),
                      index: 0,
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
                      index: 2,
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
                    StaggeredEntrance(
                      key: ValueKey('${_session}_theme_style'),
                      index: 3,
                      child: SizedBox(
                        width: itemWidth,
                        child: ListenableBuilder(
                          listenable: SettingsService(),
                          builder: (context, _) {
                            return _buildMenuItem(
                              isDark,
                              icon: Icons.palette_rounded,
                              iconBg: JellyTheme.primary,
                              title: '主题风格',
                              subtitle:
                                  '当前：${SettingsService().currentThemeInfo.name}',
                              onTap: _showThemePresetSheet,
                            );
                          },
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_4'),
                      index: 4,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.auto_stories_rounded,
                          iconBg: JellyTheme.primary,
                          title: '阅读设置',
                          subtitle: '漫画阅读模式：翻页 / 拼页',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ReadingSettingsPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_5'),
                      index: 5,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.tune_rounded,
                          iconBg: JellyTheme.primary,
                          title: '显示设置',
                          subtitle: '漫画 / 图书搜索页视图',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DisplaySettingsPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 漫画源仓库 —— 服务**漫画**（SiteConfig 网页源，取图片）
                    // 与下面的「书源仓库」是两个独立体系，别合并
                    StaggeredEntrance(
                      key: ValueKey('${_session}_source_repo'),
                      index: 6,
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
                    // 小说书源仓库 —— 服务**小说**（Legado BookSource，取文字）
                    //
                    // 与「漫画源仓库」是**两套独立体系**：
                    //   漫画源 = SiteConfig（取图片）
                    //   书源   = Legado BookSource（取文字，一个 JSON 描述一个小说站）
                    // 老桌面版也是分开的两项，这里保持一致。
                    StaggeredEntrance(
                      key: ValueKey('${_session}_book_source_repo'),
                      index: 6,
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
                    StaggeredEntrance(
                      key: ValueKey('${_session}_2'),
                      index: 7,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.download_for_offline_rounded,
                          iconBg: JellyTheme.primary,
                          title: '下载设置',
                          subtitle: '同时下载量、分片并发量',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DownloadSettingsPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_download_record'),
                      index: 8,
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
                    StaggeredEntrance(
                      key: ValueKey('${_session}_browse_history'),
                      index: 9,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.history_rounded,
                          iconBg: JellyTheme.primary,
                          title: '浏览记录',
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
                    // 被隐藏导航 tab 入口（导航栏关闭某 tab 时，依次补在"下载记录"下方）
                    for (var i = 0; i < hiddenTabs.length; i++)
                      StaggeredEntrance(
                        key: ValueKey(
                          '${_session}_hidden_${hiddenTabs[i].name}',
                        ),
                        index: 9 + i,
                        child: SizedBox(
                          width: itemWidth,
                          child: _buildHiddenTabItem(isDark, hiddenTabs[i]),
                        ),
                      ),
                    // 捐赠与支持（底部入口）
                    StaggeredEntrance(
                      key: ValueKey('${_session}_donate'),
                      index: 9 + hiddenTabs.length,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.volunteer_activism_rounded,
                          iconBg: JellyTheme.primary,
                          title: '捐赠与支持',
                          subtitle: '咸鱼店铺 · 微信 / 支付宝扫码',
                          onTap: _showDonateSheet,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部账号卡：已登录显示头像/邮箱/配额；未登录显示登录引导（参考目标样式）
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
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Material(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
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
                child: Row(
                  children: [
                    // 头像
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: logged
                            ? JellyTheme.primary
                            : (isDark
                                ? Colors.white.withValues(alpha: 0.10)
                                : Colors.black.withValues(alpha: 0.05)),
                      ),
                      child: logged
                          ? Image.asset(
                              'assets/icons/user.png',
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Icon(
                                Icons.person_rounded,
                                color: Colors.white,
                                size: 24,
                              ),
                            )
                          : Icon(
                              Icons.person_outline_rounded,
                              color: sub,
                              size: 26,
                            ),
                    ),
                    const SizedBox(width: 14),
                    // 账号信息
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            logged ? z.email : '登录 / 注册',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: fg,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            logged
                                ? 'z-library 账号 · 点击管理'
                                : '登录 z-library 账号，每日可下载 $limit 本',
                            style: TextStyle(fontSize: 13, color: sub),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 右侧：配额 / 立即登录
                    logged
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '今日可下 $used/$limit 本',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: fg,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '点击管理账号',
                                style: TextStyle(fontSize: 11, color: sub),
                              ),
                            ],
                          )
                        : Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: JellyTheme.primary,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              '立即登录',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 捐赠与支持弹窗（咸鱼店铺 · 微信/支付宝扫码）
  Future<void> _showDonateSheet() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('捐赠与支持'),
        content: const Text(
          '如果这个 App 对你有帮助，欢迎支持：\n\n'
          '· 咸鱼店铺：New-Tv 周边\n'
          '· 微信 / 支付宝：扫描店铺二维码即可\n\n'
          '每一份支持都会用来继续打磨功能。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // -------------------- 暗色模式切换 --------------------

  /// 右上角的通用圆形图标按钮（扫码 / 主题风格 用）。
  ///
  /// 与 [_buildThemeToggle] 同一套外观：38×38 白色圆 + 居中图标，
  /// 这样三个图标并排时尺寸一致（截图里它们是一样大的圆）。
  /// 明暗切换那个不能复用本方法 —— 它要挂 `_themeToggleKey` 做
  /// 圆形扩散动画的起点，所以单独实现。
  /// 顶栏右上角那三个图标按钮。
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

  // -------------------- 检查更新 --------------------


  // -------------------- 分享软件 --------------------


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
                                                  await SettingsService()
                                                      .setThemePreset(p.id);
                                                  // 等圆形揭示动画（截图+重建+扩散）完成，再收面板避免抢帧卡顿
                                                  await Future.delayed(
                                                    const Duration(
                                                      milliseconds: 500,
                                                    ),
                                                  );
                                                  if (mounted) {
                                                    Navigator.pop(context);
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
                                                    await SettingsService()
                                                        .setThemePreset(t.id);
                                                    await Future.delayed(
                                                      const Duration(
                                                        milliseconds: 500,
                                                      ),
                                                    );
                                                    if (mounted) {
                                                      Navigator.pop(context);
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
