import 'package:flutter/material.dart';

import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../../common/floating_nav_spec.dart';
import '../../services/main_tab_controller.dart';
import '../theme/music_theme.dart';
import '../widgets/mini_player.dart';
import 'discover_page.dart';
import 'library_page.dart';
import 'profile_page.dart';
import 'search_page.dart';

/// 音乐模块的 App 骨架 —— 移植自 Beans 的 `RootView.swift`。
///
/// ── 结构（与 Beans 一致）──────────────────────────────────────
///   4 个 tab：主页(发现) / 搜索 / 音乐库 / 我的
///   底部自绘悬浮导航栏（Beans 旧系统走自绘胶囊底栏）
///   迷你播放器**浮在导航栏之上**，有正在播放的歌才显示
///
/// ── 为什么自绘导航栏 ─────────────────────────────────────────
/// Beans 用的是系统 TabView + accessory；猫影自己已有悬浮栏视觉
/// （`JellyNavBar` 风格），这里保持同样手感，也方便把迷你播放器
/// 叠在栏上方。
///
/// ⚠️ 本模块**完全独立**：自己的主题（MusicTheme）、自己的播放器
/// （MusicPlayerManager）、自己的设置（SettingsStore），
/// 不与影视侧共用任何状态。
class MusicRootView extends StatefulWidget {
  const MusicRootView({super.key});

  @override
  State<MusicRootView> createState() => _MusicRootViewState();
}

/// 悬浮导航栏规格 —— 与阅读 `JellyNavBar` 保持一致。
///
/// 这两个值必须和 `lib/reading/widgets/jelly_nav_bar.dart` 里的
/// `floatingBarHeight` / `_floatingRadius` 相同，否则音乐和阅读的
/// 悬浮栏看起来是两个不同组件（用户要求统一成阅读那种）。
/// 以后改阅读的圆角，这里要跟着改。
const double _floatingBarHeight = FloatingNavSpec.barHeight;
const double _floatingRadius = FloatingNavSpec.radius;

class _MusicRootViewState extends State<MusicRootView> {
  int _tab = 0;

  static const _tabs = <({String label, IconData icon, IconData active})>[
    (label: '主页', icon: Icons.home_outlined, active: Icons.home_rounded),
    (label: '搜索', icon: Icons.search_rounded, active: Icons.search_rounded),
    (
      label: '音乐库',
      icon: Icons.library_music_outlined,
      active: Icons.library_music_rounded,
    ),
    (
      label: '我的',
      icon: Icons.person_outline_rounded,
      active: Icons.person_rounded,
    ),
  ];
  // 音乐底栏 = **4 项**（主页 / 搜索 / 音乐库 / 我的）。
  //
  // 原先第 5 项是「影视」—— 它不是本模块的 tab，只是"跳出音乐"的入口：
  // 永远不高亮、点了行为与别人不同，本质上是个假 tab。
  // 用户要求改为**长按「我的」**回影视（见下方 onLongPress）：
  // 既不占底栏位置、也不会误触，底栏回到 4 项的干净形态。
  //
  // 阅读那边同理：5 项（漫画/图书/书架/收藏/我的），长按「我的」回影视。

