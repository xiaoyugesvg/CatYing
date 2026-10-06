import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/floating_nav_spec.dart';
import '../../../services/main_tab_controller.dart';
import '../../reading/widgets/jelly_nav_bar.dart';
import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../widgets/mini_player.dart';
import 'player_page.dart' show MusicPlayerPage;
import '../services/route_observer.dart';
import '../../widgets/video_player_pip.dart';

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
  ///
  /// ── 🔴 为什么加了 `Get.isRegistered` 守卫（修一个潜在崩溃）──────────
  /// 原来直接 `MainTabController.instance`（内部是 `Get.find`）——
  /// **没注册时抛** `"MainTabController" not found`（GetX 的异常），
  /// 而抛出位置在 `build()` 里 → **整条底栏（播放条 + 导航栏）崩掉** ✗
  ///
  /// 真机上 `main.dart` 会先 `Get.put(MainTabController(), permanent: true)`，
  /// 所以平时看不到；但这是**隐式的初始化顺序依赖**：
  ///   · 单测里 pump 一下 `MusicBottomChrome` 就炸（实测确认过）
  ///   · 将来若有人调启动顺序、或某个更早的入口提前 build 到它，
  ///     就会直接崩，而且报的是"找不到控制器"这种**和底栏毫不相干**
  ///     的信息，极难定位
  ///
  /// 没注册时**当作"不在音乐模块"**（false → 底栏不显示）——
  /// 比崩掉合理得多：它本来就不该在"还没初始化完"的时候显示。
  static bool get visible {
    // ⚠️ 不能直接写 `MainTabController.instance` —— 未注册时它会抛
    if (!Get.isRegistered<MainTabController>()) return false;
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
///
/// ── 🔴 初值不能直接读 `MainTabController.instance`（修一个崩溃）──────
/// 原来写的是：
/// ```dart
/// final ValueNotifier<int> _visible =
///     ValueNotifier<int>(MainTabController.instance.selectedTab.value);
/// ```
/// 这是**文件级顶层变量** —— 它的初始化在**第一次被读到**时执行，
/// 而那一刻 `MainTabController` 可能**还没注册**（`Get.find` 抛
/// `"MainTabController" not found`）→ `MusicBottomChrome.build` 直接炸 ✗
/// （实测：单测里 pump 一下就复现；真机靠 `main.dart` 的注册顺序侥幸没事）
///
/// 现在未注册时用 `-1`（"不在任何音乐 tab"）——
/// 反正后面 `_bridged` 那段 `ever()` 会把真实值同步进来。
final ValueNotifier<int> _visible = ValueNotifier<int>(
  Get.isRegistered<MainTabController>()
      ? MainTabController.instance.selectedTab.value
      : -1,
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
        // 全屏播放器开/关 —— 它开着时本组件整个隐藏（见下面那段）
        MusicPlayerPage.isOpen,
        // 路由深度 —— 它变了才知道"进/出子页面"（见 `onRoot` 的说明）
        MusicRouteObserver.pushedCount,
      ]),
      builder: (context, _) {
        // ── 懒桥接：把 RxInt 的变化同步到 `_visible` ──────────────────
        //
        // ⚠️ 必须判 `Get.isRegistered`：`ever(...)` 的第一个参数要先求值
        //    `MainTabController.instance`（`Get.find`）——
        //    **未注册时它会抛**，而这里在 `build` 里 → 底栏整个炸 ✗
        //    （实测：单测里 pump 一下就复现）
        //
        // 未注册时**不桥接**：`_visible` 保持初值 -1 →
        // `MusicTabState.visible` 走的是…… 见下面那个 getter（它也判了），
        // 总之底栏不显示，而不是崩。
        if (!_bridged &&
            Get.isRegistered<MainTabController>()) {
          _bridged = true;
          ever(MainTabController.instance.selectedTab, (v) {
            _visible.value = v;
          });
        }
        // 不在音乐模块 → 整个不显示（看视频/读书时底部不该有音乐栏）
        if (!MusicTabState.visible) return const SizedBox.shrink();

        // ── 🔴 全屏播放器开着时**整个隐藏**（修一个"播放器被盖住"）──────
        //
        // 本组件挂在 `app.dart` 的 Stack 里、**在 `out`（Navigator）之后**
        // → 盖在**所有**路由之上，包括全屏播放器。
        //
        // 而播放器**自己**有一条底部操作栏（`_bottomBar()`：
        // 列表循环 / 收藏 / 上一首 / 歌词 / 下一首 / 设置）——
        // 被迷你条 + 导航栏压在下面，**既看不清也点不到** ✗
        //（用户实测截图：`列表循环 收藏 上一首 歌词 下一首 设置` 全被盖住）
        //
        // 而且导航栏出现在播放器上本身**语义就不对**：播放器是全屏模态页，
        // 底部该是"播放控制"，不是"切模块 tab"。
        if (MusicPlayerPage.isOpen.value) return const SizedBox.shrink();

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
        // ── 🔴 用**路由深度**判断"根页面 vs 子页面"（修一个真 bug）──────
        //
        // 原来写的是 `MusicRootView.isMounted` —— **它永远为 true** ✗：
        // `MusicRootView` 挂在 `ContentView` 的 `IndexedStack` 里，
        // `IndexedStack` 会让**所有**子页保持挂载，push 子页面时
        // 根视图仍在树里 → `dispose` 永远不调用 → 标记永远 true。
        //
        // 后果（用户实测反馈「关闭了子页面浮动导航栏结果还是不行」）：
        //   · 「子页面显示播放条」开关关掉，**子页面照样有导航栏** ✗
        //   · push 出来的全屏播放器上也画着导航栏 ✗
        //
        // `MusicRouteObserver.isOnRoot` 读的是**导航器真实的路由栈深度**，
        // 这才是"在不在根页面"的正解。见 `route_observer.dart` 的说明。
        final onRoot = MusicRouteObserver.isOnRoot;
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
                // ⚠️ **不能**用 `openMusicPlayer(context)`：本组件在
                //    Navigator 子树之外，`Navigator.of(context)` 会抛。
                //    走全局 navigatorKey（与悬浮球的 `_openPlayer` 同款）。
                onOpen: _openPlayerFromGlobalKey,
              ),
            if (showNavBar) _navBar(),
          ],
        );
      },
    );
  }

  /// 打开全屏播放器 —— **用全局 `navigatorKey`**，不用本组件的 `context`。
  ///
  /// 原因同 `_navBar` 里 `onTap` 的注释：本组件在 Navigator 子树之外。
  /// 与 `floating_play_button.dart` 的 `_openPlayer` 完全一致。
  void _openPlayerFromGlobalKey() {
    final nav = VideoPlayerPip.navigatorKey.currentState;
    if (nav == null) return;
    nav.push<void>(
      MaterialPageRoute(builder: (_) => const MusicPlayerPage()),
    );
  }

  /// 音乐底部导航栏。
  ///
  /// ── ⚠️ 这个函数**故意不接收 `BuildContext`**（别加回去）──────────
  /// 本组件挂在 `app.dart` 的 Stack 里、`out`（Navigator 子树）**之外**，
  /// 所以它拿到的任何 `context` 祖先链里**都没有 Navigator**。
  ///
  /// 之前它收了 `context` 并在里面写了 `Navigator.of(context)` ——
  /// 那个调用**必然抛异常**，表现就是"整条导航栏点了没反应" ✗
  ///（用户实测反馈过这个现象）。
  ///
  /// 现在一律走全局 `VideoPlayerPip.navigatorKey`（见 `onTap`）。
  /// **不收 `context` 是为了让"这里能用 context"这种误判无从下手。**
  Widget _navBar() {
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
        //
        // ── 🔴 必须用全局 `navigatorKey`，**不能用 `Navigator.of(context)`** ──
        //
        // 本组件挂在 `app.dart` 的 Stack 里、`out`（Navigator 子树）
        // **之外** → 它的 `context` 祖先链里**没有 Navigator**，
        // `Navigator.of(context)` 会抛异常 → **整条导航栏点了没反应** ✗
        //
        // 这与 `floating_play_button.dart` / `AppToast` 的约定一致
        //（那边注释写得很清楚："必须用全局 navigatorKey 来 push"）。
        final nav = VideoPlayerPip.navigatorKey.currentState;
        if (nav != null && nav.canPop()) {
          nav.popUntil((r) => r.isFirst);
        }
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
  // ── ⚠️ 顺序必须与 `root_view.dart` 的 `IndexedStack.children` **严格一一对应** ──
  //
  // 用户 2026 要求：**「搜索」放到「我的」右边**。
  // 所以现在是：主页 / 乐库 / 榜单 / 我的 / 搜索
  //   （原来「搜索」在第二位，紧挨主页）
  //
  // ⚠️ 长按「我的」回影视是按 **label** 判断的（`musicTabs[i].label == '我的'`），
  //    不是按索引 → 换位置不会影响它。
  (label: '主页', icon: Icons.home_outlined, active: Icons.home_rounded),
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
  (label: '搜索', icon: Icons.search_rounded, active: Icons.search_rounded),
];
