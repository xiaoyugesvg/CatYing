import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../common/theme.dart';
import '../miniapp/services/ant_bridge.dart';
import '../services/app_log.dart';
import '../services/main_tab_controller.dart';
import '../services/nav_feature_service.dart';
import '../services/webview_page_color.dart';
import '../widgets/common_widgets.dart';
import 'web_home_fm_shim.dart';
import 'web_home_manage_page.dart';
import 'web_home_prefs.dart';
import 'web_home_source.dart';
import 'webhtv_extension_page.dart';

/// 「网页首页」模块 —— **独立于小程序体系**的一个 WebView 宿主。
///
/// ── 它是什么 ──────────────────────────────────────────────────
/// 加载**用户选的网页源**（内置 5 个：默认网页 + 裤佬音乐 / 歪比巴卜 /
/// 漫蛙动漫 / 追更助手；也支持订阅链接导入、本地 HTML 导入），
/// 并注入 `window.ant` SDK（+ `window.fm` 垫片，见 [kWebHomeFmShim]）。
/// 于是网页里可以直接：
///   · `ant.source.search({siteKey, wd})` / `ant.source.detail(...)` 搜片取详情
///   · `ant.player.open({url, title})` 用猫影自己的播放器播放
///   · `ant.storage.*` 存数据（按 `webhome` 前缀隔离）
///   · `ant.request(...)` 发请求（本地 Dio，不受浏览器 CORS 限制）
///
/// ── 顶栏（用户 2026-10-14 要求）────────────────────────────────
/// 左边「网页」二字，右边两个按钮：**源切换** + **设置**（进「网页管理」）。
class WebHomePage extends StatefulWidget {
  const WebHomePage({super.key});

  @override
  State<WebHomePage> createState() => _WebHomePageState();
}

class _WebHomePageState extends State<WebHomePage> {
  /// 本模块固定的 appId（`ant.storage` 的分区前缀）—— 与任何小程序都不同。
  static const String _appId = 'webhome';

  /// 放行的能力：这是**本模块自己**的内置页面（不是第三方小程序包），
  /// 所以权限由模块统一给定，不走 manifest。
  static const List<String> _permissions = [
    'ui',
    'storage',
    'network',
    'player',
    'source',
  ];

  late final WebViewController _controller;
  int _progress = 0;
  bool _failed = false;

  /// 当前**已加载**的源 id（用来判断"是不是换源了、要不要重新加载"）。
  String _loadedSourceId = '';

  /// 当前网页的**主色**（meta theme-color → body/html 背景色）。
  /// 用来把**状态栏那一条**刷成和网页一样的颜色（用户 2026-10-14 要求）；
  /// null = 没取到 ⇒ 那条保持透明、透出壁纸（与改造前一致）。
  Color? _pageColor;

  /// ── 懒启动（用户 2026-10-15：「RSS、网页以及海阔默认关闭」）──────────
  ///
  /// 本页是 `IndexedStack` 的第 8 个 child ⇒ **模块没开进底栏也会被 build**，
  /// `initState` 照跑。原来这里无条件建 WebView 并立刻 `loadRequest` ⇒
  /// "关着"的模块在启动时就占一个 WebView、发一次网页请求。
  /// 现在只在**开关打开**时才真正起 WebView，关着时只挂一个监听等它被打开。
  bool _started = false;
  Worker? _navWorker;
  Worker? _tabWorker;
  bool get _tabEnabled =>
      NavFeatureService.instance.enabled.contains(NavFeature.webhome);

  @override
  void initState() {
    super.initState();
    // 网页源列表/选中项变化（管理页增删改排序 / 切换）→ 跟着刷新
    webHomeSourcesTick.addListener(_onSourcesChanged);
    if (_tabEnabled) {
      _start();
    } else {
      _navWorker = ever(NavFeatureService.instance.enabled, (_) {
        if (!_tabEnabled || _started) return;
        _start();
        if (mounted) setState(() {});
      });
    }
  }

  /// 认领 `ant.exitMiniApp()` 的处理权（见 [AntBridge.onExitRequested] 的单槽问题）
  void _bindExitHandler() {
    AntBridge.onExitRequested = () {
      if (!mounted) return;
      MainTabController.instance.select(MainTabController.videoTabIndex);
    };
  }

