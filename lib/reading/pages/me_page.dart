import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/reading/services/zlibrary_service.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/reading/pages/general_settings_page.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/reading/widgets/bookshelf_icon.dart';
import 'package:tvbox/reading/widgets/jelly_nav_bar.dart';
import 'package:tvbox/reading/widgets/me_account_quick_entries.dart';
import 'package:tvbox/reading/widgets/staggered_entrance.dart';
import 'package:tvbox/reading/pages/book_search_page.dart';
import 'package:tvbox/reading/pages/bookshelf_page.dart';
import 'package:tvbox/reading/pages/browse_history_page.dart';
import 'package:tvbox/reading/pages/custom_theme_editor_page.dart';
import 'package:tvbox/reading/pages/display_settings_page.dart';
import 'package:tvbox/reading/pages/download_page.dart';
import 'package:tvbox/reading/pages/download_settings_page.dart';
import 'package:tvbox/reading/pages/favorites_page.dart';
import 'package:tvbox/reading/pages/book_notes_page.dart';
import 'package:tvbox/reading/pages/reading_plan_page.dart';
import 'package:tvbox/reading/pages/reading_stats_page.dart';
import 'package:tvbox/reading/pages/reader_styles_page.dart';
import 'package:tvbox/reading/models/reader_style.dart';
import 'package:tvbox/reading/services/reader_style_store.dart';
import 'package:tvbox/reading/pet/pet_models.dart';
import 'package:tvbox/reading/pet/pet_view.dart';
import 'package:tvbox/reading/pages/reading_settings_page.dart';
import 'package:tvbox/reading/pages/purify_rules_page.dart';
import 'package:tvbox/reading/pages/search_page.dart';
import 'package:tvbox/reading/pages/book_source_repo_page.dart';
import 'package:tvbox/reading/pages/source_warehouse_page.dart';
import 'package:tvbox/reading/pages/tts_engine_page.dart';
import 'package:tvbox/reading/pages/zlibrary_auth_page.dart';
import 'package:tvbox/common/theme.dart';

/// "我的"页：账号卡 + 菜单（下载设置等）+ 版本信息
class MePage extends StatefulWidget {
  final bool isActive;

  const MePage({super.key, this.isActive = false});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  int _session = 0; // 首次切到"我的" tab 时 +1，触发卡片入场动画
  bool _hasShownEntrance = false; // 是否已播过首次入场动画
  String? _switchingTo; // 主题切换中（主题风格面板内 loading 遮罩用）

  /// 内置「登录头像」素材（`assets/avatars/mine/*.jpg`，50 张，来自 Cmbok）。
  ///
  /// 用 AssetManifest 动态读取：以后往目录里加图片**不需要改代码**。
  List<String> _mineAvatars = const [];

  @override
  void initState() {
    super.initState();
    _loadMineAvatars();
  }

