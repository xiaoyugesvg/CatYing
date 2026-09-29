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

/// 应用内预览：layerClass=AVPlayerLayer（稳定出画）+ 触摸穿透到 Flutter。
/// 注意：不要把 AVPlayerLayer 当 sublayer，也不要从 final 类再继承。
private final class AvPlayerHostView: UIView {
  override class var layerClass: AnyClass {
    return AVPlayerLayer.self
  }

  var playerLayer: AVPlayerLayer {
    return self.layer as! AVPlayerLayer
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    return nil
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