  @override
  void initState() {
    super.initState();
    // 进音乐 tab 就把数据预热起来（失败静默，不挡界面）
    warmUpMusicData();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // 主题切换（强调色/明暗）要立刻反映到整个音乐模块
      animation: Listenable.merge([
        MusicThemeStore.instance.revision,
        SettingsStore.instance.audioQuality,
      ]),
      builder: (context, _) {
        return Theme(
          data: MusicTheme.themeData(),
          child: Scaffold(
            backgroundColor: MusicTheme.background,
            body: Stack(
              children: [
                // tab 内容（用 IndexedStack 保留各页滚动位置）
                Positioned.fill(
                  child: IndexedStack(
                    index: _tab,
                    children: const [
                      DiscoverPage(),
                      SearchPage(),
                      LibraryPage(),
                      ProfilePage(),
                    ],
                  ),
                ),
                // 底部：迷你播放器 + 悬浮导航栏
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedBuilder(
                        animation: MusicPlayerManager.instance,
                        builder: (context, _) {
                          if (MusicPlayerManager.instance.currentSong == null) {
                            return const SizedBox.shrink();
                          }
                          return MiniPlayer(
                            onOpen: () => openMusicPlayer(context),
                          );
                        },
                      ),
                      _navBar(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _navBar() {
    // ── 底部安全区与悬浮间距（这里踩过坑，写清楚）──────────────────
    // 正确顺序是 **SafeArea 包在外，悬浮间距在里**：
    //     SafeArea(bottom: true) → Padding(bottom: 30) → 胶囊
    // 这样胶囊离屏幕底边 = Home 指示条高度 + 30，视觉上是"悬浮"的。
    //
    // ❌ 之前的写法是 Container(margin: bottom 8) → SafeArea(bottom: true)，
    //    间距只有 8px，胶囊紧贴 Home 指示条，
    //    看起来像"没做安全区适配"，而不是悬浮栏。
    //    阅读模块的 JellyNavBar 一直是对的（SafeArea 在外 + 30px），
    //    这里对齐它，两条栏手感才一致。
    return SafeArea(
      top: false,
      bottom: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(FloatingNavSpec.sideMargin, 0,
            FloatingNavSpec.sideMargin, FloatingNavSpec.bottomMargin),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: FloatingNavSpec.innerPadH,
              vertical: FloatingNavSpec.innerPadV),
          decoration: BoxDecoration(
            // ── 对齐阅读 JellyNavBar 的悬浮胶囊规格 ──────────────
            // 圆角 32（原 22）、高 72、白底 95%、阴影 blur 12 / offset(0,4)。
            // 数值照抄 `JellyNavBar._floatingRadius`、`floatingBarHeight`
            // 与它 Container 的 decoration，目的是让音乐和阅读的悬浮栏
            // 看起来像同一个组件（用户要求"所有悬浮菜单栏按阅读的来"）。
            //
            // 同时**去掉原来那圈 0.5px 边框**：阅读栏没有边框，
            // 它是靠阴影 + 半透明底和背景分离的；多一圈边框会显得更"硬"。
            color: FloatingNavSpec.barColor(
                MusicTheme.isDark, MusicTheme.palette),
            borderRadius: BorderRadius.circular(_floatingRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black
                    .withValues(alpha: FloatingNavSpec.shadowAlpha),
                blurRadius: FloatingNavSpec.shadowBlur,
                offset: FloatingNavSpec.shadowOffset,
              ),
            ],
          ),
          child: SizedBox(
            // 高度对齐阅读的 72（减掉上下各 6 的 padding）
            height: _floatingBarHeight - FloatingNavSpec.innerPadV * 2,
            child: Row(
              children: List.generate(_tabs.length, (i) {
                final t = _tabs[i];
                final active = i == _tab;
                // 最后一个（影视）是"跳出去"而不是本模块的 tab ——
                // 它永远不高亮，点了就切到影视主 tab。
                return Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _tab = i),
                    // 长按「我的」= 返回影视。
                    // 为什么用长按而不是加第 6 项：见 _tabs 上方的注释 ——
                    // 音乐是独立模块，影视底栏在这里被隐藏，需要一个出口；
                    // 但加 tab 会改变底栏外观，与截图不符。
                    onLongPress: t.label == '我的'
                        ? () => MainTabController.instance.backToVideo()
                        : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                          vertical: FloatingNavSpec.itemPadV),
                      decoration: BoxDecoration(
                        // 选中底色也走规格（与阅读/影视同一套 alpha/圆角）
                        color: active
                            ? FloatingNavSpec.selectedItemBg(
                                MusicTheme.isDark, MusicTheme.palette)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(
                            FloatingNavSpec.itemRadius),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            active ? t.active : t.icon,
                            size: FloatingNavSpec.iconSize,
                            // 取色规则与阅读/影视完全一致 ——
                            // 用户要求三条栏"颜色要和阅读一样"。
                            color: active
                                ? FloatingNavSpec.selectedColor(
                                    MusicTheme.isDark, MusicTheme.palette)
                                : FloatingNavSpec.unselectedColor(
                                    MusicTheme.isDark, MusicTheme.palette),
                          ),
                          const SizedBox(
                              height: FloatingNavSpec.iconLabelGap),
                          Text(
                            t.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: FloatingNavSpec.labelSize,
                              // 三条栏统一 w600（原来未选中是 w400，
                              // 看起来比另两条栏"细"，也是不一致的一种）
                              fontWeight: FloatingNavSpec.labelWeight,
                              color: active
                                  ? FloatingNavSpec.selectedColor(
                                      MusicTheme.isDark, MusicTheme.palette)
                                  : FloatingNavSpec.unselectedColor(
                                      MusicTheme.isDark, MusicTheme.palette),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// 供外部（如影视侧跳转）切到指定 tab
class MusicTabController {
  MusicTabController._();
  static final instance = MusicTabController._();
  final tab = ValueNotifier<int>(0);
}
