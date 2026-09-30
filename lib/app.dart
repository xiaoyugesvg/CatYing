import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'common/theme.dart';
import 'common/constants.dart';
import 'services/app_state.dart';
import 'services/app_log.dart';
import 'services/background_service.dart';
import 'services/player_prefs.dart';
import 'pages/home/view.dart';
import 'pages/history/view.dart';
import 'pages/favorites/view.dart';
import 'pages/live/view.dart';
import 'pages/settings/view.dart';
import 'pages/search/view.dart';
import 'pages/search/controller.dart';
import 'pages/settings/controller.dart';
import 'router/app_pages.dart';
import 'services/player_fullscreen_controller.dart';
import 'widgets/video_player_pip.dart';
import 'widgets/glass.dart';
import 'widgets/disclaimer_dialog.dart';
import 'widgets/app_loading_view.dart';
import 'common/theme_mode_store.dart';
import 'services/main_tab_controller.dart';

class TVBoxApp extends StatelessWidget {
  const TVBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 提前注册全屏状态控制器, 这样详情页 onFullScreenChanged 才能
    // 直接 PlayerFullscreenController.instance.enter/exit 调用.
    Get.put(PlayerFullscreenController(), permanent: true);
    // 全局主 Tab 控制器: 底部悬浮导航选中项全局共享,
    // 详情页也能渲染同样的悬浮栏并切回对应 tab.
    Get.put(MainTabController(), permanent: true);

