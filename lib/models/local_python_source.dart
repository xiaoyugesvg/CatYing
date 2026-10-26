import 'package:tvbox/models/source_bean.dart';

/// 用户「单独导入」的本地 Python 影视源。
///
/// 与订阅线路的关系（用户 2026-10-17）：
///   · **不**写进订阅的 sites，也**不**混进 sourceBeanList；
///   · 它们单独落盘、单独成组（源面板顶部的「本地 Python」），可逐条删除/改名；
///   · 切换订阅不会丢，重启后仍在。
///
/// 文件仍放在 <Documents>/python-project/src/spider/video/<key>.py，
/// 由 CPython 引擎按模块名加载（key 只用 [A-Za-z0-9_-]）。
class LocalPythonSource {
  /// 引擎文件名（不含 .py），形如 `lp_ab12cd34ef56`
  final String key;

  /// 显示名（可改）
  final String name;

  /// 导入时间（毫秒）
  final int addedAt;

  /// 使用次数（「频率」排序用）
  final int usage;

  const LocalPythonSource({
    required this.key,
    required this.name,
    this.addedAt = 0,
    this.usage = 0,
  });

  /// 传给 SpiderService 的 api：非 http 的 .py 会走 CPython 引擎
  String get api => '$key.py';

  /// 在 UI / prefs 里的唯一键（加前缀，避免和订阅线路撞 key）
  String get sourceKey => 'localpy_$key';

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

  factory LocalPythonSource.fromJson(Map<String, dynamic> json) {
    return LocalPythonSource(
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
