import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

/// 画中画管理器
///
/// **桌面端** (Windows/macOS/Linux)：通过 window_manager 实现桌面级悬浮窗口：
///   - 窗口置顶 (alwaysOnTop)
///   - 调整窗口为小尺寸悬浮窗 (默认 480x270 - 16:9)
///   - 移动到屏幕右下角
///
/// **iOS 端**：系统级画中画（悬浮小窗 + 切后台继续播放），
/// 由原生 PipManager.swift 实现（AVPlayer + AVPictureInPictureController），
/// 本类通过 "pip_manager" MethodChannel 桥接：
///   - 进入：把 url/headers/当前进度交给原生，原生起系统 PiP 悬浮窗，
///     主播放器（media_kit）由调用方**在收到 onPipStarted（PiP 真实激活）后**
///     暂停，避免双路声音/解码
///   - 退出：原生 delegate 回调 onPipStopped → 通知调用方恢复主播放器
///
/// **稳定性 v2（2026-09-26）**：
///   - 新增 [prepareIos]：前台播放时预热原生 AVPlayer（静音预缓冲常驻），
///     退后台/手动点 PiP 时原生立即 startPictureInPicture（毫秒级），
///     不再"后台等缓冲"导致 PiP 时灵时不灵。
///   - 新增 [releaseIos]：离开播放页时释放常驻实例。
///   - 新增 onPipStarted 通道事件：系统 PiP 悬浮窗真正出现才置 isIosActive
///     并回调 [onStarted]，避免"假 PiP"（Dart 侧以为已进入、实际没有）。
///
/// 注意：iOS 系统 PiP 是独立悬浮窗，**不**翻转 activeNotifier
/// （activeNotifier 驱动 detail view 的 immersive 模式，仅桌面端小窗需要）。
class VideoPlayerPip {
  static final VideoPlayerPip instance = VideoPlayerPip._();
  VideoPlayerPip._() {
    // iOS：注册原生 PiP 回调通道
    if (Platform.isIOS) {
      _iosChannel.setMethodCallHandler(_handleIosCall);
    }
  }
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// iOS 系统 PiP 通道（对应 ios/Runner/PipManager.swift）
  static const MethodChannel _iosChannel = MethodChannel('pip_manager');

  // ========== 桌面端状态 ==========
  bool _isActive = false;
  Rect? _savedBounds;
  Player? _attachedPlayer;
  /// 当前是否处于画中画模式（桌面端悬浮窗）
  bool get isActive => _isActive;
  /// 监听 PiP 状态变化（用于 detail 页同步隐藏 AppBar 等 UI）
  final ValueNotifier<bool> activeNotifier = ValueNotifier<bool>(false);
  /// 当前已附加的 Player（用于上层构建 PiP 预览视图）
  Player? get attachedPlayer => _attachedPlayer;

  // ========== iOS 系统 PiP 状态 ==========
  bool _iosActive = false;
  double _iosLastPosition = 0;
  VoidCallback? _iosOnStopped;
  VoidCallback? _iosOnStarted;
  /// iOS 是否处于系统画中画
  bool get isIosActive => _iosActive;
  /// iOS PiP 最后播放位置（供主播放器恢复进度）
  Duration get iosLastPosition =>
      Duration(milliseconds: (_iosLastPosition * 1000).round());

  Future<void> _handleIosCall(MethodCall call) async {
    switch (call.method) {
      case 'onPipStarted':
        // 系统 PiP 悬浮窗真正出现 → 置激活状态，通知调用方暂停主播放器
        _iosActive = true;
        final cb = _iosOnStarted;
        _iosOnStarted = null;
        cb?.call();
        break;
      case 'onPipStopped':
        final args = call.arguments as Map<dynamic, dynamic>? ?? {};
        _iosLastPosition = (args['position'] as num?)?.toDouble() ?? 0;
        final cb = _iosOnStopped;
        _iosOnStopped = null;
        _iosActive = false;
        cb?.call();
        break;
      default:
        break;
    }
  }

