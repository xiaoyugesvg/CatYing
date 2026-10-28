/// 内置小程序注册表 —— 随 App 一起打包、首次启动自动装进「程序」列表。
///
/// 与「本地文件」安装走**完全同一套**流程（zip 解包到
/// `<Documents>/miniapps/<appId>/` → 写 `type=webapp` 记录），
/// 区别只是包体来自 `assets/miniapps/`，不需要用户自己找 zip。
///
/// 加一个新的内置小程序：
///   1. 把小程序包放到 `assets/miniapps/<名字>.zip`（结构与手动安装的一致）；
///   2. 在 pubspec.yaml 的 assets 里声明该 zip；
///   3. 在下面 [kBuiltinMiniApps] 里加一条，`version` 从 1 开始。
/// 以后改包体 → **version +1**，App 启动时会自动覆盖更新（数据文件见
/// `MiniAppService._builtinKeepFiles`，会被保留）。
class BuiltinMiniApp {
  const BuiltinMiniApp({
    required this.appId,
    required this.name,
    required this.assetZip,
    required this.version,
    this.group = '',
    this.description = '',
  });

  /// 必须与 zip 内 manifest.json 的 `appId` 一致（解包目录就用它命名）
  final String appId;

  /// 列表里显示的名字（zip 里有 manifest.name 时以 manifest 为准）
  final String name;

  /// pubspec 里声明的资源路径
  final String assetZip;

  /// 内置包版本：**改包必须 +1**，否则老用户不会被更新
  final int version;

  /// 首次安装时放进哪个分组（空 = 未分组）
  final String group;

  /// 「内置程序」弹层里的一句说明
  final String description;
}

/// 全部内置小程序（当前未内置任何小程序；保留注册表机制，后续要加内置程序
/// 时在此追加条目即可，见文件顶部说明）。
const List<BuiltinMiniApp> kBuiltinMiniApps = <BuiltinMiniApp>[];

/// 按 appId 找内置项（不是内置的返回 null）
BuiltinMiniApp? builtinById(String appId) {
  for (final b in kBuiltinMiniApps) {
    if (b.appId == appId) return b;
  }
  return null;
}

/// 这个 appId 是不是内置小程序
bool isBuiltinAppId(String appId) => builtinById(appId) != null;