    // 外观模式是**唯一来源**（方向已反转：外观主导，背景跟着外观走）。
    // BackgroundService 改变外观时通过回调推给 ThemeModeStore，
    // 避免服务层反向依赖 App 层造成循环依赖。
    final bg = BackgroundService.instance;
    bg.onAppearanceChanged = (isLight) {
      ThemeModeStore.applyLightFromBackground(isLight);
    };
    // 冷启动：直接把持久化的外观模式应用上去
    ThemeModeStore.set(bg.appearanceMode.value == AppearanceMode.light
        ? ThemeMode.light
        : ThemeMode.dark);

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeModeStore.notifier,
      builder: (context, themeMode, _) {
        // 跟随系统：把平台亮度同步给 AppTheme
        final platformLight =
            View.of(context).platformDispatcher.platformBrightness ==
                Brightness.light;
        ThemeModeStore.syncFromPlatform(platformLight);
        // AppTheme 玻璃色等随 isLight 变化，必须监听后整体重建
        return ValueListenableBuilder<bool>(
          valueListenable: ThemeModeStore.brightnessListenable,
          builder: (context, isLightNow, __) {
            // ⚠️ 必须在内层算：外观联动（方案 A）改的是 AppBrightness，
            // 只会触发这一层重建。若在外层算 effectiveLight，外层不重建，
            // MaterialApp.themeMode 会一直用旧值，界面文字颜色不跟着壁纸变。
            final effectiveLight = ThemeModeStore.followBackground
                ? isLightNow
                : (platformLight && themeMode == ThemeMode.system) ||
                    themeMode == ThemeMode.light;
            // ⚠️ 单一真相源：AppTheme 的 textPrimary/backgroundCard 等 getter
            // 读的是 AppBrightness.isLight，而 MaterialApp 用的是 effectiveLight。
            // 两者若不同步，就会出现「背景是浅色、文字却是白色」这类颜色不统一
            // （用户实测截图：皎月白壁纸 + 白字）。
            // 这里在构建前把 AppBrightness 强制对齐到 effectiveLight。
            if (AppBrightness.isLight.value != effectiveLight) {
              // 用 microtask 避免在 build 中直接改 notifier 触发的重入
              final target = effectiveLight;
              Future<void>.microtask(() {
                if (AppBrightness.isLight.value != target) {
                  AppBrightness.isLight.value = target;
                }
              });
            }
            AppLog.instance.log(
                '[Appearance] themeMode=$themeMode platformLight=$platformLight '
                'followBg=${ThemeModeStore.followBackground} '
                'isLight(theme)=$isLightNow effectiveLight=$effectiveLight');
            // 全局字号缩放（设置 → 外观 → 界面字号），用 Obx 监听
            return Obx(() {
              final scale = PlayerPrefs.instance.fontScale.value;
              return GetMaterialApp(
                title: '猫影',
                theme: AppTheme.lightTheme,
                darkTheme: AppTheme.darkTheme,
                themeMode: effectiveLight ? ThemeMode.light : ThemeMode.dark,
                // 把 NavigatorState 暴露给 VideoPlayerPip，让画中画能插入到顶层 Overlay
                navigatorKey: VideoPlayerPip.navigatorKey,
                home: const ContentView(),
                getPages: AppPages.pages,
                debugShowCheckedModeBanner: false,
                builder: (context, child) {
                  if (scale <= 0 || (scale - 1.0).abs() < 0.001) {
                    return child!;
                  }
                  return MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  );
                },
              );
            });
          },
        );
      },
    );
  }
}

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
    // ⚠️ load() 是异步的：它读 theme_mode 会改明暗。外观模式是唯一来源，
    // 所以读完必须再用 BackgroundService 的外观模式断言一次，
    // 否则冷启动的明暗会被历史 theme_mode 覆盖。
    ThemeModeStore.load().then((_) {
      final bg = Get.isRegistered<BackgroundService>()
          ? BackgroundService.instance
          : null;
      if (bg == null) return;
      ThemeModeStore.set(bg.appearanceMode.value == AppearanceMode.light
          ? ThemeMode.light
          : ThemeMode.dark);
    });
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
                    gradient: const LinearGradient(
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
                  child: const Icon(
                    Icons.play_circle_filled,
                    size: 50,
                    color: Colors.white,
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
                      const Icon(Icons.link,
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
                        icon: const Icon(Icons.content_paste,
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

  final List<Widget> _tabPages = [
    const HomePage(),
    const HistoryPage(),
    const FavoritesPage(),
    const SettingsPage(),
    // 直播作为第 5 个 tab（选中才高亮，修复"首页+直播同时高亮"）
    const LivePage(),
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
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const navSideGap = 32.0;
    const navFloatGap = 8.0;
    const navBarHeight = 51.0;

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
          Obx(() => IndexedStack(
                index: MainTabController.instance.selectedTab.value,
                children: _tabPages,
              )),
          // 搜索页 - 对应 Swift .sheet(isPresented: $showSearch)
          if (_showSearch)
            Positioned.fill(
              child: Material(
                // 半透明遮罩, 让 BackgroundService 全局背景层透出
                // (纯黑会盖住玻璃背景层, 搜索页看起来像"死板黑块")
                color: AppTheme.glassTintDeep,
                child: SearchPage(
                  onClose: () {
                    setState(() {
                      _showSearch = false;
                    });
                  },
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
            left: navSideGap,
            right: navSideGap,
            bottom: bottomInset + navFloatGap,
            child: Obx(() {
              if (PlayerFullscreenController.instance.isFullscreen.value) {
                return const SizedBox.shrink();
              }
              // **真悬浮轻玻璃 (2026-09-26)**：底色用近透明 glassTintClear
              // (alpha≈2%)，只保留毛玻璃模糊+细描边+高光，几乎不遮内容。
              // 内容滚过底栏下方时依旧清晰可见，真正"沉浸式悬浮"。
              return GlassPanel(
                radius: 30,
                blur: true,
                tint: AppTheme.glassTintClear,
                borderColor: AppTheme.glassBorder,
                borderWidth: 0.8,
                highlightStrength: 0.2,
                shadow: true,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _navItem(Icons.home_outlined, Icons.home, '首页', 0),
                    _navLiveItem(),
                    _navItem(
                        Icons.schedule_outlined, Icons.schedule, '历史', 1),
                    _navItem(
                        Icons.favorite_border, Icons.favorite, '收藏', 2),
                    _navItem(
                        Icons.settings_outlined, Icons.settings, '设置', 3),
                  ],
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


  /// 直播：第 5 个底部 tab（选中才高亮，修复"首页+直播同时高亮"）
  Widget _navLiveItem() {
    return _navItem(Icons.live_tv, Icons.live_tv, '直播', 4);
  }

  /// 导航栏项 - 对应 Swift navBarItem
  Widget _navItem(
      IconData icon, IconData activeIcon, String label, int index) {
    final isSelected = MainTabController.instance.selectedTab.value == index;
    return GestureDetector(
      onTap: () {
        setState(() {
          MainTabController.instance.selectedTab.value = index;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              size: 18,
              color: isSelected
                  ? AppTheme.accentColor
                  : Colors.white.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isSelected
                    ? AppTheme.accentColor
                    : Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 网络状态横幅 - 对应 Swift networkStatusBanner
  // ============================================================

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