  Future<void> _loadMineAvatars() async {
    if (_mineAvatars.isNotEmpty) return;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final list = manifest
          .listAssets()
          .where((a) => a.startsWith('assets/avatars/mine/'))
          .toList()
        ..sort();
      if (mounted) setState(() => _mineAvatars = list);
    } catch (_) {
      // 读不到就只用生肖插画，不影响其它功能
    }
  }

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
        child: Column(
          children: [
            // ── 登录 / 账号卡：**固定在顶部**，不随下方内容滚动 ──────
            //（用户 2026-10-18：「滑动的时候登录卡片位置固定不动，其余的滑动」）
            //  我的笔记 / 阅读经历 / 阅读计划三个图标已收进这张卡的右上角，
            //  实现在 `widgets/me_account_quick_entries.dart`。
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: _buildAccountCard(isDark),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.only(
                  left: 12,
                  right: 12,
                  top: 12,
                  bottom: 8 + JellyNavBar.contentBottomAvoid,
                ),
                children: [
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
                          // 用户 2026-10-13：把「图书使用内置账号」「主题跟随系统」
                          // 两张开关卡挪到「主题风格」**前面**。
                          // 0. 图书使用内置账号
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
                                  onChanged:
                                      SettingsService().setUseBuiltinAccount,
                                ),
                              ),
                            ),
                          ),
                          // 1. 主题跟随系统
                          StaggeredEntrance(
                            key: ValueKey('${_session}_theme_follow'),
                            index: 1,
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
                                  onChanged:
                                      SettingsService().setThemeFollowSystem,
                                ),
                              ),
                            ),
                          ),
                          // 2. 主题风格
                          StaggeredEntrance(
                            key: ValueKey('${_session}_theme_style'),
                            index: 2,
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
                          // 3. 显示设置
                          StaggeredEntrance(
                            key: ValueKey('${_session}_5'),
                            index: 3,
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
                          // 4. 阅读设置
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
                          // 5. 净化规则 —— 正文净化的全局管理与导入
                          //    （用户 2026-10-25：入口应该在「我的」，不该只藏在
                          //    某本书的功能面板里）
                          StaggeredEntrance(
                            key: ValueKey('${_session}_purify'),
                            index: 5,
                            child: SizedBox(
                              width: itemWidth,
                              child: _buildMenuItem(
                                isDark,
                                icon: Icons.filter_alt_rounded,
                                iconBg: JellyTheme.primary,
                                title: '净化规则',
                                subtitle: '正文替换 · 导入 legado 规则',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const PurifyRulesPage(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 5.1 漫画源仓库 —— 服务**漫画**（SiteConfig 网页源，取图片）
                          // 与下面的「书源仓库」是两个独立体系，别合并
                          StaggeredEntrance(
                            key: ValueKey('${_session}_source_repo'),
                            index: 5,
                            child: SizedBox(
                              width: itemWidth,
                              child: _buildMenuItem(
                                isDark,
                                icon: Icons.local_mall_rounded,
                                iconBg: JellyTheme.primary,
                                title: '漫源仓库',
                                subtitle: '订阅 · 源管理',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const SourceWarehousePage(comic: true),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 6. 书源仓库 —— 服务**小说**（Legado BookSource，取文字）
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
                                icon: Icons.storefront_rounded,
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
                          // 6.1 书源仓 / 漫画仓已移到各自仓库页的**右上角图标**
                          //     （用户 2026-10-18：「不需要单独在我的页面弄」）：
                          //       · 书源仓 → 书源仓库右上角
                          //       · 漫画仓 → 漫画源仓库右上角
                          // 7. 下载设置
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
                                subtitle: '通用 · 图书 · 书源 · 漫画',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const DownloadSettingsPage(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 8. 下载记录
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
                          // 9. 阅读历程（原「浏览记录/足迹」入口，跳转不变）
                          StaggeredEntrance(
                            key: ValueKey('${_session}_browse_history'),
                            index: 9,
                            child: SizedBox(
                              width: itemWidth,
                              child: _buildMenuItem(
                                isDark,
                                icon: Icons.history_rounded,
                                iconBg: JellyTheme.primary,
                                title: '阅读历程',
                                subtitle: '漫画 & 图书阅读历史',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const BrowseHistoryPage(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 10. 阅读统计（时长 / 连续天数 / 7 天图 / 读完本数 / 书源可用率）
                          StaggeredEntrance(
                            key: ValueKey('${_session}_reading_stats'),
                            index: 10,
                            child: SizedBox(
                              width: itemWidth,
                              child: _buildMenuItem(
                                isDark,
                                icon: Icons.bar_chart_rounded,
                                iconBg: JellyTheme.primary,
                                title: '阅读统计',
                                subtitle: '时长 · 连续天数 · 7 天趋势',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ReadingStatsPage(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 10.1 阅读样式（独立样式库：内置 + 我的 + 编辑/复制/排序）
                          StaggeredEntrance(
                            key: ValueKey('${_session}_reader_styles'),
                            index: 10,
                            child: SizedBox(
                              width: itemWidth,
                              child: _buildMenuItem(
                                isDark,
                                icon: Icons.style_rounded,
                                iconBg: JellyTheme.primary,
                                title: '阅读样式',
                                subtitle: '内置 ${ReaderStyle.builtins.length} 套 · 可编辑',
                                onTap: () => _openReaderStyles(context, isDark),
                              ),
                            ),
                          ),
                          // 桌宠管理已移到「显示设置」里（用户 2026-10-18），
                          // 「我的」页不再单独占一格。
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
                          // 通用设置（软件日志 / 缓存清理 / 同步与备份）
                          StaggeredEntrance(
                            key: ValueKey('${_session}_general'),
                            index: 11,
                            child: SizedBox(
                              width: itemWidth,
                              child: _buildMenuItem(
                                isDark,
                                icon: Icons.settings_rounded,
                                iconBg: JellyTheme.primary,
                                title: '通用设置',
                                subtitle: '软件日志 · 缓存清理 · 同步与备份',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const GeneralSettingsPage(),
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
                              index: 12 + i,
                              child: SizedBox(
                                width: itemWidth,
                                child: _buildHiddenTabItem(
                                  isDark,
                                  hiddenTabs[i],
                                ),
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
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 头像（用户 2026-10-15：「选头像面板用什么素材，你去网上找相似的图标
  // 下载本地内置进去」）
  // ============================================================

  /// 内置头像数量 = 有插画素材的物种数（用户提供的 10 张生肖图）。
  ///
  /// 没有插画的物种（猫/麒麟/凤凰/朱雀/白虎/玄武等）暂不进入头像面板，
  /// 桌宠里仍可用矢量团子形态出现。
  static int get _kAvatarCount =>
      PetSpecies.all.where((e) => e.imageAsset != null).length;

  /// 没选头像时用的那款内置头像 id（`img://<speciesId>`）。
  static const String _kDefaultAvatarId = 'img://rat';

  /// 有插画素材的物种（头像面板用）
  static List<PetSpeciesInfo> get _avatarSpecies =>
      PetSpecies.all.where((e) => e.imageAsset != null).toList();

  /// 头像图（按 id）：
  ///   · '' = 默认头像；'img://<species>' = 内置生肖插画；
  ///   · 'ink://<species>' = 矢量团子（兼容旧选择）；
  ///   · 'custom' = 相册上传；
  ///   · 'aNN' = 旧版 DiceBear 素材 → 映射到同序号的内置插画。
  Widget _avatarImageFor(String id, double size, {bool logged = true}) {
    if (id == 'custom') {
      final p = SettingsService().readerAvatarPath;
      if (p.isNotEmpty) {
        final f = File(p);
        if (f.existsSync()) {
          return ClipOval(
            child: Image.file(
              f,
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
          );
        }
      }
    } else if (id.startsWith('asset://')) {
      // 内置头像素材（assets/avatars/mine/*.jpg）
      return ClipOval(
        child: Image.asset(
          id.substring(8),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _defaultAvatarIcon(size),
        ),
      );
    } else if (id.startsWith('img://')) {
      return InkPetAvatar(speciesId: id.substring(6), size: size);
    } else if (id.startsWith('ink://')) {
      return InkPetAvatar(speciesId: id.substring(7), size: size);
    } else if (id.startsWith('a')) {
      final n = int.tryParse(id.substring(1)) ?? 1;
      final list = _avatarSpecies;
      final sp = list[(n - 1) % list.length];
      return InkPetAvatar(speciesId: sp.id, size: size);
    }
    return _defaultAvatarIcon(size);
  }

  /// 当前用户选择的头像
  Widget _avatarImage(double size, {bool logged = true}) =>
      _avatarImageFor(SettingsService().readerAvatar, size, logged: logged);

  /// 默认头像：内置生肖插画（鼠），外层始终圆形裁剪。
  Widget _defaultAvatarIcon(double size) =>
      InkPetAvatar(speciesId: 'rat', size: size);

  /// 选择头像面板：拖拽条 → 「选择头像」+ 说明 → **4 列圆形网格**
  /// （首格 = 上传自定义头像，与用户给的目标样式一致）。
  Future<void> _showAvatarSheet() async {
    // 素材没加载完就打开面板时，先等一次（避免只显示生肖插画）
    await _loadMineAvatars();
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : JellyTheme.textSecondary;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.72,
        decoration: BoxDecoration(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '选择头像',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '共 ${_mineAvatars.length + _kAvatarCount} 款内置头像'
                      '（可点首张上传自定义头像）',
                      style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: sub,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListenableBuilder(
                  listenable: SettingsService(),
                  builder: (_, _) {
                    // 没选过（''）时，"当前"就是默认那款内置头像 —— 否则面板里
                    // 一个都不高亮，会让人以为"选过了但没生效"（用户 2026-10-16）
                    final cur = SettingsService().readerAvatar.isEmpty
                        ? _kDefaultAvatarId
                        : SettingsService().readerAvatar;
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 14,
                            crossAxisSpacing: 14,
                          ),
                      // 首格 = 上传；紧接着是 50 张内置插画头像；最后是生肖头像
                      itemCount: 1 + _mineAvatars.length + _kAvatarCount,
                      itemBuilder: (c, i) {
                        if (i == 0) {
                          return _avatarCell(
                            ctx: ctx,
                            isDark: isDark,
                            isUpload: true,
                            selected: false,
                          );
                        }
                        final mineIdx = i - 1;
                        if (mineIdx < _mineAvatars.length) {
                          final id = 'asset://${_mineAvatars[mineIdx]}';
                          return _avatarCell(
                            ctx: ctx,
                            isDark: isDark,
                            id: id,
                            selected: cur == id,
                          );
                        }
                        final sp = _avatarSpecies[mineIdx - _mineAvatars.length];
                        final id = 'img://${sp.id}';
                        return _avatarCell(
                          ctx: ctx,
                          isDark: isDark,
                          id: id,
                          selected: cur == id,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatarCell({
    required BuildContext ctx,
    required bool isDark,
    required bool selected,
    String id = '',
    bool isUpload = false,
  }) {
    return GestureDetector(
      onTap: () async {
        if (isUpload) {
          await _pickCustomAvatar(ctx);
        } else {
          await SettingsService().setReaderAvatar(id);
          if (ctx.mounted) Navigator.pop(ctx);
        }
      },
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : const Color(0xFFF2F3F5),
          border: Border.all(
            color: selected ? AppTheme.accentOnSurface : Colors.transparent,
            width: 2.5,
          ),
        ),
        padding: const EdgeInsets.all(2),
        child: ClipOval(
          child: isUpload
              ? Icon(
                  Icons.add_photo_alternate_outlined,
                  size: 26,
                  color: JellyTheme.textSecondary,
                )
              : _avatarImageFor(id, 64),
        ),
      ),
    );
  }

  /// 上传自定义头像：相册选图 → 复制进 App 目录 → 记路径
  Future<void> _pickCustomAvatar(BuildContext sheetCtx) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
      );
      if (picked == null) return;
      final dir = await getApplicationSupportDirectory();
      final dst = File('${dir.path}/reader_avatar.png');
      await dst.writeAsBytes(await picked.readAsBytes());
      await SettingsService().setReaderAvatar('custom', path: dst.path);
      if (sheetCtx.mounted) Navigator.pop(sheetCtx);
    } catch (_) {
      // 用户取消 / 无相册权限：静默返回，不改动原头像
      if (sheetCtx.mounted) Navigator.pop(sheetCtx);
    }
  }

  /// 「我的账号」面板（用户 2026-10-15 给的目标样式）：
  ///   头像 / 用户名 / 邮箱 → 「今日下载 N/M 本」胶囊 → 「我的账号」（单选 + 删除）
  ///   → 「添加账号」→ 说明文案 → 取消 / 退出登录。
  ///
  /// ⚠️ 只在**已登录**时弹出；未登录点账号卡仍直接进登录页。
  Future<void> _showAccountSheet() async {
    final z = ZlibraryService();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : JellyTheme.textSecondary;
    final sheetBg = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final softBg = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : const Color(0xFFF2F3F5);
    final limit = z.serverDownloadsLimit ?? ZlibraryService.loggedDailyLimit;
    final used = z.loggedCountToday;
    final email = z.email;
    final name = z.username.isNotEmpty
        ? z.username
        : (email.isNotEmpty ? email : '已登录');

    // 用户 2026-10-16：「这个弹窗我要**中间弹出**的那种」——
    // 从底部面板改成屏幕中间弹出（四角圆角 + 淡入缩放），
    // 内容超过屏高时**由内部滚动**（只限高不包滚动会把选项截断、点不到）。
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'close',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, _, __) => Center(
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.68,
            ),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: sheetBg,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 头像
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: JellyTheme.primary,
                      ),
                      child: ClipOval(child: _avatarImage(80)),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
                    if (email.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: sub),
                      ),
                    ],
                    const SizedBox(height: 16),
                    // 今日下载额度
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: softBg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.file_download_outlined,
                            size: 16,
                            color: fg,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '今日下载 $used / $limit 本',
                            style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              fontWeight: FontWeight.w600,
                              color: fg,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '我的账号',
                        style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: sub,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 当前账号（当前只支持单账号 ⇒ 常驻选中）
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.radio_button_checked_rounded,
                              size: 20,
                              color: fg,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                email.isEmpty ? name : email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: fg,
                                ),
                              ),
                            ),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () async {
                                Navigator.pop(ctx);
                                await ZlibraryService().logout();
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Icon(
                                  Icons.delete_outline_rounded,
                                  size: 20,
                                  color: sub,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    // 添加账号 → 登录页
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        Navigator.pop(ctx);
                        _push(const ZlibraryAuthPage());
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Icon(
                              Icons.add_circle_outline_rounded,
                              size: 20,
                              color: fg,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '添加账号',
                              style: TextStyle(
                                fontSize: AppTheme.fontBody,
                                color: fg,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: sub,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '退出后将回退内置账号（${ZlibraryService.builtinDailyLimit} 本/天）',
                              style: TextStyle(
                                fontSize: AppTheme.fontCaption,
                                color: sub,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.pop(ctx),
                            child: Container(
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              child: Text(
                                '取消',
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: fg,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () async {
                              Navigator.pop(ctx);
                              await ZlibraryService().logout();
                            },
                            child: Container(
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF16181D),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                '退出登录',
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? const Color(0xFF16181D)
                                      : Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, anim, _, child) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1).animate(
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      ),
    );
  }

  /// 顶部账号卡（参考目标设计）：
  ///   顶部：一条深灰装饰带，右上角放三个快捷入口（笔记 / 历程 / 计划）
  ///   左侧：圆形头像（描边 + 右下角相机角标），跨在装饰带下沿
  ///   中间：用户名（加粗）+ 小号灰字「z-library」；下一行邮箱灰字
  ///   右侧：`>` 箭头
  ///   底部：今日下载额度进度条 + 右侧「今日可下 N/N 本」
  ///     （取不到限额时整行隐藏）
  ///
  /// ── 结构 ────────────────────────────────────────────────────
  /// 单个 `Material` 卡片内用 `Stack`：底层 `Column`（灰色装饰带 + 账号信息
  /// 区），上层 `Positioned` 头像跨在色带下沿。账号信息区自带 `InkWell`
  /// （点击进登录），快捷入口在色带内、账号区外部 —— 点图标只跳目标页，
  /// 不会误触进登录。
  ///
  /// ⚠️ 账号字段（用户名 / 邮箱 / 限额）全部取自 [ZlibraryService] 的现有
  ///    状态，**取不到的字段就隐藏或退回状态文案**，绝不编造。
  Widget _buildAccountCard(bool isDark) {
    return ListenableBuilder(
      // 同时监听头像设置：在「选择头像」面板里换头像后，这张卡要立刻跟着变
      listenable: Listenable.merge([ZlibraryService(), SettingsService()]),
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

        // ── 顶部灰色装饰带（用户 2026-10-18 给的截图样式）──
        const bandHeight = 56.0;
        // 头像跨在色带下沿：值越大，头像露在色带上的部分越少
        const avatarOverlap = 32.0;
        final bandColor = isDark
            ? const Color(0xFF35373B)
            : const Color(0xFF5A5D62);
        // 下载额度进度：已用 / 总额度（0 表示今天还没下过）
        final progress = showQuota
            ? (used.clamp(0, limit) / limit).toDouble()
            : 0.0;

        // 圆形头像（描边 + 右下角相机编辑角标）
        final avatar = Stack(
          clipBehavior: Clip.none,
          children: [
            // 🔴 头像本身也可点：用户 2026-10-18 反馈
            // 「登录后的头像不能选择切换」—— 原来只有右下角
            // 那个 22px 的小相机角标能开面板，点大头像会走
            // 外层的「我的账号」，很难发现换头像的入口。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showAvatarSheet,
              child: Container(
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
                // ⚠️ 必须裁：`shape: BoxShape.circle` 只把**底色/描边**
                //    画成圆，**子级图片不会被裁** ⇒ 方形头像图会直接铺满
                //    方形区域、在圆里露出四个角（用户 2026-10-16 截图）。
                //    子级已被 decoration 按描边宽度内缩 2px，所以裁完
                //    描边仍然可见。
                clipBehavior: Clip.antiAlias,
                child: _avatarImage(60, logged: logged),
              ),
            ),
            // 相机角标（编辑头像入口）—— 点它开「选择头像」面板
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showAvatarSheet,
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
            ),
          ],
        );

        final card = Material(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── 顶部灰色装饰带：快捷入口排在色带右上角 ──
                  Container(
                    height: bandHeight,
                    padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
                    decoration: BoxDecoration(
                      color: bandColor,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                    ),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: MeAccountQuickEntries(
                        // 测试用的稳定锚点（`find.byKey`）
                        key: const ValueKey('me_account_quick_entries'),
                        isDark: isDark,
                        // 深色带上用白色系图标
                        onBand: true,
                        // 用户 2026-10-17：三个入口**各自独立**，不再共用同一页
                        onNotes: () => _push(const BookNotesPage()),
                        onJourney: () => _push(
                          const BrowseHistoryPage(showTabs: false),
                        ),
                        onPlan: () => _push(const ReadingPlanPage()),
                      ),
                    ),
                  ),
                  // ── 账号信息区：点击整块进入登录（快捷入口在色带内，不误触）──
                  InkWell(
                    // 已登录 → 弹「我的账号」面板（用户 2026-10-15 给的目标样式）；
                    // 未登录 → 直接进登录页。
                    onTap: () {
                      if (ZlibraryService().isLoggedIn) {
                        _showAccountSheet();
                      } else {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ZlibraryAuthPage(),
                          ),
                        );
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 头像用绝对定位跨在色带下沿，这里只占位
                              const SizedBox(width: 64 + 14),
                              // 账号信息：用户名 + z-library 标签 / 邮箱
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.baseline,
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
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: sub,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      secondLine,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: sub,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Icon(
                                  Icons.chevron_right_rounded,
                                  color: sub,
                                  size: 24,
                                ),
                              ),
                            ],
                          ),
                          // ── 今日下载额度进度条（用户 2026-10-18 截图样式）──
                          if (showQuota) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(99),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 6,
                                      backgroundColor: isDark
                                          ? Colors.white.withValues(alpha: 0.12)
                                          : const Color(0xFFE9EAEC),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        JellyTheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  '今日可下 $remaining/$limit 本',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontCaption,
                                    color: sub,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              // 头像：绝对定位，跨在灰色装饰带下沿（截图里的"半出头"效果）
              Positioned(
                left: 16,
                top: bandHeight - avatarOverlap,
                child: avatar,
              ),
            ],
          ),
        );

        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: card,
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

  // -------------------- 通用 --------------------

  /// 打开 QQ 群名片（带加入按钮）；未安装 QQ 则复制群号

  /// 「我的」→ 阅读样式：打开独立样式库（独立模式，点卡片设为默认阅读样式）
  Future<void> _openReaderStyles(BuildContext context, bool isDark) async {
    final store = ReaderStyleStore();
    final mine = await store.loadCustom();
    final active = await store.loadActiveId();
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderStylesPage(
          builtins: ReaderStyle.builtins,
          mine: mine,
          activeId: active,
          background: isDark
              ? const Color(0xFF14161A)
              : const Color(0xFFF6F7F9),
          foreground: isDark
              ? const Color(0xFFE7EAF0)
              : const Color(0xFF1B1F27),
          night: isDark,
          standalone: true,
        ),
      ),
    );
  }

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
                          // 标题行：左「主题风格」，右「省电」开关
                          //（用户 2026-10-15 给的目标样式：面板顶部只有 省电 一个开关，
                          //  下面两行分别是「跟随系统明暗」「系统动效」）
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
                            ],
                          ),
                          const SizedBox(height: 4),
                          _themeSwitchRow(
                            isDark: isDark,
                            icon: Icons.brightness_6_rounded,
                            title: '跟随系统明暗',
                            value: SettingsService().themeFollowSystem,
                            onChanged: switching
                                ? null
                                : (v) =>
                                      SettingsService().setThemeFollowSystem(v),
                          ),
                          _themeSwitchRow(
                            isDark: isDark,
                            icon: Icons.auto_awesome_rounded,
                            title: '系统动效',
                            subtitle: '页面转场等全局动效',
                            value: SettingsService().backgroundAnimation,
                            onChanged: switching
                                ? null
                                : (v) => SettingsService()
                                      .setBackgroundAnimation(v),
                          ),
                          const SizedBox(height: 8),
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
                                  // 预设：**全宽圆角行**（色点 + 名称 + 右侧单选圆）
                                  //（用户 2026-10-15 给的目标样式；
                                  //  原来是「一颗大圆点 + 名称」的 Wrap 网格）
                                  Column(
                                    children: [
                                      for (final p in themePresets)
                                        _buildPresetRow(
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
                                                  final sheetNav = Navigator.of(
                                                    sheetCtx,
                                                  );
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
                                    Column(
                                      children: [
                                        for (final t
                                            in SettingsService().customThemes)
                                          _buildPresetRow(
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
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _buildThemeTransferButton(
                                          isDark,
                                          Icons.input_rounded,
                                          '导入主题',
                                          _importThemes,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _buildThemeTransferButton(
                                          isDark,
                                          Icons.ios_share_rounded,
                                          '导出主题',
                                          _exportThemes,
                                        ),
                                      ),
                                    ],
                                  ),
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

  /// 一行主题（用户 2026-10-15 给的目标样式）：
  ///   **左 = 三个色点（主色 / 强调色 / 浅底），中 = 名称，右 = 单选圆**。
  ///
  /// 原来这里是"一颗 SweepGradient 四色环大圆点 + 名称"的 64 宽网格卡；
  /// 用户给了新的参考样式 ⇒ 换成全宽圆角行，7 套配色一眼扫下来更好选。
  ///
  /// 自定义主题的「编辑 / 删除」仍放在**长按菜单**（点按 = 应用主题）。
  Widget _buildPresetRow(
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
    final canEdit =
        (editable && onEdit != null) || (deletable && onDelete != null);

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
                  leading: const Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: Colors.redAccent,
                  ),
                  title: const Text(
                    '删除主题',
                    style: TextStyle(color: Colors.redAccent),
                  ),
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

    // 三个色点：主色 / 强调色 / 浅底（一眼分辨 7 套配色）
    final dots = <Color>[
      preset.palette.primary,
      preset.palette.accent,
      preset.palette.backgroundLight,
    ];
    final rowBg = selected
        ? (isDark
              ? Colors.white.withValues(alpha: 0.10)
              : const Color(0xFFEDEEF0))
        : (isDark
              ? Colors.white.withValues(alpha: 0.04)
              : const Color(0xFFF7F8FA));

    return GestureDetector(
      onTap: onTap,
      onLongPress: canEdit ? showActions : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: rowBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            for (final c in dots)
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.18)
                        : Colors.black.withValues(alpha: 0.08),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                preset.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: labelColor,
                ),
              ),
            ),
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 20,
              color: selected ? labelColor : hintColor.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }

  /// 主题面板里的一行「图标 + 标题(+副标题) + 开关」
  ///（用户 2026-10-15 给的目标样式：跟随系统明暗 / 系统动效）。
  Widget _themeSwitchRow({
    required bool isDark,
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    ValueChanged<bool>? onChanged,
  }) {
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : JellyTheme.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: sub),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: AppTheme.fontBody, color: fg),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: sub,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Transform.scale(
            scale: 0.75,
            child: Switch(value: value, onChanged: onChanged),
          ),
        ],
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

  /// 「导入 / 导出主题」次级按钮：无描边、仅浅底，视觉上弱于「新建自定义主题」。
  Widget _buildThemeTransferButton(
    bool isDark,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final fg = isDark ? Colors.white70 : JellyTheme.textPrimaryLight;
    return Material(
      color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 17),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 导出自定义主题：写一份 JSON 到 Documents + 复制到剪贴板，弹窗说明。
  Future<void> _exportThemes() async {
    final svc = SettingsService();
    if (svc.customThemes.isEmpty) {
      await _showThemeInfo('没有可导出的主题', '先在「新建自定义主题」里创建一套配色，或在编辑器里保存后重试。');
      return;
    }
    final json = svc.exportCustomThemes();
    String? savedPath;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(
        '${dir.path}/newtv_themes_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await f.writeAsString(json);
      savedPath = f.path;
    } catch (_) {
      // 写文件失败不阻断：剪贴板仍可用
    }
    try {
      await Clipboard.setData(ClipboardData(text: json));
    } catch (_) {}
    if (!mounted) return;
    await _showThemeInfo(
      '已导出 ${svc.customThemes.length} 套主题',
      savedPath == null
          ? 'JSON 已复制到剪贴板，可直接粘贴分享。'
          : 'JSON 已复制到剪贴板，并另存为：\n$savedPath',
    );
  }

  /// 导入自定义主题：优先从文件读 JSON，也可直接粘贴剪贴板内容。
  Future<void> _importThemes() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? JellyTheme.cardDark
          : JellyTheme.cardLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('从文件导入'),
              subtitle: const Text('选择 .json 主题文件'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste_rounded),
              title: const Text('粘贴 JSON'),
              subtitle: const Text('使用剪贴板中的主题 JSON'),
              onTap: () => Navigator.pop(ctx, 'clipboard'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    String? text;
    if (choice == 'file') {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
      );
      if (result.isEmpty) return;
      final path = result.first.path;
      if (path == null) return;
      try {
        text = await File(path).readAsString();
      } catch (e) {
        if (mounted) await _showThemeInfo('读取文件失败', '$e');
        return;
      }
    } else {
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        text = data?.text;
      } catch (_) {}
      if (text == null || text.trim().isEmpty) {
        if (mounted) await _showThemeInfo('剪贴板为空', '请先复制主题 JSON 再试。');
        return;
      }
    }

    if (text.trim().isEmpty) return;
    final count = await SettingsService().importCustomThemes(text);
    if (!mounted) return;
    if (count == 0) {
      await _showThemeInfo('没有可导入的主题', '内容不是有效的主题 JSON，或缺少配色字段。');
    } else {
      await _showThemeInfo('已导入 $count 套主题', '可在上方「我的自定义」列表里查看并应用。');
    }
  }

  Future<void> _showThemeInfo(String title, String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
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
