import AVKit
import AVFoundation
import Flutter
import UIKit

/// iOS 系统画中画（PiP）管理器
///
/// 背景：
///   NewTv 主播放器是 media_kit（libmpv 渲染到 Flutter 纹理），
///   系统级画中画（悬浮小窗 + 切后台继续播放）只支持 AVPlayerLayer，
///   libmpv 纹理无法直接进入系统 PiP。
///
/// 方案（双播放器 PiP 通道）：
///   1. 用户点 PiP → Dart 收集 url / headers / 当前进度 → startPip
///   2. 本类创建 AVPlayer + AVPlayerLayer（透明容器插到 window 最底层，
///      不遮挡 Flutter 画面），seek 到当前进度，startPictureInPicture()
///      启动系统悬浮窗
///   3. 主播放器（media_kit）由 Dart 侧暂停，避免双路声音 / 解码
///   4. PiP 结束（用户关闭窗口 / 点"返回App" / 手动退出）→
///      delegate 回调 → channel 通知 Dart → 主播放器 seek 续播
///
/// 前置条件（NewTv 已具备）：
///   - Info.plist UIBackgroundModes 含 audio ✅（已有）
///   - AVAudioSession .playback（BackgroundAudio.swift 已激活）✅
///   - 无需特殊 entitlement（TrollStore 侧载可用）
///
/// 稳定性修复（2026-09-26）：
///   - 旧版在 AVPlayerItem 尚未就绪（readyToPlay）时立即调
///     startPictureInPicture()，网络流缓冲未完成时系统会静默拒绝启动，
///     表现为"画中画时灵时不灵"。
///   - 现改为：先 play() 预缓冲，监听 item.status 到 .readyToPlay 后再
///     启动系统 PiP；15s 超时 / 加载失败回传 FlutterError 给 Dart 提示。
///   - 真实激活状态由 pictureInPictureControllerDidStartPictureInPicture
///     回调确认，避免"假 PiP"（Dart 侧以为已进入，实际没有）。
class PipManager: NSObject, AVPictureInPictureControllerDelegate {
  static let shared = PipManager()

  private var channel: FlutterMethodChannel?
  private var pipController: AVPictureInPictureController?
  private var pipPlayer: AVPlayer?
  private var pipLayer: AVPlayerLayer?
  private var containerView: UIView?

  // -- 启动门闩（等 readyToPlay 再进 PiP）--
  private var itemStatusObserver: NSKeyValueObservation?
  private var startTimeoutWork: DispatchWorkItem?
  /// 是否有待启动请求（等就绪后自动进 PiP）
  private var pendingStart = false
  /// 挂起的 startPip result（就绪/失败后才回传）
  private var startResult: FlutterResult?

  /// 当前是否处于系统 PiP（didStart 置 true，didStop 置 false）
  private(set) var isActive = false
  /// PiP 最后播放位置（秒，供 Dart 恢复主播放器进度）
  private(set) var lastPositionSeconds: Double = 0

  private override init() { super.init() }

  // MARK: - 注册（AppDelegate.didInitializeImplicitFlutterEngine 调）

