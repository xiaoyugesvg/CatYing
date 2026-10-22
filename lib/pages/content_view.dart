import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../common/theme.dart';
import '../common/constants.dart';
import '../services/app_state.dart';
import '../services/app_log.dart';
import 'home/view.dart';
import 'shelf/view.dart';
import '../reading/widgets/jelly_nav_bar.dart';
import '../services/api_config.dart';
import '../services/nav_feature_service.dart';
import '../services/prefs_mirror.dart';
import 'live/view.dart';
import '../reading/pages/home_page.dart' as reading_app;
import '../music/pages/root_view.dart';
import '../miniapp/pages/mini_app_list_page.dart';
import '../hiker/pages/hiker_home_page.dart';
import '../emby/emby_home_page.dart';
import '../rss/pages/rss_page.dart';
import 'drama/view.dart';
import '../room/room_home_page.dart';
import 'settings/view.dart';
import 'search/view.dart';
import 'search/controller.dart';
import 'settings/controller.dart';
import '../services/detail_page_controller.dart';
import '../services/player_fullscreen_controller.dart';
import '../widgets/disclaimer_dialog.dart';
import '../widgets/app_loading_view.dart';
import '../services/main_tab_controller.dart';

/// 主内容视图 - 对应 Swift ContentView
/// 管理三种状态：设置页 / 加载页 / 主页
class ContentView extends StatefulWidget {
  const ContentView({super.key});

  @override
  State<ContentView> createState() => _ContentViewState();
}