  /// 真正开建 WebView 并加载当前源（只会跑一次）
  void _start() {
    if (_started) return;
    _started = true;
    AntBridge.configure(appId: _appId, permissions: _permissions);
    _bindExitHandler();
    // ⚠️ `AntBridge.onExitRequested` 是**单槽静态**：小程序网页页
    //（mini_app_web_page）一打开就会把它改成"关掉那一页"，而本页只在
    //  模块开启时设一次 ⇒ 之后回到网页，`ant.exitMiniApp()` 会落到那个
    //  **已销毁**页面的回调上（mounted=false → 什么都不做）＝点了没反应。
    //   所以只要"网页"这个 tab 被选中，就重新认领一次。
    _tabWorker = ever(MainTabController.instance.selectedTab, (v) {
      if (v == NavFeature.webhome.tabIndex) _bindExitHandler();
    });
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.backgroundPrimary)
      ..addJavaScriptChannel(
        AntBridge.channelName,
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (url) {
            if (mounted) {
              setState(() {
                _progress = 0;
                _failed = false;
              });
            }
          },
          onPageFinished: (url) {
            // 每次加载完都注入：站内跳转产生的新页面同样需要 window.ant / window.fm
            _controller
              ..runJavaScript(AntBridge.injectScript)
              ..runJavaScript(kWebHomeFmShim);
            // 用户自配的「WebHome 扩展」（Webhtv → WebHome 扩展）按匹配规则注入
            _injectExtensions(url);
            // 顶栏跟随网页配色：立刻探一次；不少页面的颜色是脚本随后才设的
            //（或主题异步就绪），再补探一次兜住。
            _probePageColor();
            Future<void>.delayed(const Duration(milliseconds: 600), () {
              if (mounted) _probePageColor();
            });
          },
          onWebResourceError: (e) {
            AppLog.instance.log('[WebHome] 资源错误: ${e.errorCode} '
                '${e.description} url=${e.url}');
            // 只有**主文档**失败才提示（子资源失败很常见，不打扰用户）
            if (e.isForMainFrame == true && mounted) {
              setState(() => _failed = true);
            }
          },
        ),
      );
    _loadEntry();
  }

  @override
  void dispose() {
    webHomeSourcesTick.removeListener(_onSourcesChanged);
    _navWorker?.dispose();
    _tabWorker?.dispose();
    super.dispose();
  }

  /// 源列表变了：换了源就重新加载，只是顺序/名字变了就只重建界面。
  void _onSourcesChanged() {
    // 模块没开 ⇒ 不干活（此时 WebView 还没建，碰 _controller 会 LateInitializationError）
    if (!mounted || !_started) return;
    final cur = WebHomePrefs.instance.current.id;
    if (cur != _loadedSourceId) {
      setState(() {
        _failed = false;
        _progress = 0;
      });
      _loadEntry();
    } else {
      setState(() {});
    }
  }

  /// 探一次页面主色。
  Future<void> _probePageColor() async {
    final c = await probeWebViewPageColor(_controller);
    if (!mounted || c == null || c == _pageColor) return;
    setState(() => _pageColor = c);
  }

  /// 注入命中的「WebHome 扩展」（用户自配脚本，见 Webhtv → WebHome 扩展）。
  ///
  /// 与 `window.ant` / `window.fm` **同一时机**（页面加载完成后）；
  /// 命中的扩展由 [WebhtvExtensionStore.resolveFor] 合成一段带 try/catch 的 IIFE，
  /// 单个扩展报错不会影响其它扩展。
  Future<void> _injectExtensions(String url) async {
    try {
      final js = await WebhtvExtensionStore.instance.resolveFor(
        url: url,
        sourceKey: WebHomePrefs.instance.current.id,
      );
      if (js.isEmpty) return;
      await _controller.runJavaScript(js);
      AppLog.instance.log('[WebHome] 已注入扩展脚本（${js.length} 字符）');
    } catch (e) {
      AppLog.instance.log('[WebHome] 注入扩展失败: $e');
    }
  }

  /// 加载**当前选中的网页源**。
  ///
  /// 三种形态分别走：远端 `loadRequest` / 内置 `loadFlutterAsset` /
  /// 本地文件 `loadFile`（用户在手机上导入的那种）。
  Future<void> _loadEntry() async {
    if (!WebHomePrefs.instance.loaded) {
      await WebHomePrefs.instance.load();
    }
    if (!mounted) return;
    final src = WebHomePrefs.instance.current;
    _loadedSourceId = src.id;
    try {
      switch (src.kind) {
        case WebHomeSourceKind.url:
          await _controller.loadRequest(Uri.parse(src.value));
        case WebHomeSourceKind.asset:
          await _controller.loadFlutterAsset(src.value);
        case WebHomeSourceKind.file:
          await _controller.loadFile(src.value);
      }
    } catch (e) {
      AppLog.instance.log('[WebHome] 网页加载失败（${src.name}）: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  /// 桥回调：与小程序宿主同一套协议（`AntBridge` 是静态的，两边共用）。
  Future<void> _onBridgeMessage(JavaScriptMessage message) async {
    final raw = message.message;
    Map<String, dynamic>? req;
    try {
      req = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
    if (req == null || req['id'] == null) return;
    final id = req['id'];
    final resp = await AntBridge.handleMessage(raw);
    final map = jsonDecode(resp) as Map<String, dynamic>;
    final ok = map['ok'] == true;
    try {
      if (ok) {
        await _controller.runJavaScript(
          'window.__antResolve && window.__antResolve($id, ${jsonEncode(map['result'])});',
        );
      } else {
        await _controller.runJavaScript(
          'window.__antReject && window.__antReject($id, ${jsonEncode(map['error'])});',
        );
      }
    } catch (e) {
      AppLog.instance.log('[WebHome] 桥回调失败: $e');
    }
  }

  /// 打开「网页管理」（设置里的同一页）。
  void _openManage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const WebHomeManagePage()),
    );
  }

  /// 顶栏动作按钮：**圆形浅底**（与 RSS / 影视首页右上角同款）。
  Widget _topIcon(IconData icon, String tooltip, VoidCallback? onTap) =>
      Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 15,
              color: onTap == null
                  ? AppTheme.textTertiary
                  : AppTheme.textSecondary,
            ),
          ),
        ),
      );

  /// 重新加载当前网页（顶栏「刷新」）。
  void _reload() {
    setState(() {
      _failed = false;
      _progress = 0;
    });
    _controller.reload();
  }

  /// 切换网页 —— 版式**对齐 RSS / 影视的切换面板**
  ///（用户 2026-10-15：「网页的顶栏也参考 RSS 那种」）：
  /// 约 0.4 屏高、标题 + 定位 + 网格/列表切换、搜索胶囊、2 列卡片、
  /// 底部「网页管理」入口。
  Future<void> _pickSource() async {
    final prefs = WebHomePrefs.instance;
    if (!prefs.loaded) await prefs.load();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _WebSourceSwitchSheet(
        sources: prefs.sources,
        selectedId: prefs.selectedId,
        onPick: (id) {
          if (id != prefs.selectedId) prefs.select(id);
        },
        onManage: _openManage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 模块没开进底栏 ⇒ 一行都不渲染（也保证上面那套懒启动不被绕过）
    if (!_started) return const SizedBox.shrink();
    // 状态栏那一条：刷成**当前网页的主色**（取不到就透明 ⇒ 透出壁纸，与改造前一致）。
    final topInset = MediaQuery.paddingOf(context).top;
    final pageColor = _pageColor;
    Widget page = Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: Column(
        children: [
          Container(height: topInset, color: pageColor),
          // ── 顶栏：与 RSS / 影视首页**同款**——左「Logo + 加粗网页名（点击换源）」，
          //    右「圆形动作按钮」。（用户 2026-10-15：「网页的顶栏也参考 RSS 那种」）
          //
          // ⚠️ 进入「网页」时影视悬浮底栏会隐藏（见 MainTabController
          //   .inEmbeddedModule），所以最左边必须留一个**回影视**的出口，
          //   否则用户会被困在网页里出不去。
          SizedBox(
            height: 46,
            child: Padding(
              // 左 6：让返回钮贴近屏幕边；右 6：圆形按钮贴边（同 RSS）
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回影视',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    iconSize: 20,
                    onPressed: () => MainTabController.instance.backToVideo(),
                    icon: Icon(Icons.arrow_back_ios_new_rounded,
                        color: AppTheme.textPrimary),
                  ),
                  // 左：Logo + 网页名（**点它换源**）—— 与 RSS / 影视首屏同款
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _pickSource,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _WebLogo(),
                        const SizedBox(width: 8),
                        const _CurrentSourceLabel(),
                        const SizedBox(width: 4),
                        Icon(Icons.expand_more_rounded,
                            size: 16, color: AppTheme.textTertiary),
                      ],
                    ),
                  ),
                  const Spacer(),
                  _topIcon(Icons.refresh_rounded, '刷新', _reload),
                  const SizedBox(width: 8),
                  _topIcon(Icons.tune_rounded, 'Webhtv 管理', _openManage),
                ],
              ),
            ),
          ),
          Expanded(
            // 只保留**左右**安全区（横屏刘海），上下自己管：
            // 上 = 顶栏；下 = 与改造前一致（不额外留白）
            child: SafeArea(
              top: false,
              bottom: false,
              child: Stack(
                children: [
                  Positioned.fill(
                      child: WebViewWidget(controller: _controller)),

                  // 贴顶加载进度（不占位，与小程序宿主一致）
                  if (_progress > 0 && _progress < 100)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(
                        value: _progress / 100.0,
                        minHeight: 2,
                        backgroundColor: AppTheme.borderLight,
                        valueColor: AlwaysStoppedAnimation<Color>(
                            AppTheme.accentColor),
                      ),
                    ),

                  // 主文档加载失败：给明确原因 + 重试/换源入口（而不是白屏）
                  if (_failed)
                    Positioned.fill(
                      child: ColoredBox(
                        color: AppTheme.backgroundPrimary,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.public_off_rounded,
                                  size: 42, color: AppTheme.textSecondary),
                              const SizedBox(height: 12),
                              Text(
                                '「${WebHomePrefs.instance.current.name}」打不开',
                                style: TextStyle(
                                    color: AppTheme.textPrimary, fontSize: 15),
                              ),
                              const SizedBox(height: 6),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 32),
                                child: Text(
                                  WebHomePrefs.instance.current.value,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 12),
                                ),
                              ),
                              const SizedBox(height: 18),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  TextButton(
                                    onPressed: () {
                                      setState(() => _failed = false);
                                      _loadEntry();
                                    },
                                    child: const Text('重试'),
                                  ),
                                  const SizedBox(width: 8),
                                  TextButton(
                                    onPressed: _pickSource,
                                    child: const Text('换一个网页'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    // 状态栏图标的明暗必须跟着那条颜色走 —— 否则「浅色网页 + 深色主题」时
    // 深色图标压在浅底上、或浅图标压在浅底上，等于看不见状态栏。
    if (pageColor != null) {
      page = AnnotatedRegion<SystemUiOverlayStyle>(
        value: pageColor.computeLuminance() > 0.5
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light,
        child: page,
      );
    }
    return page;
  }
}

/// 「网页」顶栏 Logo —— 与 RSS / 影视首页的 Logo **同款造型**
///（34×34 圆角渐变方块 + 同色柔光），只是图标换成地球。
///
/// 用户 2026-10-15：「网页的顶栏也参考 RSS 那种」⇒ 顶栏左侧统一成
/// “Logo + 加粗网页名（点击换源）”，与 RSS / 影视首屏的视觉语言一致。
class _WebLogo extends StatelessWidget {
  const _WebLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.accentColor.withValues(alpha: 0.65),
            AppTheme.accentColor,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: AppTheme.accentColor.withValues(alpha: 0.35),
            blurRadius: 10,
          ),
        ],
      ),
      child: const Icon(Icons.public_rounded, color: Colors.white, size: 20),
    );
  }
}