  func register(with messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "pip_manager", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "nil", message: "PipManager 已释放", details: nil))
        return
      }
      switch call.method {
      case "isPipSupported":
        result(AVPictureInPictureController.isPictureInPictureSupported())
      case "startPip":
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty else {
          result(FlutterError(code: "bad_args", message: "缺少播放地址", details: nil))
          return
        }
        let headers = args["headers"] as? [String: String] ?? [:]
        let positionMs = (args["position"] as? NSNumber)?.doubleValue ?? 0
        self.startPip(url: url, headers: headers, positionMs: positionMs, result: result)
      case "stopPip":
        self.stopPip()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSLog("[PipManager] channel registered")
  }

  // MARK: - 启动 PiP

  private func startPip(url: String, headers: [String: String], positionMs: Double, result: @escaping FlutterResult) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(code: "unsupported", message: "当前设备不支持画中画", details: nil))
      return
    }
    guard let videoURL = URL(string: url) else {
      result(FlutterError(code: "bad_url", message: "播放地址无效", details: nil))
      return
    }
    // 已有 PiP / 待启动请求先清理
    if pipController != nil || pendingStart { cleanup() }

    var options: [String: Any] = [:]
    if !headers.isEmpty {
      // AVURLAssetHTTPHeaderFieldsKey 在新版 iOS SDK 中已不可见（deprecated 后移除），
      // 其值即字符串字面量 "AVURLAssetHTTPHeaderFieldsKey"，直接使用等价。
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: videoURL, options: options)
    let playerItem = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: playerItem)
    let layer = AVPlayerLayer(player: player)

    // AVPlayerLayer 必须挂到 window 层级才能启动 PiP。
    // 用全屏透明容器插到 window 最底层，不遮挡 Flutter 画面。
    guard let window = Self.keyWindow() else {
      result(FlutterError(code: "no_window", message: "无法获取窗口", details: nil))
      return
    }
    let container = UIView(frame: window.bounds)
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false
    window.insertSubview(container, at: 0)
    layer.frame = container.bounds
    layer.videoGravity = .resizeAspect
    container.layer.addSublayer(layer)

    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      container.removeFromSuperview()
      result(FlutterError(code: "pip_init_failed", message: "画中画控制器创建失败", details: nil))
      return
    }

    controller.delegate = self
    pipController = controller
    pipPlayer = player
    pipLayer = layer
    containerView = container

    // 从当前进度续播
    if positionMs > 0 {
      player.seek(to: CMTime(seconds: positionMs / 1000.0, preferredTimescale: 600))
    }

    // ---- 启动门闩：等 item 就绪再进系统 PiP ----
    // 网络流（m3u8/mp4）缓冲需要 1~3 秒，立即 startPictureInPicture()
    // 在未就绪时会被系统静默拒绝 → "时灵时不灵"。先预缓冲，就绪后自动启动。
    startResult = result
    pendingStart = true

    itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard let self = self else { return }
      DispatchQueue.main.async { self.handleItemStatus(item.status) }
    }

    // 15s 兜底：源加载慢 / 网络异常时不能一直挂着
    let timeout = DispatchWorkItem { [weak self] in
      self?.failStart("画中画启动超时（源加载慢）")
    }
    startTimeoutWork = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)

    player.play() // 预缓冲（先出声音，进 PiP 后无感切换）
    NSLog("[PipManager] startPip(await-ready): \(url)")
  }

  /// item 状态变化处理
  private func handleItemStatus(_ status: AVPlayerItem.Status) {
    switch status {
    case .readyToPlay:
      NSLog("[PipManager] item readyToPlay → start PiP")
      doStartPiP()
    case .failed:
      let reason = pipPlayer?.currentItem?.error?.localizedDescription ?? "未知"
      NSLog("[PipManager] item failed: \(reason)")
      failStart("画中画启动失败：源加载失败（\(reason)）")
    case .unknown:
      break
    @unknown default:
      break
    }
  }

  /// 就绪后真正启动系统 PiP
  private func doStartPiP() {
    guard pendingStart, let controller = pipController else { return }
    pendingStart = false
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    // 回传成功：Dart 侧暂停主播放器，避免双路声音
    startResult?(nil)
    startResult = nil
    controller.startPictureInPicture()
    // 真实激活状态由 didStart / didStop 回调维护，这里不置位
    NSLog("[PipManager] startPictureInPicture() called")
  }

  /// 启动失败统一出口（超时 / 加载失败 / 其它）
  private func failStart(_ message: String) {
    guard pendingStart else { return }
    pendingStart = false
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    startResult?(FlutterError(code: "pip_start_failed", message: message, details: nil))
    startResult = nil
    NSLog("[PipManager] failStart: \(message)")
    cleanup()
  }

  // MARK: - 停止 PiP

  func stopPip() {
    NSLog("[PipManager] stopPip (isActive=\(isActive), pendingStart=\(pendingStart))")
    if isActive {
      lastPositionSeconds = pipPlayer?.currentTime().seconds ?? 0
      pipController?.stopPictureInPicture()
      // didStop delegate 里会 notify + cleanup，这里只触发停止
      return
    }
    if pendingStart {
      // 启动门闩未完成时被要求退出：直接放弃启动
      startResult?(nil)
      startResult = nil
    }
    cleanup()
  }

  private func cleanup() {
    itemStatusObserver?.invalidate()
    itemStatusObserver = nil
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    pendingStart = false
    if startResult != nil {
      startResult?(nil)
      startResult = nil
    }
    pipPlayer?.pause()
    pipPlayer = nil
    pipLayer?.removeFromSuperlayer()
    pipLayer = nil
    containerView?.removeFromSuperview()
    containerView = nil
    pipController = nil
    isActive = false
  }

  // MARK: - AVPictureInPictureControllerDelegate

  /// 系统 PiP 悬浮窗真正出现
  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    NSLog("[PipManager] didStartPictureInPicture")
    isActive = true
  }

  /// 用户点了 PiP 悬浮窗的关闭（×）或 PiP 被系统终止
  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    NSLog("[PipManager] didStopPictureInPicture")
    lastPositionSeconds = pipPlayer?.currentTime().seconds ?? 0
    notifyFlutter()
    cleanup()
  }

  /// 用户点了 PiP 悬浮窗的"返回 App"按钮
  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    NSLog("[PipManager] restoreUserInterface")
    lastPositionSeconds = pipPlayer?.currentTime().seconds ?? 0
    notifyFlutter()
    completionHandler(true)
    // 延迟清理，避免切回 App 时画面闪烁
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.cleanup()
    }
  }

  private func notifyFlutter() {
    let args: [String: Any] = ["position": lastPositionSeconds]
    channel?.invokeMethod("onPipStopped", arguments: args)
  }

  // MARK: - 工具

  static func keyWindow() -> UIWindow? {
    if #available(iOS 15.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first
    }
    return UIApplication.shared.windows.first { $0.isKeyWindow }
  }
}
