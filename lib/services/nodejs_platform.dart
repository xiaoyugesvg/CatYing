// lib/services/nodejs_platform.dart
//
// Node.js 跨平台抽象层
// -----------------------------------------------------------------------------
// 目前只有 **iOS** 有实现（platform channel → Swift → NodeMobile.xcframework）。
// Windows / Android 的实现从未落地；原先为 Windows 预留的"运行时 zip 下载"
// 接口（`NodeDownloadConfig` / `isNodeRuntimeInstalled` /
// `downloadAndExtractNodeRuntime`）已于 2026-10-26 删除 —— 全仓无调用方，
// 留着只会让人误以为支持 Windows。
//
// 跨端统一接口在 [NodeJSPlatform] 抽象类里。
// NodeJSManager 用 `Platform.isXxx` 选具体实现。

import 'dart:async';

/// Node.js 平台抽象接口
///
/// **各端必须实现**的核心方法（启动/停止/加载源/路径）。
abstract class NodeJSPlatform {
  // ============================================================
  // 运行时状态
  // ============================================================
  bool get isRunning;
  bool get isNodeReady;
  int get nativeServerPort;
  int get managementPort;
  int get spiderPort;

  // ============================================================
  // 启动 / 停止 Node.js
  // ============================================================

  /// 启动 Node.js 进程
  ///
  /// - Windows: 调 `Process.start(node.exe, [main.js, --native-port ...])`
  /// - iOS:     调 platform channel → Swift → `node_start(argc, argv)`
  /// - Android: 调 platform channel → Kotlin → JNI 调 libnode
  ///
  /// 三端都需要：
  /// 1. 把 `main.js` 准备好（Windows: rootBundle→本地；iOS: bundle resource；Android: assets）
  /// 2. 起本地 HTTP server 收 Node.js 通知（用 dart:io，三端统一）
  /// 3. 通过 `--native-port` 把 HTTP server 端口传给 Node.js
  ///
  /// 返回 `isNodeReady`（Node.js 已发出 ready 消息）
  Future<bool> startNodeJS();

  void stopNodeJS();

  void forceResetRunningState();

  /// 等待 Node.js 发出 `ready` 消息
  Future<bool> waitForNodeReady();

  /// 等待 Spider HTTP server 端口打开
  Future<bool> waitForSpiderPort();

  // ============================================================
  // 源管理
  // ============================================================

  /// 从 URL 加载源（MD5 校验 + 下载 + 通过 management 端口通知 Node.js）
  ///
  /// 返回 `(success, message?)`
  Future<(bool success, String? message)> loadSource(String urlString);

  /// 删除已下载的源文件
  Future<bool> deleteSource();

  /// 文档目录下 nodejs source 目录的绝对路径
  /// - Windows / Android: `getApplicationDocumentsDirectory()/nodejs/source`
  /// - iOS:               `<Documents>/nodejs-project/src/source`
  Future<String> getDocumentsSourcePath();

  /// 最近一次实际载入的源缓存目录（按源 URL 分目录缓存）。
  /// 恢复流程（scene_recovery）要重新 `/source/loadPath` 时必须用这个，
  /// 不能再用根目录 —— 根目录下已没有 `index.js`。
  Future<String?> getLastSourceCachePath() async => null;

  // ============================================================
  // 端口注入
  // ============================================================

  /// 由 [NodeJSManager] 在启动 HTTP server 后注入端口
  /// Node.js 通过 `--native-port $port` 拿到这个端口，回调通知 Dart
  void setNativeServerPort(int port);

  // ============================================================
  // 小程序 Node 后端（manifest.json 的 `node` 字段）
  // ============================================================

  /// 启动某个小程序自带的 Node 服务，返回它的 base URL（`http://127.0.0.1:<port>`）。
  ///
  /// 默认实现返回 null（该平台不支持 / 还没有实现）。iOS 走 management 端口
  /// 的 `/miniapp/start`，让 Node 侧 require 小程序的 `server/index.js` 并 listen。
  Future<String?> startMiniAppService({
    required String appId,
    required String dir,
    String entry = 'server/index.js',
    String config = 'server/index.config.js',
  }) async =>
      null;

  /// 停止某个小程序的 Node 服务（不存在时静默返回）。
  Future<void> stopMiniAppService(String appId) async {}

  /// HTTP server 收到 `/onCatPawOpenPort?port=&type=` 时调用
  void onPortReceived(int port, String type);

  /// HTTP server 收到 `/onMessage` 时调用
  void onMessage(String message);
}
