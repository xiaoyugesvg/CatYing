import 'package:flutter/material.dart';

import '../services/music_api.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import 'discover_page.dart';
import 'library_page.dart';
import 'music_bottom_chrome.dart';
import 'charts_page.dart';
import 'profile_page.dart';
import 'search_page.dart';
import '../../common/theme.dart';
import '../../services/nodejs_manager.dart';

/// 音乐模块的 App 骨架 —— 移植自 Beans 的 `RootView.swift`。
///
/// ── 结构（与 Beans 一致）──────────────────────────────────────
///   5 个 tab：主页(发现) / 搜索 / 乐库 / 榜单 / 我的
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

  /// 音乐主页是否**正挂载在树上**（供全局迷你条判断要不要让位给导航栏）。
  ///
  /// ── 🔴 为什么需要它（用户 2026 要求）──────────────────────────
  /// 用户要求「只要在播放，**每个页面**都要有迷你条」→ 迷你条移到了
  /// `app.dart` 的全局 Stack（覆盖所有路由）。
  ///
  /// 但音乐主页**本来就有**一个迷你条（它是导航栏的 Column 兄弟）。
  /// 如果不判断，主页会出现**两条**。
  ///
  /// 而且两者的纵向位置不同：
  ///   · 主页里：迷你条在导航栏**上方**（导航栏占 86）
  ///   · 子页面里：下面没有导航栏 → **贴底**
  /// 所以全局那条要按这个标记决定 `bottomInset`（0 或导航栏高度）。
  ///
  /// 用"挂载状态"而不是路由栈判断，是因为主页**不是一条路由** ——
  /// 它是 `MainTabController` 的一个 tab，压在 IndexedStack 里，
  /// 从路由栈上看不出来"现在显示的是不是它"。
  static bool isMounted = false;


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




  // 音乐底栏 = **5 项**（主页 / 搜索 / 乐库 / 榜单 / 我的）。
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
    MusicRootView.isMounted = true;
    // 进音乐 tab 就把数据预热起来（不挡界面）
    _warmUp();
  }

  @override
  void dispose() {
    // ⚠️ 必须复位：否则离开音乐后全局迷你条会一直以为"要避开导航栏"，
    //    在别的模块里露出一大截空白。
    MusicRootView.isMounted = false;
    super.dispose();
  }

  /// 预热；失败则显示重试条（原来失败是**完全静默**的，
  /// 用户进音乐页看到空白也不知道怎么回事）。
  ///
  /// 🔴 **不再用 `warmUpMusicData()`** —— 它在 `mini_player.dart` 里
  ///（那个文件你要求我不要动 ✓）。而且它只在**抛异常**时算失败，可
  /// `MusicApi._doCall` 把一切异常**吞成** `{ok:false}` 从不抛 ✗ →
  /// 它**永远返回 true** → 首页那条「点击重试」提示条是**死 UI** ✗。
  /// 改用 `hotSearchResult()`：后台未就绪/接口失败会拿到 `ok:false` ✓
  /// → 提示条能真的出现、点了也真的会重试 ✓
  Future<void> _warmUp() async {
    // 🔴 音乐数据服务跑在内嵌 Node 的 `/music/api` 上，与影视配置的
    // spider 源**无关**；但 Node 全局只在「配置里有 spider 源」时才被拉起
    //（`app_state.dart` 的 `_ensureNodeJSAndLoadSource`：
    //  `hasSpiderSource == false` 直接 return）。
    // 后果：纯 TVBox 配置（只有 CMS 采集站、没有 jar/js spider）下
    // Node 从未启动 → `managementPort <= 0` → 音乐模块一切请求直接报
    // 「后台服务未就绪」（用户实测："用 tvbox 源时音乐数据加载失败"，
    //  而 catvod 类带 spider 的配置就能用）。
    // 这里进音乐 tab 时自行确保 Node 已启动（已运行/已就绪时幂等返回）。
    if (NodeJSManager.instance.managementPort <= 0) {
      await NodeJSManager.instance.startNodeJS();
      if (!mounted) return;
    }
    final r = await MusicApi.instance.hotSearchResult();
    if (!mounted) return;
    setState(() => _warmUpFailed = !r.ok);
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
            backgroundColor: Colors.transparent,
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
                  // 🔴 **必须监听 `MusicTabState.index`**（修一个真 bug）──
                  //
                  // tab 状态在重构后从本地 `_tab` 提到了共享的
                  // `MusicTabState.index`（因为全局底栏也要读它）。
                  // 但**共享的 `ValueNotifier` 变了不会自己重建** ——
                  // 而本页外层的 `AnimatedBuilder` 只监听**主题 revision**，
                  // 与 tab 无关。
                  //
                  // 后果（用户实测反馈：「点击没反应」）：
                  //   点导航栏 → `index.value` 变了 → **没有任何 widget 重建**
                  //   → 界面停在第 1 个 tab，看起来就是"点了没反应" ✗
                  //
                  // 用 `ValueListenableBuilder` 包住 `IndexedStack`：
                  // 只有它重建（5 个子页实例仍是 `const`，不会丢状态）。
                  child: ValueListenableBuilder<int>(
                    valueListenable: MusicTabState.index,
                    builder: (context, tabIndex, _) => IndexedStack(
                      // ⚠️ key 里**不能**带 tab：`IndexedStack` 的 key 一变，
                      // 整个子树（5 个 tab 页）就被销毁重建 —— 表现是
                      // **每次切到乐库都闪一次 loading**、滚动位置与搜索词全丢，
                      // 而且子页的 `wantKeepAlive` 完全失效。
                      // tab 由 `index:` 负责，key 只需跟"主题版本"（换肤要重建）。
                      key: ValueKey(
                          'music-tabs-${MusicThemeStore.instance.revision.value}'),
                      index: tabIndex,
                      // ⚠️ 顺序必须与 `musicTabs` **严格一一对应**
                      //（主页 / 乐库 / 榜单 / 我的 / 搜索 —— 用户要求
                      //  「搜索」放在「我的」右边，见 `musicTabs` 的注释）
                      children: const [
                        DiscoverPage(),
                        LibraryPage(),
                        ChartsPage(),
                        ProfilePage(),
                        SearchPage(),
                      ],
                    ),
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
                                      color: MusicTheme.label, fontSize: AppTheme.fontSubhead),
                                ),
                              ),
                              Text('点击重试',
                                  style: TextStyle(
                                      color: MusicTheme.tint,
                                      fontSize: AppTheme.fontSubhead,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                // ⚠️ 底部两条（迷你条 + 导航栏）**已经移到全局层** ——
                // 见 `music_bottom_chrome.dart` 的 `MusicBottomChrome`，
                // 它挂在 `app.dart` 的 Stack 里，覆盖所有路由。
                // 这里**不要再画一遍**，否则主页会出现两条。
              ],
            ),
          ),
        );
      },
    );
  }
  // ⚠️ 原来的 `_navBar()` **已移出本文件** ——
  // 底栏（迷你条 + 导航栏）现在由 `music_bottom_chrome.dart` 的
  // `MusicBottomChrome` 提供，并挂在 `app.dart` 的全局 Stack 里，
  // 这样**所有路由**（含 push 出去的子页面）都能看到它们。

}

