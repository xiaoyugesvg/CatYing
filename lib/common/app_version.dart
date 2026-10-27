/// 应用版本号的**唯一 Dart 来源**。
///
/// 为什么单独一个文件：原来同一份版本号在三处硬编码
/// （`pubspec.yaml` 的 `version:`、`about_settings_page.dart` 的 `appVersion`、
/// `ant_bridge.dart` 的 `kAppVersion` / `kAppBuildNumber`）。改一处忘一处就会
/// 出现「设置里显示 2.0、小程序接口还报 1.0」这种自相矛盾。
///
/// ⚠️ `pubspec.yaml` 没法 import Dart，那份只能手改，改的时候必须和这里同步：
///
///     pubspec.yaml:  version: 2.0.0+2
///                              ^^^^^ ^
///                              │     └─ kAppBuildNumber
///                              └─────── kAppVersion
///
/// iOS 的 `Info.plist` 用的是 `$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`，
/// 由 pubspec 在构建时注入，不需要手改。
library;

/// 对用户展示的版本号（iOS `CFBundleShortVersionString`）。
const String kAppVersion = '2.0.0';

/// 构建号（iOS `CFBundleVersion`）。每次上架必须递增，与 [kAppVersion] 相互独立
/// —— 同一个 2.0.0 可以出多个构建号（修 bug 重打）。
const int kAppBuildNumber = 2;
