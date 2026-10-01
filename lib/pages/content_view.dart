import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../common/theme.dart';
import '../common/constants.dart';
import '../services/app_state.dart';
import '../services/app_log.dart';
import '../services/background_service.dart';
import 'home/view.dart';
import 'shelf/view.dart';
import '../reading/widgets/jelly_nav_bar.dart';
import '../services/nav_feature_service.dart';
import 'live/view.dart';
import '../reading/pages/home_page.dart' as reading_app;
import '../music/pages/root_view.dart';
import 'settings/view.dart';
import 'search/view.dart';
import 'search/controller.dart';
import 'settings/controller.dart';
import '../router/app_pages.dart';
import '../services/detail_page_controller.dart';
import '../services/player_fullscreen_controller.dart';
import '../widgets/video_player_pip.dart';
import '../widgets/disclaimer_dialog.dart';
import '../widgets/app_loading_view.dart';
import '../common/appearance_sync.dart';
import '../common/floating_nav_spec.dart';
import '../common/theme_mode_store.dart';
import '../services/main_tab_controller.dart';

/// 主内容视图 - 对应 Swift ContentView
/// 管理三种状态：设置页 / 加载页 / 主页
class ContentView extends StatefulWidget {
  const ContentView({super.key});

  @override
  State<ContentView> createState() => _ContentViewState();
}

