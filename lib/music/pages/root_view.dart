import 'package:flutter/material.dart';

import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../../services/main_tab_controller.dart';
import '../theme/music_theme.dart';
import '../widgets/mini_player.dart';
import 'discover_page.dart';
import 'library_page.dart';
import 'profile_page.dart';
import 'search_page.dart';
import '../../reading/widgets/jelly_nav_bar.dart';
import 'package:get/get.dart';

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
  /// 音乐底部栏 —— **直接复用阅读的 `JellyNavBar`**（用户要求以阅读为基准）。
  ///
  /// ── 为什么不再自己画一遍 ──────────────────────────────────────
  /// 这里原来是手写的胶囊（Container + 阴影 + Row + AnimatedContainer），
  /// 于是只有"背景色淡入"（180ms），而阅读那边有：
  ///   · **果冻弹性滑动指示器**（850ms ElasticOutCurve）
  ///   · **毛玻璃模糊**（背景动画关闭时的 BackdropFilter）
  /// 现在直接复用组件：一次拿到指示器 + 毛玻璃 + 自适应宽度，
  /// 而且以后改一处三条栏一起变。
  ///
  /// 保留音乐特有的：**长按「我的」回影视** ——
  /// 音乐是独立模块，影视底栏在这里被隐藏，需要一个出口。
  Widget _navBar() {
    return Obx(() => JellyNavBar(
          // ⚠️ 显式传音乐的调色板（JellyNavBar 默认用阅读的 JellyTheme，
          // 切音乐配色时那个不会变 → 音乐栏颜色错）。
          palette: MusicTheme.palette,
          currentIndex: _tab,
          floating: true,
          items: [
            for (final t in _tabs)
              JellyNavItem(icon: t.active, label: t.label),
          ],
          onTap: (i) {
            if (i < 0 || i >= _tabs.length) return;
            setState(() => _tab = i);
          },
          onLongPress: (i) {
            if (i < 0 || i >= _tabs.length) return;
            if (_tabs[i].label == '我的') {
              MainTabController.instance.backToVideo();
            }
          },
        ));
  }

}

/// 供外部（如影视侧跳转）切到指定 tab
class MusicTabController {
  MusicTabController._();
  static final instance = MusicTabController._();
  final tab = ValueNotifier<int>(0);
}
