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
///   1. 用户点 PiP / 退后台自动 → Dart 收集 url / headers / 当前进度 → startPip
///   2. 本类创建 AVPlayer + AVPlayerLayer（透明容器插到 window 最底层，
///      不遮挡 Flutter 画面），seek 到当前进度，startPictureInPicture()
///      启动系统悬浮窗
///   3. 主播放器（media_kit）由 Dart 侧在收到 onPipStarted（系统 PiP 真正出现）
///      后暂停，避免双路声音 / 解码
///   4. PiP 结束（用户关闭窗口 / 点"返回App" / 手动退出）→
///      delegate 回调 → channel 通知 Dart → 主播放器 seek 续播
///
/// 前置条件（NewTv 已具备）：
///   - Info.plist UIBackgroundModes 含 audio ✅（已有）
///   - AVAudioSession .playback（BackgroundAudio.swift 已激活）✅
///   - 无需特殊 entitlement（TrollStore 侧载可用）✅
///
/// 稳定性修复 v4（2026-09-26）：
///   旧版根因导致"画中画时灵时不灵"：
///   a) 后台才调 startPip：App 已进后台才创建 AVPlayer 等 readyToPlay，
///      后台缓冲慢/受限，15s 超时或系统拒绝启动 → 无小窗但主播放器还在播。
///   b) http 明文源：原生 AVPlayer 受 ATS 限制，http:// m3u8 直接加载失败
///      （Info.plist 已放行 NSAllowsArbitraryLoads）；media_kit 自己的网络栈
///      不受 ATS 影响 → "主播放器能播、PiP 失败"。
///   c) v2/v3 的 appDidEnterBackground 只要求 preparedReady / 只要求实例存在
///      才启动，但存在竞态：原生已 startPictureInPicture（didStart 尚未回调，
///      isActive 仍为 false）时，Dart 侧 paused 回调又调 enterIos → startPip
///      开头 `if pipController != nil { cleanup() }` 会把刚启动的实例销毁 →
///      自动 PiP 时灵时不灵。
///
///   修复（v4）：
///   - preparePip(url, headers)：**前台播放时预热**创建 AVPlayer，静音预缓冲
///     并常驻待命（readyToPlay 后保持），退后台/点 PiP 时立即启动。
///   - startPip 复用路径：**存在常驻实例（同 URL，无论是否就绪）即 seek + 启动**，
///     不再 cleanup 销毁；实例正处启动中（startingPip，didStart 未回调）时
///     直接回传成功，消除双路径竞态。
///   - appDidEnterBackground：只要存在常驻实例且未在 PiP，即启动系统悬浮窗；
///     预热中（源慢）时窗口先出现，AVPlayer 缓冲完成后面面自然呈现。
///   - 真实激活由 pictureInPictureControllerDidStartPictureInPicture 确认，
///     并通过通道事件 onPipStarted 通知 Dart 暂停主播放器。
///
/// 无声修复 v5（2026-09-26）：
///   "自动小窗能播但没有声音、手动有声" 的根因：主播放器(mpv)仍占用
///   AVAudioSession 时启动 AVPlayer PiP，audio session 未激活/被抢占 →
///   小窗有画面无声音。修复：
///   - Dart 侧进 PiP 前先暂停主播放器释放 session（见 video_player.dart）
///   - 原生侧所有启动路径（复用/慢路径/退后台/didStart）统一先
///     activateAudioSession() 激活 .playback session，再 play
class PipManager: NSObject, AVPictureInPictureControllerDelegate {
  static let shared = PipManager()

  private var channel: FlutterMethodChannel?
  private var pipController: AVPictureInPictureController?
  private var pipPlayer: AVPlayer?
  private var pipLayer: AVPlayerLayer?
  private var containerView: UIView?

  // -- 启动门闩（懒加载路径：等 readyToPlay 再进 PiP）--
  private var itemStatusObserver: NSKeyValueObservation?
  private var startTimeoutWork: DispatchWorkItem?
  /// 是否有待启动请求（等就绪后自动进 PiP）
  private var pendingStart = false
  /// 挂起的 startPip result（就绪/失败后才回传）
  private var startResult: FlutterResult?

  // -- 预热常驻状态 --
  /// 常驻实例已 readyToPlay，可直接启动 PiP
  private var preparedReady = false
  /// 预热时的源 URL（换源时重建实例）
  private var preparedURL = ""

  /// 是否正在启动 PiP（startPictureInPicture 已调用、didStart 尚未回调）
  /// 用于消除原生退后台自动触发与 Dart paused 回调的竞态：
  /// 启动中收到重复 startPip 时直接回传成功，不销毁实例。
  private var startingPip = false