class _ContentViewState extends State<ContentView>
    with WidgetsBindingObserver {
  // int _selectedTab 已迁移到 MainTabController.selectedTab (全局共享)
  bool _hasSavedConfig = false;
  bool _showSearch = false;
  // 防止 ever() 回调重入 - 在回调内部清空 pendingSearchKeyword 时会再次触发 ever()
  bool _isProcessingSearchKeyword = false;

  // 设置页表单
  final _vodUrlController = TextEditingController();
  bool _isLoadingConfig = false;
  String? _configError;

  // 搜索控制器
  TvSearchController? _searchVM;

  // 设置控制器（多仓库选择）
  SettingsController? _settingsVM;

  /// 上一次 lifecycle state (用于记录 from→to 转换)
  AppLifecycleState? _lastLifecycleState;
  DateTime? _lastLifecycleChangeAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 主题模式（含「跟随系统」）已在 main() 启动时从 prefs 加载，
    // 这里不再用 BackgroundService.appearanceMode 覆盖 ——
    // 旧逻辑每次冷启动都会把 'system' 覆盖成 dark/light（跟随系统丢失）。
    _searchVM = Get.find<TvSearchController>();
    _settingsVM = Get.put(SettingsController());
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
    _vodUrlController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 对应 Swift onChange(of: scenePhase) - 应用恢复前台时检查服务
    final from = _lastLifecycleState;
    final now = DateTime.now();
    final prevAt = _lastLifecycleChangeAt;
    final sincePrevMs =
        prevAt == null ? null : now.difference(prevAt).inMilliseconds;

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

  /// 对应 Swift onAppear - 加载已保存的配置
  Future<void> _loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final savedVodUrl = prefs.getString(AppConstants.apiUrl) ?? '';

    if (savedVodUrl.isNotEmpty) {
      _hasSavedConfig = true;
      _vodUrlController.text = savedVodUrl;
      final appState = Get.find<AppState>();
      await appState.loadConfig(vodUrl: savedVodUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = Get.find<AppState>();

    return Obx(() {
      final phase = appState.loadingPhase.value;

      // 对应 Swift: if appState.isConfigLoaded → mainTabView
      // else if hasSavedConfig && loadingPhase != .idle → loadingView
      // else → setupView
      Widget currentChild;
      if (appState.isConfigLoaded.value) {
        currentChild = _buildMainTabView();
      } else if (_hasSavedConfig && phase != LoadingPhase.idle) {
        currentChild = _buildLoadingView();
      } else {
        currentChild = _buildSetupView();
      }

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

  Widget _buildSetupView() {
    final appState = Get.find<AppState>();

    return Material(
      // 首次配置页也跟随外观（原来写死 0xFF0F0F0F，浅色模式下是一整片黑）
      color: AppTheme.backgroundPrimary,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppTheme.backgroundPrimary,
              AppTheme.backgroundSecondary,
              AppTheme.backgroundPrimary,
            ],
          ),
        ),
        child: SafeArea(
        child: Center(
          // 键盘避让：这一页中间有个接口地址输入框，键盘弹起时若不抬高，
          // 输入框会被键盘盖住（用户看不到自己在打什么）。
          // 用 viewInsets（键盘）而不是 padding（刘海/Home 条）。
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Column(
              children: [
                const SizedBox(height: 60),
                // Logo
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        AppTheme.accentColor,
                        AppTheme.accentLightColor,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.accentColor.withValues(alpha: 0.4),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  // 猫猫 Logo（取自 App 图标）。
                  // 外圈保留原来的强调色渐变圆环 + 光晕，中间放猫猫 ——
                  // 直接铺满整圆会丢掉原来的"发光圆钮"观感。
                  child: ClipOval(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/cat_logo.png',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXL),
                Text(
                  'TVBox',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingSM),
                Text(
                  '极致视听 · 简洁至上',
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: AppTheme.textSecondary,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(
                    height: AppTheme.spacingXXL + AppTheme.spacingSM),
                // 接口配置标题
                Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: AppTheme.spacingXS),
                  child: Text(
                    '接口配置',
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingMD),
                // 点播接口地址 - 对应 Swift vodApiUrl TextField
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundSecondary,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: AppTheme.borderLight),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      Icon(Icons.link,
                          color: AppTheme.accentColor, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _vodUrlController,
                          style: TextStyle(
                              color: AppTheme.textPrimary),
                          decoration: InputDecoration(
                            hintText: '请输入点播接口地址 (URL)',
                            hintStyle: TextStyle(
                                color: AppTheme.textTertiary),
                            border: InputBorder.none,
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 14),
                          ),
                          keyboardType: TextInputType.url,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.content_paste,
                            color: AppTheme.accentColor, size: 20),
                        onPressed: _pasteFromClipboard,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppTheme.spacingMD),
                const SizedBox(height: AppTheme.spacingXXL),
                // 确认按钮 - 对应 Swift "开启影音之旅" Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoadingConfig
                        ? null
                        : () => _submitConfig(appState),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          vertical: AppTheme.spacingLG),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: _isLoadingConfig
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Obx(() {
                                final phase = appState.loadingPhase.value;
                                return Text(
                                  phase.isLoading
                                      ? phase.description
                                      : '正在解析配置...',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16),
                                );
                              }),
                            ],
                          )
                        : const Text(
                            '开启影音之旅',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16),
                          ),
                  ),
                ),
                // 最近使用 - 对应 Swift apiHistory
                if (_settingsVM != null &&
                    _settingsVM!.apiHistory.isNotEmpty)
                  Obx(() {
                    final history = _settingsVM!.apiHistory;
                    if (history.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: AppTheme.spacingXXL),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppTheme.spacingXS),
                          child: Text(
                            '最近使用',
                            style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: AppTheme.textTertiary,
                            ),
                          ),
                        ),
                        const SizedBox(height: AppTheme.spacingMD),
                        ...history.take(3).map((url) => Padding(
                              padding: const EdgeInsets.only(
                                  bottom: AppTheme.spacingMD),
                              child: GestureDetector(
                                onTap: () {
                                  _vodUrlController.text = url;
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                      horizontal: AppTheme.spacingLG),
                                  decoration: BoxDecoration(
                                    color: AppTheme.backgroundSecondary,
                                    borderRadius:
                                        BorderRadius.circular(10),
                                    border: Border.all(
                                        color: AppTheme.borderLight,
                                        width: 0.5),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                          Icons
                                              .history_rounded,
                                          size: AppTheme.fontCaption,
                                          color:
                                              AppTheme.textSecondary),
                                      const SizedBox(
                                          width: AppTheme.spacingSM),
                                      Expanded(
                                        child: Text(
                                          url,
                                          style: TextStyle(
                                            fontSize:
                                                AppTheme.fontCaption,
                                            color:
                                                AppTheme.textSecondary,
                                          ),
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Icon(Icons.chevron_right,
                                          size: 8,
                                          color: AppTheme.textTertiary),
                                    ],
                                  ),
                                ),
                              ),
                            )),
                      ],
                    );
                  }),
                // 错误信息 - 对应 Swift settingsVM.configError
                if (_configError != null) ...[
                  const SizedBox(height: AppTheme.spacingLG),
                  Container(
                    padding: const EdgeInsets.all(AppTheme.spacingMD),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.red.withValues(alpha: 0.3),
                          width: 0.5),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.red, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _configError!,
                            style: const TextStyle(
                                color: Colors.red,
                                fontSize: AppTheme.fontCaption),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 50),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }

  /// 提交配置 - 对应 Swift settingsVM.loadConfig()
  Future<void> _submitConfig(AppState appState) async {
    final vodUrl = _vodUrlController.text.trim();

    if (vodUrl.isEmpty) {
      setState(() {
        _configError = '请输入点播接口地址';
      });
      return;
    }

    setState(() {
      _isLoadingConfig = true;
      _configError = null;
    });

    // 保存配置 URL
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.apiUrl, vodUrl);

    try {
      await appState.loadConfig(vodUrl: vodUrl);

      if (appState.isConfigLoaded.value) {
        // 加载成功 - applyLoadedConfigState 已在 loadConfig 中调用
        if (_settingsVM != null) {
          await _settingsVM!.addToApiHistory(vodUrl);
        }
      } else {
        setState(() {
          _isLoadingConfig = false;
          _configError = appState.configLoadError.value ?? '配置加载失败';
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingConfig = false;
        _configError = e.toString();
      });
    }
  }

  /// 从剪贴板粘贴 - 对应 Swift readPasteboardText()
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _vodUrlController.text = data.text!;
    }
  }

  // ============================================================
  // 主标签视图 - 对应 Swift mainTabView
  // ============================================================

  /// 音乐 / 阅读在 IndexedStack 里的下标。
  ///
  /// 这两个模块**自带导航栏**，所以影视底栏要在它们选中时隐藏
  /// （否则两条栏重叠 —— 用户实测反馈过）。
  /// 写成常量而不是散落的字面量 5/6，改 _tabPages 顺序时不容易漏。

  final List<Widget> _tabPages = [
    const HomePage(),
    // 「史藏」= 历史 + 收藏（统一页，顶部 tab 切换）
    const ShelfPage(),
    const ShelfPage(), // 占位：索引 2 保留结构避免下标错乱
    const SettingsPage(),
    // 直播作为第 5 个 tab（选中才高亮，修复"首页+直播同时高亮"）
    const LivePage(),
    // 音乐（索引 5）—— 按 Beans-Music 的 4-tab 结构重绘
    // （主页/搜索/音乐库/我的 + 迷你播放器 + 全屏播放器）
    const MusicRootView(),
    // 阅读（索引 6）—— 完整移植 cmbok_app 的 5-tab 应用
    // （漫画 / 图书 / 书架 / 收藏 / 我的），内含它自己的导航栏与主题体系
    const reading_app.HomePage(),
  ];

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
    //   · bottomMargin = 30（距底部距离）
    //   · SafeArea 自动避让 Home Indicator

    return Scaffold(
      body: Stack(
        children: [
          // 全局背景层 - 对应 TV-release CustomWallView
          // 4 个内置渐变 + 用户上传自定义图片, 通过 BackgroundService 切换
          // 5 个 tab 页背景透明 (后述) 让其透出
          Positioned.fill(
            child: BackgroundService.instance.buildBackground(overlayAlpha: 0.3),
          ),
          // 5 个 tab 页 - 全屏铺满, 不做底部预留, 悬浮栏浮于其上
          // 关键: IndexedStack 的 index 必须包在 Obx 里, 切 tab 才生效
          //
          // ⚠️ 外面再套一层 ValueListenableBuilder 监听外观：
          // AppTheme 的颜色 getter 读 AppBrightness.isLight，但 _tabPages 是
          // **const widget 实例** —— IndexedStack 重建时 Flutter 判定 widget
          // 未变，会**跳过子页的 build**，于是首页里不在 Obx 内的部分
          // （筛选芯片面板、搜索栏等）一直用旧颜色，表现为
          // "切了外观，但筛选背景没变"。
          // 这里监听 isLight，并在变化时换 key，强制子页重绘。
          ValueListenableBuilder<bool>(
            valueListenable: AppBrightness.isLight,
            builder: (context, isLight, __) => Obx(() => IndexedStack(
                  key: ValueKey('tabs-$isLight'),
                  index: MainTabController.instance.selectedTab.value,
                  children: _tabPages,
                )),
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
                  // key 跟随外观：搜索浮层里的文字/输入框颜色同样读 AppTheme，
                  // 不重建的话切外观后会停在旧色。
                  child: SearchPage(
                    key: ValueKey('search-$isLight'),
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
              return Obx(() {
                final features = NavFeatureService.instance.enabled;
                final cur = MainTabController.instance.selectedTab.value;
                return JellyNavBar(
                  // ⚠️ 必须显式传影视的调色板 —— JellyNavBar 默认用
                  // 阅读的 JellyTheme.palette，切影视配色时那个不会变，
                  // 会导致影视栏颜色错（静默 bug）。
                  palette: AppTheme.palette,
                  currentIndex:
                      features.indexWhere((f) => f.tabIndex == cur).clamp(
                            0,
                            features.isEmpty ? 0 : features.length - 1,
                          ),
                  floating: true,
                  items: [
                    for (final f in features)
                      JellyNavItem(
                        icon: f.activeIcon,
                        label: f.label,
                      ),
                  ],
                  onTap: (i) {
                    if (i < 0 || i >= features.length) return;
                    MainTabController.instance.select(features[i].tabIndex);
                  },
                  onLongPress: (_) =>
                      MainTabController.instance.backToVideo(),
                );
              });
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
                const Icon(Icons.wifi_off,
                    color: Colors.white, size: 16),
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