class _ContentViewState extends State<ContentView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // int _selectedTab 已迁移到 MainTabController.selectedTab (全局共享)

  /// 主 tab 切换时的左右平移（用户 2026-10-20：「页面切换不能左右平移么」）。
  ///
  /// ⚠️ 不能用 PageView：这里 12 个页面都靠 IndexedStack **保活**（滚动位置、
  ///   已加载列表、阅读子 tab 等），改成 PageView 会把非相邻页销毁。
  ///   所以保留 IndexedStack 只做「整页滑入」动画：动画只改位移，
  ///   不碰子树，Element/State 全部复用。
  late final AnimationController _tabSlideCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  double _tabSlideFrom = 0;
  int _lastTabIndex = MainTabController.instance.selectedTab.value;

  /// 启动最多等 3 秒：不管配置加载成功、失败还是超时，到点直接进主界面，
  /// 配置继续在后台加载（用户 2026-10-18）。
  static const Duration _kMaxStartupWait = Duration(seconds: 3);
  bool _forceEntered = false;
  Timer? _enterTimer;

  bool _showSearch = false;
  // 防止 ever() 回调重入 - 在回调内部清空 pendingSearchKeyword 时会再次触发 ever()
  bool _isProcessingSearchKeyword = false;

  // 搜索控制器
  TvSearchController? _searchVM;

  /// 上一次 lifecycle state (用于记录 from→to 转换)
  AppLifecycleState? _lastLifecycleState;
  DateTime? _lastLifecycleChangeAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 3 秒硬上限：到点无条件进主界面，配置加载继续在后台跑
    _enterTimer = Timer(_kMaxStartupWait, () {
      if (!mounted) return;
      setState(() => _forceEntered = true);
    });
    // 主题模式（含「跟随系统」）已在 main() 启动时从 prefs 加载，
    // 这里不再用 BackgroundService.appearanceMode 覆盖 ——
    // 旧逻辑每次冷启动都会把 'system' 覆盖成 dark/light（跟随系统丢失）。
    _searchVM = Get.find<TvSearchController>();
    Get.put(SettingsController());
    // tab 切换 → 记录方向并播放一次「滑入」动画（向右切页从右侧进，反之从左侧）
    ever(MainTabController.instance.selectedTab, (int index) {
      if (index == _lastTabIndex) return;
      _tabSlideFrom = index > _lastTabIndex ? 1.0 : -1.0;
      _lastTabIndex = index;
      _tabSlideCtrl.forward(from: 0);
    });
    // 对应 Swift: .onChange(of: appState.pendingSearchKeyword)
    // 使用 ever 监听 pendingSearchKeyword 变化，触发搜索 overlay
    // 注意: 在回调内部清空 pendingSearchKeyword 会再次触发 ever()，必须用 guard 防止重入
    final appState = Get.find<AppState>();
    ever(appState.pendingSearchKeyword, (String? keyword) {
      // 防止重入: 清空 pendingSearchKeyword.value = null 会再次触发此回调
      if (_isProcessingSearchKeyword) return;
      if (keyword != null && keyword.isNotEmpty && mounted) {
        _isProcessingSearchKeyword = true;
        _searchVM?.keyword.value = keyword;
        // 清空 pendingSearchKeyword，对应 Swift: appState.pendingSearchKeyword = nil
        appState.pendingSearchKeyword.value = null;
        setState(() {
          _showSearch = true;
        });
        _isProcessingSearchKeyword = false;
        // 对应 Swift: 延迟搜索到下一帧，避免在 build 阶段触发 setState
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchVM?.search();
        });
      }
    });
    _loadSavedConfig();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _enterTimer?.cancel();
    _tabSlideCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 对应 Swift onChange(of: scenePhase) - 应用恢复前台时检查服务
    final from = _lastLifecycleState;
    final now = DateTime.now();
    final prevAt = _lastLifecycleChangeAt;
    final sincePrevMs = prevAt == null
        ? null
        : now.difference(prevAt).inMilliseconds;

    AppLog.instance.lifecycle(
      'didChange',
      from: from,
      to: state,
      source: 'ContentView',
      fields: {
        'isConfigLoaded': Get.find<AppState>().isConfigLoaded.value,
        if (sincePrevMs != null) 'sincePrevMs': sincePrevMs,
      },
    );

    _lastLifecycleState = state;
    _lastLifecycleChangeAt = now;

    // 进后台/失活时立刻落一份设置快照：崩溃/被系统回收时最多丢这一次之后的改动。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(PrefsMirror.snapshot());
    }

    if (state == AppLifecycleState.resumed) {
      final appState = Get.find<AppState>();
      AppLog.instance.lifecycle(
        'trigger_handleSceneActive',
        to: state,
        source: 'ContentView.resumed',
        fields: {
          'reason': 'AppLifecycleState.resumed → handleSceneActive',
        },
      );
      appState.handleSceneActive();
    }
  }

  /// 系统内存告警（iOS 的 `didReceiveMemoryWarning`）。
  ///
  /// ── 为什么补这个（2026-10-14）────────────────────────────────
  /// 全项目原来**零处**实现它。本 App 同时挂着 Node + CPython + FFmpeg/KSPlayer，
  /// 内存压力本来就大；系统发警告时我们不主动放掉任何东西 ⇒ 更容易被
  /// Jetsam 强杀（强杀时连生命周期回调都没有）。
  /// 这里只做**最可控**的一件事：清 Flutter 自己的图片解码缓存 ——
  /// 它可随时重新解码（`Image.file` 的源文件仍在），代价只是正在显示的图
  /// 短暂重载；却能立刻腾出最大一块可控内存。
  /// ⚠️ 刻意**不**清 `cmbok_blob_temp` 临时文件：漫画阅读中的章节图就来自那里，
  ///    删了会当场变成破图（那是"缓存"但不能随手删）。
  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    try {
      final cache = PaintingBinding.instance.imageCache;
      final before = cache.currentSizeBytes;
      cache.clear();
      cache.clearLiveImages();
      AppLog.instance.log('[内存压力] 已清理图片缓存（释放前 $before 字节）');
    } catch (e) {
      AppLog.instance.w('[内存压力] 清理图片缓存失败: $e');
    }
  }

  /// 对应 Swift onAppear - 加载已保存的配置
  ///
  /// 用户 2026-10-18：
  ///   · 不再渲染首次启动的「接口配置」页，直接进主界面；
  ///   · 有已保存地址就**后台**加载，最多等 3 秒（见 [_kMaxStartupWait]）。
  Future<void> _loadSavedConfig() async {
    var savedVodUrl = AppState.startupSavedApiUrl.trim();
    if (savedVodUrl.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      savedVodUrl = prefs.getString(AppConstants.apiUrl) ?? '';
      // prefs 丢了就用手写那份文件备份兜底（防"重启又要重新填源"）
      savedVodUrl = await ApiConfig.restoreApiUrlIfLost(savedVodUrl);
    }
    if (!mounted || savedVodUrl.isEmpty) return;

    final appState = Get.find<AppState>();
    await appState.loadConfig(vodUrl: savedVodUrl);
  }

  @override
  Widget build(BuildContext context) {
    final appState = Get.find<AppState>();

    return Obx(() {
      // 启动三态：
      //   ① 配置已就绪 → 主界面
      //   ② 还没就绪 → 加载页（最多 3 秒）
      //   ③ 3 秒到 → 无论成功/失败/仍加载中，都直接进主界面，
      //      配置继续在后台加载（用户 2026-10-18）
      //
      // 首次启动不再渲染「接口配置」页：没有地址也直接进软件，
      // 线路统一到「设置 → 订阅管理」里添加并激活。
      final Widget currentChild =
          (appState.isConfigLoaded.value || _forceEntered)
          ? _buildMainTabView()
          : _buildLoadingView();

      return Stack(
        children: [
          currentChild,
          // 对应 Swift: .overlay(alignment: .top) { networkStatusBanner }
          _buildNetworkStatusBanner(),
        ],
      );
    });
  }

  // ============================================================
  // 加载视图 - 对应 Swift loadingView
  // ============================================================

  /// 圆形进度 + 中心 Logo（猫影）
  Widget _buildLoadingView() {
    return const AppLoadingView();
  }

  // ============================================================
  // 主标签视图 - 对应 Swift mainTabView
  // ============================================================

  /// 音乐 / 阅读在 IndexedStack 里的下标。
  ///
  /// 这两个模块**自带导航栏**，所以影视底栏要在它们选中时隐藏
  /// （否则两条栏重叠 —— 用户实测反馈过）。
  /// 写成常量而不是散落的字面量 5/6，改 tab 顺序时不容易漏。

  /// 上一次生成 tab 页实例用的"外观签名"（明暗 + 配色版本）
  String? _tabSig;
  List<Widget>? _tabPagesCache;

  /// 构造 7 个 tab 页实例。
  ///
  /// ── ⚠️ 为什么必须"按外观签名换新实例"，而不是 const 字段 ──────────
  ///
  /// `AppTheme` 是静态类，颜色 getter 读 `AppBrightness.isLight` / `_palette`，
  /// 改了**不会通知任何 widget**。若这些页面是 `const` 实例，IndexedStack
  /// 重建时 Flutter 在 `Element.updateChild` 里判定
  /// `child.widget == newWidget`（同一个规范化实例）→ **直接跳过子页 build**
  /// → 子页停在旧颜色（"切了外观但筛选背景没变"）。
  ///
  /// 旧实现是靠给 IndexedStack 换 key 强制重建来解决的，但那是**销毁重建**：
  /// 7 个 tab 的 State（阅读的子 tab、滚动位置、已加载列表）全部丢失 ——
  /// 用户实测"在阅读里切个明暗，阅读就跳回默认首页"。
  ///
  /// 现在改成"新实例 + 不换 key"：`updateChild` 看到 widget 变了会走
  /// `update()` → 子页**重建**；而 runtimeType / 位置 / key 都没变 →
  /// Element 与 State **复用**。于是颜色刷新、状态不丢。
  ///
  /// 缓存的意义：只在"明暗或配色真的变了"时换新实例；其它重建
  /// （切 tab、网络刷新等）继续复用同一批实例，避免每次都白重建 7 个大页面。
  List<Widget> _tabPages(String sig) {
    if (_tabSig != sig || _tabPagesCache == null) {
      _tabSig = sig;
      // 这里**故意不写 const**（写了就会被规范化成同一实例，子页又不重建了）
      _tabPagesCache = <Widget>[
        HomePage(),
        // 「史藏」= 历史 + 收藏（统一页，顶部 tab 切换）
        ShelfPage(),
        ShelfPage(), // 占位：索引 2 保留结构避免下标错乱
        SettingsPage(),
        // 直播作为第 5 个 tab（选中才高亮，修复"首页+直播同时高亮"）
        LivePage(),
        // 音乐（索引 5）—— 按 Beans-Music 的 4-tab 结构重绘
        // （主页/搜索/音乐库/我的 + 迷你播放器 + 全屏播放器）
        MusicRootView(),
        // 阅读（索引 6）—— 完整移植 cmbok_app 的 5-tab 应用
        // （漫画 / 图书 / 书架 / 收藏 / 我的），内含它自己的导航栏与主题体系
        reading_app.HomePage(),
        // 程序（索引 7）—— 独立「小程序」模块（TVBox 配置：影视 + 直播）
        const MiniAppListPage(),
        // RSS（索引 8）—— 订阅源阅读（Legado RSS 源 / 标准 RSS / OPML；
        // 见 lib/rss/）。用户 2026-10-15 要求"直接加个 RSS 分类"
        const RssPage(),
        // 海阔（索引 9）—— 海阔视界(hiker/hipy)小程序规则模块（见 lib/hiker/）。
        // 独立于「程序」里的 TVBox 小程序体系；默认不进底栏，
        // 用户在「设置 → 主页页面」里自行开启。
        const HikerHomePage(),
        // Emby（索引 10）—— 自建媒体库（电影 / 剧集）。
        // 默认不进底栏，用户在「设置 → 菜单设置」里自行开启。
        const EmbyHomePage(),
        // 短剧（索引 11）—— 按当前源的短剧类目聚合（2026-10-22）。
        // 同样默认不进底栏。
        const DramaPage(),
        // 一起看（索引 12）—— 局域网观影房间：房主手机当服务器，
        // 同一 WiFi 下多人同步播放 + 聊天（2026-10-22）。
        // 同样默认不进底栏。
        const RoomHomePage(),
      ];
    }
    return _tabPagesCache!;
  }

  Widget _buildMainTabView() {
    final appState = Get.find<AppState>();

    // 对应 Swift: .sheet(isPresented: $appState.showAboutOnLaunch)
    _handleShowAboutOnLaunch(appState);

    // 悬浮导航栏布局参数:
    // - bottomInset: Home Indicator 安全区（刘海屏/iPad 手势条避让）
    // - 悬浮胶囊离底 8pt, 左右留 32pt
    // - 面板高度 ≈ 内容 35(icon18+3+label14) + 内边距 16 ≈ 51
    //
    // **真悬浮 (2026-09-26)**: 不再为底栏预留全局 navReserve 高度,
    // IndexedStack 直接全屏铺满, 底栏作为 Positioned 浮在内容之上。
    // 各 tab 页自身的滚动列表在内容底部留少量内边距即可,
    // 底栏底色已改为近透明玻璃, 内容滚过其下方时依旧清晰可见。
    // 悬浮导航栏由 JellyNavBar 组件内部处理边距和底部距离，
    // 外层 Positioned 直接贴边即可，避免双重边距导致三条栏不一致。
    // JellyNavBar 内部已统一：
    //   · sideMargin = 12（左右边距）
    //   · bottomMargin = 20（距底部距离，2026-10-02 由 30 下调，栏整体下移）
    //   · SafeArea 自动避让 Home Indicator

    return Scaffold(
      // 主界面背景全透明：不再画灰色背景层，
      // 让 app.dart 的全局壁纸层（StackFit.expand）从顶部一路铺到屏幕底
      //（含 Home Indicator 安全区）—— 用户要求"壁纸也延伸到底"。
      // 各 tab 页（首页/收藏/历史等）自身 Scaffold 也是透明的，直接透出壁纸。
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 全局背景层已**上提到 `app.dart` 的 MaterialApp.builder**
          // （Navigator 之上）。原因：这层原来画在 ContentView 里，而它是
          // Navigator 的**第一条路由**，`MaterialPageRoute` 是 opaque 的 ——
          // 推入子页后 Flutter 不再绘制 ContentView，于是所有透明 Scaffold
          // 的子页（设置子页/数据源/播放器/缓存/关于…）渲染成**纯黑**。
          // 放这里只能让 5 个 tab 透出壁纸，管不到被 push 的页面。
          // 5 个 tab 页 - 全屏铺满, 不做底部预留, 悬浮栏浮于其上
          // 关键: IndexedStack 的 index 必须包在 Obx 里, 切 tab 才生效
          //
          // ⚠️ 外面再套一层 ValueListenableBuilder 监听外观：
          // AppTheme 的颜色 getter 读 AppBrightness.isLight，但页面的
          // build 会被 Flutter 跳过（见 `_tabPages` 的说明）。
          // 这里监听外观，并**只在这些值变化时**换一批新实例，
          // 让子页重建（Element/State 复用），而不是换 key 销毁重建。
          ValueListenableBuilder<bool>(
            valueListenable: AppBrightness.isLight,
            // ⚠️ 除 isLight 外，`paletteRevision` 也算进签名：
            // `AppTheme` 换配色时 `_palette` 变了但不会通知任何 widget。
            builder: (context, isLight, __) => ValueListenableBuilder<int>(
              valueListenable: AppTheme.paletteRevision,
              builder: (context, paletteRev, ___) => Obx(() {
                final tabIndex =
                    MainTabController.instance.selectedTab.value;
                return AnimatedBuilder(
                  animation: _tabSlideCtrl,
                  builder: (context, child) {
                    // 240ms 内从 ±1 屏滑回 0：向右切页从右侧进，向左切页从左侧进
                    final t =
                        Curves.easeOutCubic.transform(_tabSlideCtrl.value);
                    final dx = _tabSlideFrom * (1 - t);
                    return FractionalTranslation(
                      translation: Offset(dx, 0),
                      child: child,
                    );
                  },
                  // child 不参与动画重建：IndexedStack 以及 12 个 tab 页的
                  // Element/State 全部复用（保活滚动位置与已加载数据）
                  child: IndexedStack(
                    // 🔴 这里**不能**再拼 `ValueKey('tabs-$isLight-$paletteRev')`：
                    // 换 key 会销毁重建全部 tab 页，阅读子 tab 与各页滚动位置
                    // 全部丢失（用户实测"切个明暗就跳回默认首页"）。
                    // 子页重建改由 `_tabPages(sig)` 换新实例来触发。
                    index: tabIndex,
                    children: _tabPages('$isLight-$paletteRev'),
                  ),
                );
              }),
            ),
          ),
          // 搜索页 - 对应 Swift .sheet(isPresented: $showSearch)
          if (_showSearch)
            ValueListenableBuilder<bool>(
              valueListenable: AppBrightness.isLight,
              builder: (context, isLight, __) => Positioned.fill(
                child: Material(
                  // 半透明遮罩, 让 BackgroundService 全局背景层透出
                  // (纯黑会盖住玻璃背景层, 搜索页看起来像"死板黑块")
                  color: AppTheme.glassTintDeep,
                  // 不再给 SearchPage 换 key：它是内联构造的，每次重建都是
                  // 新实例 → 会 rebuild 拿到新颜色；而 key 变化会**销毁重建**
                  // 它的 State（搜索词/结果/滚动位置全丢）。
                  child: SearchPage(
                    onClose: () {
                      setState(() {
                        _showSearch = false;
                      });
                    },
                  ),
                ),
              ),
            ),
          // 悬浮导航栏 - 对应 Swift floatingNavBar
          // **2026-07-09**: 全屏时隐藏, 让视频真正铺满屏幕
          // 详情页 onFullScreenChanged 时调 PlayerFullscreenController
          // .enter/.exit, 这里 Obx 监听后切到 SizedBox.shrink().
          //
          // **关键修复**: 必须放在 body Stack 里而不是 Scaffold 的
          // bottomNavigationBar。Scaffold 会把 body 和 bottomNavigationBar
          // 渲染成上下两个互不重叠的层, BackdropFilter 只能模糊自己下方
          // 已有的内容, bottomNavigationBar 下层只有 Scaffold 纯色背景,
          // 毛玻璃永远透不出 body 里的渐变背景层, 真机上看起来就是
          // "死板半透明深色块"。放进 Stack 后, 面板下方就是全局背景层
          // + 页面内容, 磨砂悬浮效果才真正生效。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Obx(() {
              if (PlayerFullscreenController.instance.isFullscreen.value) {
                return const SizedBox.shrink();
              }
              // ⚠️ 音乐 / 阅读 两个模块**自带悬浮导航栏**，
              // 影视底栏必须让位，否则两条栏叠在一起（用户实测反馈）。
              //   索引 5 = 音乐（MusicRootView 自绘 4-tab 栏）
              //   索引 6 = 阅读（cmbok 的 JellyNavBar 5-tab 栏）
              // 判断条件收在 MainTabController.inEmbeddedModule 里 ——
              // 那边同时管着"回影视"按钮的目标索引，改顺序时只有一处要动。
              if (MainTabController.instance.inEmbeddedModule) {
                return const SizedBox.shrink();
              }
              // 影视**详情页**也不要底栏：详情页是全屏内容页（海报 + 剧集
              // + 播放器），底栏会压住剧集列表的最后一行。
              // 详情页是通过 Get.toNamed('/detail') 推入的路由，
              // 这里的 Obx 读 DetailPageController 的计数（响应式），
              // 详情页 initState/dispose 时自动开关。
              if (DetailPageController.instance.isOpen) {
                return const SizedBox.shrink();
              }
              // ── 直接用阅读的 JellyNavBar（用户要求"以阅读为基准"）──
              //
              // ── 为什么不再自己画一遍 ──────────────────────────────
              // 这里原来是**又写了一遍**胶囊（Container + 阴影 + Row +
              // AnimatedContainer 选中块）。后果是影视/音乐只有"背景色淡入"
              // （300ms），而阅读有**果冻弹性滑动指示器**（850ms ElasticOut）
              // 和**毛玻璃模糊**（BackdropFilter）——
              // 三条栏的交互风格和质感都不一样。
              //
              // 上面那段旧注释还写着"不做 BackdropFilter，纯色胶囊更稳"，
              // 那是我当时自己的取舍；用户明确要求**按阅读来**，所以
              // 现在直接复用 `JellyNavBar`：一次拿到
              //   ① 果冻弹性指示器  ② 毛玻璃模糊  ③ 自适应宽度
              //   ④ 与阅读完全一致的边距/圆角/阴影/字号
              //
              // 只保留影视特有的两件事：
              //   · 项来自 `NavFeatureService.enabled`（可开关 + 拖动排序）
              //   · 长按「设置」= 返回影视顶层（阅读/音乐是从这边进去的）
              // 悬浮栏读 `AppTheme.palette`，所以换配色时它也**必须**重建 ——
              // 用 ValueListenableBuilder 监听 paletteRevision，
              // 并用它当 key 强制重建（JellyNavBar 内部取色是构造时读的）。
              return ValueListenableBuilder<int>(
                valueListenable: AppTheme.paletteRevision,
                builder: (context, paletteRev, __) => Obx(
                  () {
                    final features = NavFeatureService.instance.enabled;
                    final raw = MainTabController.instance.selectedTab.value;
                    // 索引 2 是历史遗留的「收藏」占位页（实际渲染 ShelfPage）。
                    // 若当前停在这里，底栏找不到对应项会回退成 0 ⇒ 看起来像
                    // 「首页已选中」，点首页只触发 onReselect 而不切页。
                    final cur = raw == 2 ? 1 : raw;
                    return JellyNavBar(
                      // 不再换 key：`palette` 是构造参数，每次重建都传新的
                      // `AppTheme.palette`，新实例自然会 rebuild 取到新色；
                      // 而换 key 会销毁重建它的 State（果冻指示器动画被打断）。
                      // ⚠️ 必须显式传影视的调色板 —— JellyNavBar 默认用
                      // 阅读的 JellyTheme.palette，切影视配色时那个不会变，
                      // 会导致影视栏颜色错（静默 bug）。
                      palette: AppTheme.palette,
                      currentIndex: features
                          .indexWhere((f) => f.tabIndex == cur)
                          .clamp(
                            0,
                            features.isEmpty ? 0 : features.length - 1,
                          ),
                      floating: true,
                      items: [
                        for (final f in features)
                          JellyNavItem(
                            icon: f.activeIcon,
                            label: f.label,
                            // Emby / 音乐 / 阅读用图片图标（见 NavFeature.iconAsset）；
                            // 都是白色蒙版 ⇒ 按前景色着色，跟随选中态与深浅色。
                            // 用户上传过自定义图标的仍由 JellyNavBar 优先渲染。
                            iconBuilder: f.iconAsset == null
                                ? null
                                : (color, size) => Image.asset(
                                      f.iconAsset!,
                                      width: size,
                                      height: size,
                                      fit: BoxFit.contain,
                                      color: f.iconAssetTinted ? color : null,
                                      colorBlendMode: f.iconAssetTinted
                                          ? BlendMode.srcIn
                                          : null,
                                    ),
                          ),
                      ],
                      onTap: (i) {
                        if (i < 0 || i >= features.length) return;
                        MainTabController.instance.select(features[i].tabIndex);
                      },
                      // 兜底：底栏的 currentIndex 是「按 features 反查」的，
                      // 当实际 tab 不在底栏里（例如从首页右上角进了未启用的
                      // 史藏）时会回退到 0。此时 JellyNavBar 认为「首页已选中」
                      // 只回调 onReselect —— 这里照样切过去，保证点首页一定回首页。
                      onReselect: (i) {
                        if (i < 0 || i >= features.length) return;
                        MainTabController.instance.select(features[i].tabIndex);
                      },
                      onLongPress: (_) =>
                          MainTabController.instance.backToVideo(),
                    );
                  },
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  /// 处理 showAboutOnLaunch - 启动时显示免责声明
  /// 对应 Swift .sheet(isPresented: $appState.showAboutOnLaunch)
  /// 用户可勾选"不再提示"，勾选后持久化到 SharedPreferences
  void _handleShowAboutOnLaunch(AppState appState) {
    if (appState.showAboutOnLaunch.value) {
      appState.showAboutOnLaunch.value = false;
      // 延迟显示，避免在 build 中直接弹窗
      Future.microtask(() {
        if (mounted) {
          _showDisclaimerDialog();
        }
      });
    }
  }

  /// 显示免责声明对话框
  Future<void> _showDisclaimerDialog() async {
    await showAppDisclaimerDialog(context);
  }

  Widget _buildNetworkStatusBanner() {
    final appState = Get.find<AppState>();

    return Obx(() {
      // 对应 Swift: if !networkMonitor.isConnected
      // 使用 connectivity_plus 的状态判断
      // 这里通过 appState 的网络状态来显示
      final isRetrying = appState.isRetryingConfig.value;
      // 当正在重试时显示网络横幅（表示之前断网过）
      if (!isRetrying) return const SizedBox.shrink();

      return Positioned(
        top: MediaQuery.of(context).padding.top + AppTheme.spacingSM,
        left: 0,
        right: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spacingLG,
              vertical: AppTheme.spacingSM,
            ),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: AppTheme.spacingSM,
                  offset: const Offset(0, AppTheme.spacingXS),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off, color: Colors.white, size: 16),
                const SizedBox(width: AppTheme.spacingSM),
                const Text(
                  '网络连接已断开',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                // 对应 Swift: if appState.isRetryingConfig { ProgressView() }
                if (isRetrying) ...[
                  const SizedBox(width: AppTheme.spacingSM),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// 免责声明条款文本组件