/// 顶栏里显示"当前网页名"的小组件（跟随 [webHomeSourcesTick] 重建）。
///
/// 单独抽出来是为了让**只有它**跟着源列表刷新，不把整个 WebView 重建。
class _CurrentSourceLabel extends StatelessWidget {
  const _CurrentSourceLabel();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: webHomeSourcesTick,
      builder: (context, _, _) {
        final sources = WebHomePrefs.instance.sources;
        if (sources.isEmpty) return const SizedBox.shrink();
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text(
            WebHomePrefs.instance.current.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      },
    );
  }
}

/// 网页切换面板 —— **照 RSS / 影视模块的 `SourceSwitchSheet` 版式做**：
///   拖拽条 → 「标题 + 定位 + 网格/列表切换」→ 搜索胶囊 →
///   2 列卡片（3.4 纵横比）/ 单列行 → 底部「网页管理」入口
///
/// 用户 2026-10-15：「网页的顶栏也参考 RSS 那种」。
class _WebSourceSwitchSheet extends StatefulWidget {
  const _WebSourceSwitchSheet({
    required this.sources,
    required this.selectedId,
    required this.onPick,
    required this.onManage,
  });

  final List<WebHomeSource> sources;
  final String selectedId;
  final ValueChanged<String> onPick;
  final VoidCallback onManage;

