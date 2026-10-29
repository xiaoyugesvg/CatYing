import 'package:tvbox/models/source_bean.dart';

/// 用户「单独导入」的本地 **JS** 影视源。
///
/// 与 [LocalPythonSource] 完全同构，区别只在引擎：
///   · PY 源交给 CPython（`PythonSourcesService.registerSource`）；
///   · JS 源交给内置 Node（`NodeJSManager.loadSource` 按**相对标识**
///     `ljs_xxx.js` 解析成 `<Documents>/local_js/ljs_xxx.js` 再载入）。
///
/// 为什么 api 存**相对文件名**而不是绝对路径：
///   iOS 沙盒目录名里带 UUID，重装 / 换机后绝对路径全变；
///   相对标识由 `NodeJSPlatformIos._resolveLocalJsPath` 在运行时拼成真实路径。
///
/// 支持的脚本形态（与 SpiderService 的 JS 分支一致）：
///   · TVBox / 猫源 drpy2：`var rule = {...}` + `export`/`module.exports`
///   · drpy 单文件：`var spider = {...}` 或 `class Spider`
///   · 订阅 JS：`var rule = { home: async function(){...} }`
class LocalJsSource {
  /// 引擎文件名（不含 .js），形如 `ljs_ab12cd34ef56`
  final String key;

  /// 显示名（可改）
  final String name;

  /// 导入时间（毫秒）
  final int addedAt;

  /// 使用次数（「频率」排序用）
  final int usage;

  const LocalJsSource({
    required this.key,
    required this.name,
    this.addedAt = 0,
    this.usage = 0,
  });

  /// 传给 SpiderService 的 api：非 http 的 .js 会走 Node 本地载入
  String get api => '$key.js';

  /// 在 UI / prefs 里的唯一键（加前缀，避免和订阅线路 / PY / XBPQ 撞 key）
  String get sourceKey => '${SourceBean.localJsKeyPrefix}$key';

  /// 转成 App 内部的 SourceBean（type=3 Spider）
  SourceBean toSourceBean() => SourceBean(
    key: sourceKey,
    name: name.isEmpty ? key : name,
    api: api,
    type: 3,
    searchable: 1,
    filterable: 1,
    quickSearch: 0,
  );

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'addedAt': addedAt,
    'usage': usage,
  };

  factory LocalJsSource.fromJson(Map<String, dynamic> json) {
    return LocalJsSource(
      key: (json['key'] ?? '').toString().trim(),
      name: (json['name'] ?? '').toString(),
      addedAt: (json['addedAt'] is num)
          ? (json['addedAt'] as num).toInt()
          : int.tryParse('${json['addedAt'] ?? 0}') ?? 0,
      usage: (json['usage'] is num)
          ? (json['usage'] as num).toInt()
          : int.tryParse('${json['usage'] ?? 0}') ?? 0,
    );
  }
}
