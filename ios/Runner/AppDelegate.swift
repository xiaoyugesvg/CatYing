import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // NodeJSBridge 持有 platform channel
  private var nodeJSBridge: NodeJSBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.applicationSupportsShakeToEdit = false // Disable shake to undo

    // **2026-07-08 方案 A (Background Audio)**:
    // 启动 silent audio playback, 让 iOS 把 app 当作 "audio app",
    // 维持 app 在后台 / 锁屏时不挂起 embed library (Node.js 进程).
    // 见 BackgroundAudio.swift 详细说明.
    // 必须在 Flutter 引擎启动**之前**调, 否则 iOS 在 Flutter 启动过程中
    // 可能已经判定 app 进入 inactive.
    // 按需保活：不再启动就常驻静音音频；Node 启动后再开，见 NodeJSBridge

    // 监听 lifecycle 事件, 在进入后台前重新激活 audio session
    NotificationCenter.default.addObserver(
      BackgroundAudio.shared,
      selector: #selector(BackgroundAudio.appWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      BackgroundAudio.shared,
      selector: #selector(BackgroundAudio.appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      BackgroundAudio.shared,
      selector: #selector(BackgroundAudio.appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // 注册 Flutter 生态的所有插件
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 注册 NodeJSBridge（iOS 端 Node.js 集成的 platform channel）
    //
    // FlutterImplicitEngineBridge 协议不直接暴露 binaryMessenger 属性，
    // 但暴露 pluginRegistry；通过 registrar(forPlugin:).messenger() 可以拿到
    // FlutterBinaryMessenger，这是 Flutter 标准的插件注册方式。
    //
    // 参考：
    //   - D:\lj\11\tvbox_project\ios\Runner\AppDelegate.swift（旧的 FlutterViewController 模式）
    //   - Flutter 官方插件开发：registrar.messenger() 是 binaryMessenger 的标准来源
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NodeJSBridge") {
      self.nodeJSBridge = NodeJSBridge(messenger: registrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 NodeJSBridge 的 registrar")
    }

    // 注册 PipManager（iOS 系统画中画）
    // 与 NodeJSBridge 同一注册模式：registrar(forPlugin:).messenger() 拿
    // FlutterBinaryMessenger，PipManager 内部建 "pip_manager" MethodChannel。
    if let pipRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PipManager") {
      PipManager.shared.register(with: pipRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 PipManager 的 registrar")
    }

    // 注册全局唯一 AVPlayer（应用内画面 + PiP 共用）
    if let avRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "AvEngine") {
      AvEngine.shared.register(messenger: avRegistrar.messenger())
      avRegistrar.register(
        AvPlayerViewFactory(messenger: avRegistrar.messenger()),
        withId: "av_player_view"
      )
    } else {
      print("[AppDelegate] ❌ 无法获取 AvEngine 的 registrar")
    }

    // 注册 TTS（听书朗读）
    //
    // 用系统自带的 AVSpeechSynthesizer，**不引第三方插件**：
    // 新增 pub 依赖若没重新 pod install，插件原生库不会被链接，
    // Flutter 启动时找不到插件会直接崩（flutter_tts 就是这么导致闪退的）。
    if let ttsRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "TtsEngine") {
      TtsEngine.shared.register(messenger: ttsRegistrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 TtsEngine 的 registrar")
    }
  }
}