  @override
  State<_WebSourceSwitchSheet> createState() => _WebSourceSwitchSheetState();
}

class _WebSourceSwitchSheetState extends State<_WebSourceSwitchSheet> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String _kw = '';

  /// false=单列列表 / true=双排网格（默认双排，与 RSS / 影视面板一致）
  bool _grid = true;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<WebHomeSource> get _list {
    if (_kw.isEmpty) return widget.sources;
    final k = _kw.toLowerCase();
    return widget.sources
        .where((s) => s.name.toLowerCase().contains(k))
        .toList();
  }

  /// 定位到当前选中的网页（与 RSS / 影视面板同款）。
  ///
  /// 用**算术**算行偏移，不用 `ensureVisible` —— 选中的源常在很下面、
  /// 还没被 build，那时拿不到 context。
  void _locate() {
    final list = _list;
    final i = list.indexWhere((s) => s.id == widget.selectedId);
    if (i < 0 || !_scroll.hasClients) return;
    final w = MediaQuery.of(context).size.width;
    // 与下面网格参数保持一致：2 列 / 间距 10 / 纵横比 3.4 / 行距 8
    final rowH = _grid ? ((w - 32 - 10) / 2) / 3.4 + 8 : 52.0;
    final offset = _grid ? (i ~/ 2) * rowH : i * rowH;
    final pos = _scroll.position;
    _scroll.animateTo(
      offset.clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 15, color: AppTheme.textSecondary),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final list = _list;
    return Container(
      height: (h * 0.4).clamp(h * 0.34, h * 0.48),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 10, bottom: 4),
              child: SheetHandle(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Text('切换网页',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  _circleBtn(Icons.my_location_rounded, _locate),
                  const SizedBox(width: 8),
                  _circleBtn(
                    _grid ? Icons.view_list_outlined : Icons.grid_view_outlined,
                    () => setState(() => _grid = !_grid),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search, size: 16, color: AppTheme.textTertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: (v) => setState(() => _kw = v.trim()),
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索网页',
                          hintStyle: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: AppTheme.textTertiary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: list.isEmpty
                  ? Center(
                      child: Text('未找到匹配的网页',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: AppTheme.textTertiary)),
                    )
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [
                        if (_grid)
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 10,
                              childAspectRatio: 3.4,
                            ),
                            itemCount: list.length,
                            itemBuilder: (c, i) => _tile(list[i]),
                          )
                        else
                          for (final s in list)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: _row(s),
                            ),
                      ],
                    ),
            ),
            // 底部入口：去管理页导入 / 排序 / 删除
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.pop(context);
                widget.onManage();
              },
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.borderLight, width: 0.5),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.tune_rounded,
                        size: 16, color: AppTheme.textSecondary),
                    const SizedBox(width: 6),
                    Text('Webhtv 管理',
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: AppTheme.textPrimary)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pick(WebHomeSource s) {
    Navigator.pop(context);
    widget.onPick(s.id);
  }

  /// 副标题：远端源显示完整地址；内置 / 本地显示「形态 · 文件名」
  String _sub(WebHomeSource s) => s.kind == WebHomeSourceKind.url
      ? s.value
      : '${s.kind.label} · ${s.value.split('/').last}';

  /// 网格卡片：首字头像 + 名称 + 地址
  Widget _tile(WebHomeSource s) {
    final on = s.id == widget.selectedId;
    return GestureDetector(
      onTap: () => _pick(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on
                ? AppTheme.accentColor.withValues(alpha: 0.5)
                : AppTheme.borderLight,
            width: on ? 1 : 0.5,
          ),
        ),
        child: Row(
          children: [
            CardGridAvatar(s.name, selected: on),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 2),
                  Text(_sub(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: AppTheme.textTertiary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 单列行
  Widget _row(WebHomeSource s) {
    final on = s.id == widget.selectedId;
    return GestureDetector(
      onTap: () => _pick(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: on
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on
                ? AppTheme.accentColor.withValues(alpha: 0.5)
                : AppTheme.borderLight,
            width: on ? 1 : 0.5,
          ),
        ),
        child: Row(
          children: [
            CardGridAvatar(s.name, selected: on),
            const SizedBox(width: 10),
            Expanded(
              child: Text(s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                      color: AppTheme.textPrimary)),
            ),
            if (on)
              Icon(Icons.check_circle_rounded,
                  size: 16, color: AppTheme.accentColor),
          ],
        ),
      ),
    );
  }
}