  /// iOS：设备是否支持系统画中画（模拟器 false，真机 true）
  Future<bool> isIosPipSupported() async {
    if (!Platform.isIOS) return false;
    try {
      return await _iosChannel.invokeMethod<bool>('isPipSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// iOS：前台预热原生 AVPlayer（静音预缓冲并常驻待命）。
  /// 播放开始/换源时调用，退后台或手动点 PiP 时原生可直接启动（毫秒级）。
  Future<void> prepareIos({
    required String url,
    Map<String, String>? headers,
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _iosChannel.invokeMethod<void>('preparePip', {
        'url': url,
        'headers': headers ?? const <String, String>{},
      });
    } catch (e) {
      debugPrint('[VideoPlayerPip] prepare failed: $e');
    }
  }

  /// iOS：释放原生常驻 PiP 实例（离开播放页时调用）
  Future<void> releaseIos() async {
    if (!Platform.isIOS) return;
    try {
      await _iosChannel.invokeMethod<void>('releasePip');
    } catch (_) {}
  }

  /// iOS：进入系统画中画
  /// - [url] 播放地址
  /// - [headers] 请求头（Referer / User-Agent 等）
  /// - [position] 当前进度（原生 AVPlayer 从此处续播）
  /// - [onStarted] 原生 PiP 悬浮窗**真正出现**时回调（调用方暂停主播放器）
  /// - [onStopped] 原生 PiP 结束时回调（调用方恢复主播放器并 seek）
  Future<bool> enterIos({
    required String url,
    Map<String, String>? headers,
    Duration? position,
    VoidCallback? onStopped,
    VoidCallback? onStarted,
  }) async {
    if (!Platform.isIOS) return false;
    // 真正激活中才视为已进入；若状态残留（onPipStopped 丢了）则强制复位后再进
    if (_iosActive) return true;

    _iosOnStopped = onStopped;
    _iosOnStarted = onStarted;
    // 不要清 _iosLastPosition：回退恢复进度还要用
    try {
      // 二次进入前重新预热，避免 cleanup 后 preparedReady=false 导致 startPip 失败
      await prepareIos(url: url, headers: headers);
      await _iosChannel.invokeMethod<void>('startPip', {
        'url': url,
        'headers': headers ?? const <String, String>{},
        'position': position?.inMilliseconds ?? 0,
      });
      // 已发起：等待 onPipStarted 真实激活后再置 isIosActive
      return true;
    } catch (e) {
      _iosOnStopped = null;
      _iosOnStarted = null;
      _iosActive = false;
      final msg = (e is PlatformException) ? '${e.code}: ${e.message}' : e.toString();
      debugPrint('[VideoPlayerPip] iOS enter failed: $msg');
      return false;
    }
  }

  /// iOS：退出系统画中画
  Future<void> exitIos() async {
    if (!Platform.isIOS) return;
    try {
      await _iosChannel.invokeMethod<void>('stopPip');
    } catch (_) {}
    // 无论原生是否在 PiP，都清掉 Dart 状态，避免卡在 isIosActive=true
    // 导致之后无法再进入小窗
    _iosActive = false;
    final cb = _iosOnStopped;
    _iosOnStopped = null;
    _iosOnStarted = null;
    cb?.call();
  }

  /// 强制复位（onPipStopped 丢失 / 二次进入失败时用）
  void resetIosState() {
    _iosActive = false;
    _iosOnStopped = null;
    _iosOnStarted = null;
  }

  // ========== 桌面端入口 API ==========
  /// 附加播放器到 PiP 模块（不创建新 Player，复用已有实例）
  void attachPlayer(Player player) {
    _attachedPlayer = player;
  }

  /// 解除附加
  void detachPlayer() {
    _attachedPlayer = null;
  }

  /// 进入画中画（桌面端悬浮窗）
  Future<void> enter() async {
    if (_isActive) return;
    if (_attachedPlayer == null) {
      debugPrint('[VideoPlayerPip] enter: no player attached');
      return;
    }
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      // 移动端平台：不支持桌面级 PiP 浮动窗口；
      // iOS 请走 enterIos（系统画中画），Android 暂未实现
      debugPrint('[VideoPlayerPip] enter: unsupported platform');
      return;
    }
    try {
      // 1) 保存当前窗口状态（仅大小/位置）
      _savedBounds = await windowManager.getBounds();
      // 注意：不再保存/恢复 OS 全屏 —— 全屏由 VideoPlayerWidget 的
      // _toggleNativeFullscreen 通过 media_kit 的 Utils.EnterNativeFullscreen
      // 管理，与 windowManager.setFullScreen 不是同一个 API，
      // 互相调用会导致窗口状态混乱。
      // 2) 设置窗口为可调整大小（解除最小尺寸限制以便恢复）
      await windowManager.setMinimumSize(const Size(240, 160));
      // 3) 计算悬浮窗位置：屏幕右下角，留 16px 边距
      const pipSize = Size(480, 270); // 16:9
      final screenBounds = _getScreenBounds();
      final pipPosition = Offset(
        screenBounds.right - pipSize.width - 16,
        screenBounds.bottom - pipSize.height - 16,
      );
      // 4) 调整窗口大小并移动到右下角
      await windowManager.setSize(pipSize);
      await windowManager.setPosition(pipPosition);
      // 5) 隐藏窗口标题栏（最大/最小/关闭那一栏），让 PiP 看起来更纯粹
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      // 6) 设置窗口置顶
      await windowManager.setAlwaysOnTop(true);
      _isActive = true;
      activeNotifier.value = true;
      debugPrint('[VideoPlayerPip] enter: PiP active');
    } catch (e, st) {
      debugPrint('[VideoPlayerPip] enter failed: $e\n$st');
      _isActive = false;
      activeNotifier.value = false;
    }
  }

  /// 退出画中画（桌面端悬浮窗）
  Future<void> exit() async {
    if (!_isActive) return;
    try {
      // 1) 取消置顶
      await windowManager.setAlwaysOnTop(false);
      // 2) 恢复窗口标题栏显示
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      // 3) 恢复窗口大小与位置
      if (_savedBounds != null) {
        await windowManager.setSize(_savedBounds!.size);
        await windowManager.setPosition(_savedBounds!.topLeft);
        // 不再恢复 OS 全屏 —— 见 enter() 注释
      }
    } catch (e, st) {
      debugPrint('[VideoPlayerPip] exit failed: $e\n$st');
    } finally {
      _isActive = false;
      _savedBounds = null;
      activeNotifier.value = false;
      debugPrint('[VideoPlayerPip] exit: PiP inactive');
    }
  }

  /// 切换画中画（桌面端悬浮窗）
  Future<void> toggle() async {
    if (_isActive) {
      await exit();
    } else {
      await enter();
    }
  }

  /// 获取屏幕可用区域（用于计算 PiP 悬浮窗位置）
  Rect _getScreenBounds() {
    // 使用 Flutter 的 platformDispatcher 获取屏幕尺寸
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr = view.devicePixelRatio;
    final physicalSize = view.physicalSize;
    final logicalSize = Size(physicalSize.width / dpr, physicalSize.height / dpr);
    final offset = view.viewPadding.top > 0
        ? Offset.zero
        : Offset.zero; // 简化：未考虑多屏场景
    return Rect.fromLTWH(
      offset.dx,
      offset.dy,
      logicalSize.width,
      logicalSize.height,
    );
  }
}
