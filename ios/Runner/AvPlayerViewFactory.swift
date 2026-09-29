import AVFoundation
import Flutter
import UIKit

/// 应用内预览层：与 PiP 共用 AvEngine.shared.player
final class AvPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return AvPlayerPlatformView(frame: frame)
  }
}

/// 触摸穿透到 Flutter（顶栏/底栏可点）
private final class AvPassthroughView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    return nil
  }
}

/// 关键：layerClass 必须是 AVPlayerLayer（而不是把 AVPlayerLayer 当 sublayer）。
/// Flutter UiKitView 里 sublayer 方式经常「有声无画」；layerClass 方式渲染稳定。
private final class AvPlayerHostView: AvPassthroughView {
  override class var layerClass: AnyClass {
    return AVPlayerLayer.self
  }

  var playerLayer: AVPlayerLayer {
    return self.layer as! AVPlayerLayer
  }
}

final class AvPlayerPlatformView: NSObject, FlutterPlatformView {
  private let host: AvPlayerHostView

  init(frame: CGRect) {
    host = AvPlayerHostView(frame: frame)
    host.isUserInteractionEnabled = false
    super.init()

    let pl = host.playerLayer
    pl.player = AvEngine.shared.player
    pl.videoGravity = .resizeAspect
    // PiP 用同一 layer
    AvEngine.shared.displayLayer = pl
    AvEngine.shared.displayContainer = host
    NSLog("[AvPlayerView] host layerClass=AVPlayerLayer frame=\(frame)")
  }

  func view() -> UIView {
    return host
  }

  func layout(_ frame: CGRect) {
    host.frame = frame
    // layerClass 的 root layer 需要跟 bounds 对齐
    host.playerLayer.frame = host.bounds
    host.playerLayer.videoGravity = .resizeAspect
  }

  deinit {
    if AvEngine.shared.displayContainer === host {
      AvEngine.shared.displayContainer = nil
      AvEngine.shared.displayLayer = nil
    }
  }
}
