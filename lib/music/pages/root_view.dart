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

  /// #14：预热是否失败（true 时在顶部显示"加载失败，点击重试"）
  bool _warmUpFailed = false;

  @override
  void initState() {
    super.initState();
    // 进音乐 tab 就把数据预热起来（不挡界面）
    _warmUp();
  }

  /// 预热；失败则显示重试条（原来失败是**完全静默**的，
  /// 用户进音乐页看到空白也不知道怎么回事）
  Future<void> _warmUp() async {
    final ok = await warmUpMusicData();
    if (!mounted) return;
    setState(() => _warmUpFailed = !ok);
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
                  // 🔴 #21：这里原来**没有 key，且 children 是 `const [...]`**
                  //
                  // `MusicTheme` 与 `AppTheme` 一样是**静态类**：
                  // 它的颜色 getter 读静态字段 `_isDark`/`_accent`，
                  // 改了**不会通知任何 widget**。
                  //
                  // 外层的 `AnimatedBuilder(revision)` 确实会重建，
                  // 但 `children: const [...]` 是**同一批 widget 实例** ——
                  // `Element.updateChild` 比对时判定"widget 没变"，
                  // 直接 return，**跳过 DiscoverPage 等子页的 build**。
                  //
                  // 后果（用户实测截图）：子页里的 `MusicTheme.label`
                  // 停在旧值（白字），而 `Scaffold(backgroundColor:`
                  // `MusicTheme.background)` 是直接读的、立刻变了（浅底）
                  // → **白字浅底、整页灰蒙蒙看不清**。
                  //
                  // 修法与影视侧的 `content_view.dart` 完全一致：
                  // 换 key 强制子页重建。revision 在每次主题变更时 ++，
                  // 所以拼进 key 就能让子页跟着换色。
                  child: IndexedStack(
                    key: ValueKey('music-tabs-$_tab-'
                        '${MusicThemeStore.instance.revision.value}'),
                    index: _tab,
                    children: const [
                      DiscoverPage(),
                      SearchPage(),
                      LibraryPage(),
                      ProfilePage(),
                    ],
                  ),
                ),
                // #14：预热失败提示条（可点重试）
                // 放在顶部，不遮挡底部播放器与导航栏
                if (_warmUpFailed)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: MediaQuery.of(context).padding.top + 8,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          setState(() => _warmUpFailed = false);
                          _warmUp();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: MusicTheme.fill,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.cloud_off_rounded,
                                  size: 16, color: MusicTheme.secondary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '音乐数据加载失败（可能是网络不通）',
                                  style: TextStyle(
                                      color: MusicTheme.label, fontSize: 13),
                                ),
                              ),
                              Text('点击重试',
                                  style: TextStyle(
                                      color: MusicTheme.tint,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
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
    // 🔴 #22：**不要用 `Obx` 包它**（这里踩过坑，写清楚）
    //
    // `Obx` 只有在它的 builder 内**读到了至少一个 `.obs`（Rx）变量**时才成立。
    // 而这个组件里：
    //   · `JellyNavBar` 是普通 StatefulWidget（不是 GetX 的）
    //   · `_tab` 是**普通 int**（本页用 `setState` 管理，不是 Rx）
    //   · `_tabs` 是普通 List
    // 于是 `Obx` 检测不到任何可观察变量，直接抛：
    //   "[Get] the improper use of a GetX has been detected"
    // 而 GetX 的这个异常会让**整棵 Obx 子树被换成 ErrorWidget**
    //（ErrorWidget 的高度是 100000px，表现就是"底栏不见了 + 多出一块空白"）。
    //
    // 用户实测截图："底部没有悬浮胶囊导航栏" —— 就是这条异常造成的。
    //
    // 本页是 StatefulWidget + setState，切 tab 已经会重建，
    // **不需要** Obx。直接返回即可。
    return JellyNavBar(
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
    );
  }

}

/// 供外部（如影视侧跳转）切到指定 tab
class MusicTabController {
  MusicTabController._();
  static final instance = MusicTabController._();
  final tab = ValueNotifier<int>(0);
}
