import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/floating_nav_spec.dart';
import '../../../services/main_tab_controller.dart';
import '../../reading/widgets/jelly_nav_bar.dart';
import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../widgets/mini_player.dart';
import 'root_view.dart' show MusicRootView;

/// 音乐底栏的**共享状态**（tab 选中项 + 可见性）。
///
/// ── 🔴 为什么需要它（用户 2026 要求）────────────────────────────
/// 用户要求「**每个界面**都要有迷你条 + 导航栏」。
///
/// 原来这两条是**写在 `MusicRootView` 里**的（`Positioned` 贴在它自己
/// 的 `Stack` 底部）。而音乐子页面（歌单详情 / 本地音乐 / 音源管理…）
/// 是 `Navigator.push` 上去的**整屏路由** → 把它们整个盖住 ✗。
///
/// 修法是把这两条**移到全局层**（`app.dart` 的 Stack，与悬浮播放球同层），
/// 那样一处挂载就覆盖所有路由。
///
/// 但"移出去"带来一个新问题：**tab 选中状态原本是 `MusicRootView` 的
/// 私有 `_tab`**，全局那份读不到、也改不了。所以把它提出来放这里 ——
/// `MusicRootView` 与全局底栏**共用同一份**，点哪儿都同步。
class MusicTabState {
  MusicTabState._();

  /// 当前选中的 tab（主页 / 搜索 / 乐库 / 榜单 / 我的）
  static final ValueNotifier<int> index = ValueNotifier<int>(0);

  /// 音乐模块**当前是否可见**（由 `MainTabController` 驱动）。
  ///
  /// 全局底栏只在音乐模块里显示 —— 否则看视频/读书时底部会冒出
  /// 音乐导航栏（那显然不对）。
  static bool get visible {
    final c = MainTabController.instance;
    return c.selectedTab.value == MainTabController.musicTabIndex;
  }
}

/// **音乐底部套装**：迷你播放条 + 悬浮导航栏。
///
/// 两者是**一个 `Column` 的兄弟**（迷你条在上、导航栏在下），
/// 所以调用方只需把它 `Positioned(bottom: 0)` 一次，
/// 不用分别管两条的位置 —— 这正是它们原来在 `MusicRootView` 里的关系。
///
/// ── 用法 ──────────────────────────────────────────────────────
/// 挂在 **`app.dart` 的全局 Stack** 里（覆盖所有路由）。
/// 不要在各页面里重复挂 —— 会叠出好几条。
/// 把 GetX 的 `RxInt`（`selectedTab`）桥接成 `Listenable`。
///
/// 为什么要桥：`AnimatedBuilder` 只认 `Listenable`，而 `RxInt` 不是。
/// 不用 `Obx` 是因为这里同时还要读 `MusicTabState.index`（普通
/// `ValueNotifier`）和 `MusicPlayerManager`（`ChangeNotifier`）——
/// 三者在 `Obx` 里混用容易漏通知，统一成 `AnimatedBuilder` 更可靠。
final ValueNotifier<int> _visible = ValueNotifier<int>(
  MainTabController.instance.selectedTab.value,
);
bool _bridged = false;

class MusicBottomChrome extends StatelessWidget {
  const MusicBottomChrome({super.key});

  /// 导航栏 + 迷你条 + 间距的**总高度**（给子页面留白用）。
  ///
  /// = 迷你条整条(62) + 导航栏下边距(20) + 导航栏高(66)
  /// 迷你条没在播时不会出现，但留白按"最坏情况"给，
  /// 否则一有歌底部内容就会跳一下。
  static const double totalHeight =
      MusicMiniPlayerLayout.totalHeight +
      FloatingNavSpec.bottomMargin +
      FloatingNavSpec.barHeight;