  /// 当前是否处于系统 PiP（didStart 置 true，didStop 置 false）
  private(set) var isActive = false
  /// PiP 最后播放位置（秒，供 Dart 恢复主播放器进度）
  private(set) var lastPositionSeconds: Double = 0

  private override init() {
    super.init()
    // 退后台自动启动 PiP：前台已预热（含预热中）时，进后台瞬间直接启动系统悬浮窗
    // （比 Dart 侧 AppLifecycleState 回调更早、更稳，且此时 AVPlayer 已开始缓冲）
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

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
      case "preparePip":
        // 前台预热：静音预缓冲 AVPlayer 并常驻待命（不启动 PiP）
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty else {
          result(FlutterError(code: "bad_args", message: "缺少播放地址", details: nil))
          return
        }
        let headers = args["headers"] as? [String: String] ?? [:]
        self.preparePip(url: url, headers: headers)
        result(nil)
      case "releasePip":
        // 离开播放页：释放常驻实例
        self.releasePip()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSLog("[PipManager] channel registered")
  }

  // MARK: - 前台预热（常驻待命）

  /// 前台播放时预热：创建 AVPlayer 静音预缓冲，readyToPlay 后常驻待命。
  /// 同一 URL 已就绪则直接复用；换源时重建。
  private func preparePip(url: String, headers: [String: String]) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    // 同一 URL 已预热就绪：直接复用
    if preparedReady, preparedURL == url { return }
    // 换源 / 首次：重建常驻实例
    if pipController != nil { cleanup() }
    guard let videoURL = URL(string: url) else { return }

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
    guard let window = Self.keyWindow() else { return }
    let container = UIView(frame: window.bounds)
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false
    window.insertSubview(container, at: 0)
    layer.frame = container.bounds
    layer.videoGravity = .resizeAspect
    container.layer.addSublayer(layer)

    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      container.removeFromSuperview()
      return
    }

    controller.delegate = self
    pipController = controller
    pipPlayer = player
    pipLayer = layer
    containerView = container
    preparedURL = url
    preparedReady = false

    // 监听 readyToPlay：就绪后置 preparedReady，等待退后台/手动启动
    itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if item.status == .readyToPlay {
          self.preparedReady = true
          NSLog("[PipManager] prepared ready: \(url)")
        } else if item.status == .failed {
          NSLog("[PipManager] prepare failed: \(item.error?.localizedDescription ?? "未知")")
          // 预热失败：释放实例（下次播放状态变化会重新预热）
          self.cleanup()
        }
      }
    }

    // 静音预缓冲：避免与主播放器双路声音
    player.volume = 0
    player.play()
    NSLog("[PipManager] preparePip (prewarm): \(url)")
  }

  /// 离开播放页：释放常驻实例
  func releasePip() {
    NSLog("[PipManager] releasePip")
    cleanup()
    preparedURL = ""
  }

  // MARK: - 启动 PiP

  private func startPip(url: String, headers: [String: String], positionMs: Double, result: @escaping FlutterResult) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(code: "unsupported", message: "当前设备不支持画中画", details: nil))
      return
    }
    guard URL(string: url) != nil else {
      result(FlutterError(code: "bad_url", message: "播放地址无效", details: nil))
      return
    }

    // ---- 复用路径：存在常驻实例（同 URL，无论是否就绪）→ 立即启动 ----
    if let controller = pipController, preparedURL == url {
      // 实例正处启动中（退后台自动触发 / 上一步手动发起，didStart 未回调）：
      // 不重复启动、不销毁，直接回传成功，消除双路径竞态。
      if isActive || startingPip {
        result(nil)
        return
      }
      NSLog("[PipManager] startPip (reuse, preparedReady=\(preparedReady))")
      activateAudioSession()
      if positionMs > 0 {
        pipPlayer?.seek(to: CMTime(seconds: positionMs / 1000.0, preferredTimescale: 600))
      }
      pipPlayer?.volume = 1.0 // 恢复音量（PiP 悬浮窗需要声音）
      pipPlayer?.play()
      startingPip = true
      controller.startPictureInPicture()
      // 真实激活由 didStart / didStop 回调维护，这里只回传"已发起"
      result(nil)
      return
    }

    // ---- 慢路径：无同 URL 常驻实例（懒加载 + 门闩，兜底）----
    // 已有不同源实例 / 待启动请求先清理
    if pipController != nil || pendingStart { cleanup() }
    guard let videoURL = URL(string: url) else {
      result(FlutterError(code: "bad_url", message: "播放地址无效", details: nil))
      return
    }

    var options: [String: Any] = [:]
    if !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: videoURL, options: options)
    let playerItem = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: playerItem)
    let layer = AVPlayerLayer(player: player)

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
    preparedURL = url

    activateAudioSession()
    // 从当前进度续播
    if positionMs > 0 {
      player.seek(to: CMTime(seconds: positionMs / 1000.0, preferredTimescale: 600))
    }

    // ---- 启动门闩：等 item 就绪再进系统 PiP ----
    startResult = result
    pendingStart = true
    preparedReady = false

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

    player.volume = 1.0
    player.play() // 预缓冲（先出声音，进 PiP 后无感切换）
    NSLog("[PipManager] startPip(slow path, await-ready): \(url)")
  }

  /// item 状态变化处理（懒加载路径）
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

  /// 就绪后真正启动系统 PiP（懒加载路径）
  private func doStartPiP() {
    guard pendingStart, let controller = pipController else { return }
    pendingStart = false
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    // 回传"已发起"：Dart 侧等 onPipStarted 真实激活后再暂停主播放器
    startResult?(nil)
    startResult = nil
    preparedReady = true
    pipPlayer?.volume = 1.0
    startingPip = true
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
    NSLog("[PipManager] stopPip (isActive=\(isActive), pendingStart=\(pendingStart), startingPip=\(startingPip))")
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
    // 常驻实例未在 PiP：暂停保持待命（不销毁，下次可快路径启动）
    pipPlayer?.pause()
  }

  private func cleanup() {
    itemStatusObserver?.invalidate()
    itemStatusObserver = nil
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    pendingStart = false
    startingPip = false
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
    preparedReady = false
  }

  // MARK: - 退后台自动启动 PiP

  /// 激活音频会话：AVPlayer 出声的前提。App 退后台 / 启动 PiP 前调用，
  /// 修复"自动小窗无声"：主播放器(mpv)暂停后 audio session 可能被释放/
  /// 停用，AVPlayer 启动时如果没有 active 的 playback session 会无声。
  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
      NSLog("[PipManager] audio session activated (playback)")
    } catch {
      NSLog("[PipManager] activateAudioSession failed: \(error.localizedDescription)")
    }
  }

  /// App 进入后台：**只要存在常驻实例、未在 PiP 且未在启动中**，立即启动系统悬浮窗。
  /// 不再要求 preparedReady——预热中（源加载慢）退后台时，PiP 窗口先出现
  /// （黑屏/loading），AVPlayer 缓冲完成后画面自然呈现，避免"退后台只有声音没有小窗"。
  @objc private func appDidEnterBackground() {
    NSLog("[PipManager] appDidEnterBackground (preparedReady=\(preparedReady), isActive=\(isActive), startingPip=\(startingPip))")
    guard !isActive, !startingPip, let controller = pipController else { return }
    activateAudioSession()
    pipPlayer?.volume = 1.0
    pipPlayer?.play()
    startingPip = true
    controller.startPictureInPicture()
    // 真实激活由 didStart 回调确认并通知 Dart
    NSLog("[PipManager] auto startPictureInPicture on background (preparedReady=\(preparedReady))")
  }

  // MARK: - AVPictureInPictureControllerDelegate

  /// 系统 PiP 悬浮窗真正出现
  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    NSLog("[PipManager] didStartPictureInPicture")
    isActive = true
    startingPip = false
    // **修复自动小窗无声**: PiP 激活瞬间再确保 audio session 激活 +
    // 音量恢复 + 继续播放。主播放器刚暂停, audio session 归 AVPlayer,
    // 这里显式激活保证小窗一定有声音。
    activateAudioSession()
    pipPlayer?.volume = 1.0
    pipPlayer?.play()
    // 通知 Dart：PiP 真实激活，主播放器可以暂停了（避免双路声音）
    notifyFlutter("onPipStarted", position: 0)
  }

  /// 用户点了 PiP 悬浮窗的关闭（×）或 PiP 被系统终止
  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    NSLog("[PipManager] didStopPictureInPicture")
    lastPositionSeconds = pipPlayer?.currentTime().seconds ?? 0
    notifyFlutter("onPipStopped", position: lastPositionSeconds)
    cleanup()
  }

  /// 用户点了 PiP 悬浮窗的"返回 App"按钮
  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    NSLog("[PipManager] restoreUserInterface")
    lastPositionSeconds = pipPlayer?.currentTime().seconds ?? 0
    notifyFlutter("onPipStopped", position: lastPositionSeconds)
    completionHandler(true)
    // 延迟清理，避免切回 App 时画面闪烁
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.cleanup()
    }
  }

  private func notifyFlutter(_ method: String, position: Double) {
    let args: [String: Any] = ["position": position]
    channel?.invokeMethod(method, arguments: args)
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
