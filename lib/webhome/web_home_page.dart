import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:webview_flutter/webview_flutter.dart';

import '../common/theme.dart';
import '../miniapp/services/ant_bridge.dart';
import '../services/app_log.dart';
import '../services/main_tab_controller.dart';
import '../services/webview_page_color.dart';
import '../widgets/common_widgets.dart';
import 'web_home_fm_shim.dart';
import 'web_home_manage_page.dart';
import 'web_home_prefs.dart';
import 'web_home_source.dart';

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

  @override
  void initState() {
    super.initState();
    AntBridge.configure(appId: _appId, permissions: _permissions);
    // 网页里调 `ant.exitMiniApp()` → 切回影视首页 tab
    //（本模块是底栏 tab，没有"返回上一页"这回事）
    AntBridge.onExitRequested = () {
      if (!mounted) return;
      MainTabController.instance.select(MainTabController.videoTabIndex);
    };
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
    // 网页源列表/选中项变化（管理页增删改排序 / 切换）→ 跟着刷新
    webHomeSourcesTick.addListener(_onSourcesChanged);
    _loadEntry();
  }

  @override
  void dispose() {
    webHomeSourcesTick.removeListener(_onSourcesChanged);
    super.dispose();
  }

  /// 源列表变了：换了源就重新加载，只是顺序/名字变了就只重建界面。
  void _onSourcesChanged() {
    if (!mounted) return;
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

  /// 切换网页：**卡片网格**（一行 2 个）—— 用户 2026-10-15：
  /// 「弹窗也太丑了，要卡片式的，一行 2-3 个这种」。
  Future<void> _pickSource() async {
    final prefs = WebHomePrefs.instance;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text('切换网页',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('长按拖动排序在「网页管理」',
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption)),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: CardGrid(
                    columns: 2,
                    children: [
                      for (final s in prefs.sources)
                        CardGridItem(
                          title: s.name,
                          subtitle: s.kind == WebHomeSourceKind.url
                              ? s.value
                              : '${s.kind.label} · ${s.value.split('/').last}',
                          selected: s.id == prefs.selectedId,
                          leading: CardGridAvatar(s.name,
                              selected: s.id == prefs.selectedId),
                          onTap: () {
                            Navigator.pop(ctx);
                            if (s.id != prefs.selectedId) prefs.select(s.id);
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              CardGridItem(
                icon: Icons.settings_outlined,
                title: '网页管理',
                subtitle: '导入订阅链接 / 本地文件、排序、改名、删除',
                onTap: () {
                  Navigator.pop(ctx);
                  _openManage();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 状态栏那一条：刷成**当前网页的主色**（取不到就透明 ⇒ 透出壁纸，与改造前一致）。
    final topInset = MediaQuery.paddingOf(context).top;
    final pageColor = _pageColor;
    Widget page = Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: Column(
        children: [
          Container(height: topInset, color: pageColor),
          // ── 顶栏：左「网页」+ 右「源切换 / 设置」──
          SizedBox(
            height: 46,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Text('网页',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                // 顺带显示"当前是哪个网页"，一眼知道在看哪个
                const _CurrentSourceLabel(),
                IconButton(
                  tooltip: '切换网页',
                  iconSize: 20,
                  onPressed: _pickSource,
                  icon: Icon(Icons.swap_horiz_rounded,
                      color: AppTheme.textPrimary),
                ),
                IconButton(
                  tooltip: '网页管理',
                  iconSize: 20,
                  onPressed: _openManage,
                  icon: Icon(Icons.tune_rounded, color: AppTheme.textPrimary),
                ),
                const SizedBox(width: 4),
              ],
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
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(
            WebHomePrefs.instance.current.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: AppTheme.fontCaption),
          ),
        );
      },
    );
  }
}