  @override
  Widget build(BuildContext context) {
    // 只监听当前 tab（音乐模块是否可见）—— 用 `AnimatedBuilder` 而不是 `Obx`：
    // `MainTabController.selectedTab` 是 Rx（`.obs`），`Obx` 能用；
    // 但这里还要读 `MusicTabState.index`（普通 ValueNotifier），
    // 混着用 `Obx` 容易漏通知，所以统一用 `AnimatedBuilder` 监听两个 Listenable。
    return AnimatedBuilder(
      // ⚠️ `MainTabController.selectedTab` 是 GetX 的 `RxInt`，
      // **不是** `Listenable` —— 直接塞进 `Listenable.merge` 会编译不过。
      // 用一个本地 `ValueNotifier` 由 `ever()` 桥接（见 `_visible`）。
      animation: Listenable.merge([
        MusicTabState.index,
        MusicPlayerManager.instance,
        // 「正在播放」是**独立**的 ValueNotifier（不是 ChangeNotifier 的通知），
        // 所以必须单独听它 —— 否则暂停后播放条不会消失。
        MusicPlayerManager.instance.isPlaying,
        _visible,
        SettingsStore.instance.bottomBarOnSubPages,
      ]),
      builder: (context, _) {
        // 懒桥接：第一次 build 时把 RxInt 的变化同步到 `_visible`
        if (!_bridged) {
          _bridged = true;
          ever(MainTabController.instance.selectedTab, (v) {
            _visible.value = v;
          });
        }
        // 不在音乐模块 → 整个不显示（看视频/读书时底部不该有音乐栏）
        if (!MusicTabState.visible) return const SizedBox.shrink();

        // ── 主页 vs 子页面（用户 2026 定稿）────────────────────────
        //
        // · **主页**（`MusicRootView` 挂着）
        //     导航栏 = 切 tab 的唯一入口 → **永远显示**
        //     播放条 = 有歌就显示（暂停也留着，方便继续播）
        // · **子页面**（push 上去的）
        //     **只有播放条**，而且**只在真的在播放时才显示** ——
        //     暂停/没歌就整条收起来，不占地方。
        //
        // ── 为什么子页面这一侧改成"仅播放中"（用户 2026 要求）────────
        // 原话：「去掉那个子页面也有悬浮导航栏呢？只是显示播放栏呢？
        //        播放的时候显示，不播放就不显示呢」
        //
        // 理由也站得住：子页面里用户已经在看内容了，再压一条导航栏
        // 既遮内容又和"返回"语义重叠；而播放条是**纯播放控制**，
        // 正在放的时候它有用，暂停了它就是多余的遮挡。
        final onRoot = MusicRootView.isMounted;
        final playing = MusicPlayerManager.instance.isPlaying.value;
        final hasSong = MusicPlayerManager.instance.currentSong != null;

        final showNavBar = onRoot;
        final showMini = onRoot
            ? hasSong
            : (SettingsStore.instance.bottomBarOnSubPages.value && playing);

        if (!showNavBar && !showMini) return const SizedBox.shrink();

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 迷你条（没歌时它自己 `SizedBox.shrink()`，不占位）
            if (showMini)
              MiniPlayer(
                // 子页面（没有导航栏）→ 紧凑贴底，别留那 26 的空档
                tightBottom: !onRoot,
                onOpen: () => openMusicPlayer(context),
              ),
            if (showNavBar) _navBar(context),
          ],
        );
      },
    );
  }

  Widget _navBar(BuildContext context) {
    return JellyNavBar(
      // ⚠️ 显式传音乐的调色板（JellyNavBar 默认用阅读的 JellyTheme，
      // 切音乐配色时那个不会变 → 音乐栏颜色错）。
      palette: MusicTheme.palette,
      currentIndex: MusicTabState.index.value,
      floating: true,
      items: [
        // 选中用 `active`、未选中用 `icon`（原来无论选中与否都传 active
        // → 等于"没有未选中态"的视觉）。
        for (var i = 0; i < musicTabs.length; i++)
          JellyNavItem(
            icon: i == MusicTabState.index.value
                ? musicTabs[i].active
                : musicTabs[i].icon,
            label: musicTabs[i].label,
          ),
      ],
      onTap: (i) {
        if (i < 0 || i >= musicTabs.length) return;
        // 切 tab 前**先退回根路由** —— 否则会在子页面（歌单详情等）
        // 之上悄悄换掉 tab，用户点完还停在子页面，看起来"点了没反应" ✗
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.popUntil((r) => r.isFirst);
        MusicTabState.index.value = i;
      },
      onLongPress: (i) {
        if (i < 0 || i >= musicTabs.length) return;
        // 长按「我的」→ 回影视（音乐是独立模块，需要一个出口）
        if (musicTabs[i].label == '我的') {
          MainTabController.instance.backToVideo();
        }
      },
    );
  }
}

/// 音乐底栏的 5 个 tab 定义（主页 / 搜索 / 乐库 / 榜单 / 我的）。
///
/// ⚠️ 放在这里（而不是 `MusicRootView` 里）是因为**全局底栏和
/// `MusicRootView` 都要用**，而且必须**顺序一致** ——
/// 两处各写一份一旦不同步，tab 就会错位。
///
/// ⚠️ 5 项时每个格子变窄 → 标签都控制在 **2~3 个汉字**。
const musicTabs = <({String label, IconData icon, IconData active})>[
  (label: '主页', icon: Icons.home_outlined, active: Icons.home_rounded),
  (label: '搜索', icon: Icons.search_rounded, active: Icons.search_rounded),
  (
    label: '乐库',
    icon: Icons.library_music_outlined,
    active: Icons.library_music_rounded,
  ),
  (
    label: '榜单',
    icon: Icons.leaderboard_outlined,
    active: Icons.leaderboard_rounded,
  ),
  (
    label: '我的',
    icon: Icons.person_outline_rounded,
    active: Icons.person_rounded,
  ),
];
