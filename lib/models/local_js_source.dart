import 'package:tvbox/models/source_bean.dart';

/// 用户「单独导入」的本地 JS 影视源（CatVod / drpy / TVBox type=3 脚本）。
///
/// 与本地 Python 源（[LocalPythonSource]）是同一套设计，只是引擎换成 Node：
///   · **不**写进订阅的 sites，也**不**混进 sourceBeanList；
///   · 单独落盘在 `<Documents>/local_js/`，单独成组，可逐条删除/改名；
///   · 切换订阅不会丢，重启后仍在。
///
/// 为什么 api 用「相对标识」而不是绝对路径：
///   iOS 沙盒的 Documents 绝对路径里带一段随机 UUID，重装/迁移后会变；
///   把绝对路径写进 prefs 会让主页源指向一个不存在的文件。
///   这里只存 `ljs_<hash>.js`，真实路径由 [LocalJsSources] 按当前 Documents 拼出来。
class LocalJsSource {
  /// 文件名（不含 .js），形如 `ljs_ab12cd34ef56`
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

  /// 传给 SpiderService 的 api：非 http 的 `.js` 会走 Node 引擎。
  String get api => '$key.js';

  /// 在 UI / prefs 里的唯一键（加前缀，避免和订阅线路 / 本地 py 撞 key）
  String get sourceKey => 'localjs_$key';

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
