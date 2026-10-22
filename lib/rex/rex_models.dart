/// REX / ForwardWidget 模块的数据模型。
///
/// 一个模块（module raw JS）导出的 `WidgetMetadata` 大致是：
/// ```js
/// WidgetMetadata = {
///   id, title, description, author, version, site,
///   modules: [
///     { title: '最新', functionName: 'loadList', params: [
///         { name: 'page', title: '页码', type: 'page', value: '1' } ] },
///     { title: '播放源', functionName: 'loadResource', type: 'stream' },
///   ],
/// }
/// ```
/// 列表/详情/播放的返回值是统一形状的 VideoItem，见 [RexItem]/[RexStream]。
library;

class RexParam {
  const RexParam({
    required this.name,
    this.title = '',
    this.type = '',
    this.value = '',
  });

  final String name;
  final String title;

  /// constant / page / input / bool / select …
  final String type;
  final String value;

  Map<String, dynamic> toJson() => {
        'name': name,
        'title': title,
        'type': type,
        'value': value,
      };

  factory RexParam.fromJson(Map<String, dynamic> j) => RexParam(
        name: '${j['name'] ?? ''}',
        title: '${j['title'] ?? ''}',
        type: '${j['type'] ?? ''}',
        value: '${j['value'] ?? ''}',
      );
}

class RexFunction {
  const RexFunction({
    this.id = '',
    required this.title,
    this.description = '',
    required this.functionName,
    this.type = '',
    this.params = const [],
  });

  final String id;
  final String title;
  final String description;
  final String functionName;
  final String type;
  final List<RexParam> params;

  bool get isStream => type == 'stream' || functionName == 'loadResource';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'functionName': functionName,
        'type': type,
        'params': params.map((e) => e.toJson()).toList(),
      };

  factory RexFunction.fromJson(Map<String, dynamic> j) => RexFunction(
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        description: '${j['description'] ?? ''}',
        functionName: '${j['functionName'] ?? ''}',
        type: '${j['type'] ?? ''}',
        params: [
          if (j['params'] is List)
            for (final e in j['params'] as List)
              if (e is Map) RexParam.fromJson(e.cast<String, dynamic>()),
        ],
      );
}

class RexModule {
  const RexModule({
    required this.url,
    required this.id,
    required this.title,
    this.description = '',
    this.author = '',
    this.version = '',
    this.site = '',
    this.functions = const [],
    this.functionNames = const [],
    this.enabled = true,
  });

  /// 模块 raw 地址（.js 内容）
  final String url;
  final String id;
  final String title;
  final String description;
  final String author;
  final String version;
  final String site;

  /// WidgetMetadata.modules（分类入口）
  final List<RexFunction> functions;

  /// 模块实际导出的可调用函数名
  final List<String> functionNames;

  /// 是否显示在「REX」首页（订阅管理里可开关）
  final bool enabled;

  RexModule copyWith({
    String? url,
    String? title,
    String? description,
    String? version,
    bool? enabled,
    List<RexFunction>? functions,
    List<String>? functionNames,
  }) =>
      RexModule(
        url: url ?? this.url,
        id: id,
        title: title ?? this.title,
        description: description ?? this.description,
        author: author,
        version: version ?? this.version,
        site: site,
        functions: functions ?? this.functions,
        functionNames: functionNames ?? this.functionNames,
        enabled: enabled ?? this.enabled,
      );

  List<RexFunction> get listFunctions =>
      functions.where((f) => !f.isStream && f.functionName.isNotEmpty).toList();

  bool get canSearch => functionNames.contains('search') ||
      functionNames.contains('searchByCode') ||
      functionNames.contains('loadSearch');

  bool get canPlay => functionNames.contains('loadResource');

  Map<String, dynamic> toJson() => {
        'url': url,
        'id': id,
        'title': title,
        'description': description,
        'author': author,
        'version': version,
        'site': site,
        'functions': functions.map((e) => e.toJson()).toList(),
        'functionNames': functionNames,
        'enabled': enabled,
      };

  factory RexModule.fromJson(Map<String, dynamic> j) => RexModule(
        url: '${j['url'] ?? ''}',
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? 'REX 模块'}',
        description: '${j['description'] ?? ''}',
        author: '${j['author'] ?? ''}',
        version: '${j['version'] ?? ''}',
        site: '${j['site'] ?? ''}',
        functions: [
          if (j['functions'] is List)
            for (final e in j['functions'] as List)
              if (e is Map) RexFunction.fromJson(e.cast<String, dynamic>()),
        ],
        functionNames: [
          if (j['functionNames'] is List)
            for (final e in j['functionNames'] as List) '$e',
        ],
        enabled: j['enabled'] != false,
      );
}

class RexItem {
  const RexItem({
    required this.id,
    required this.title,
    required this.link,
    this.cover = '',
    this.backdrop = '',
    this.description = '',
    this.mediaType = '',
    this.playerType = '',
  });

  final String id;
  final String title;

  /// 传给 loadDetail / loadResource 的句柄（模块自定义格式）
  final String link;
  final String cover;
  final String backdrop;
  final String description;
  final String mediaType;
  final String playerType;

  factory RexItem.fromJson(Map<String, dynamic> j) => RexItem(
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        link: '${j['link'] ?? j['id'] ?? ''}',
        cover: '${j['cover'] ?? ''}',
        backdrop: '${j['backdrop'] ?? ''}',
        description: '${j['description'] ?? ''}',
        mediaType: '${j['mediaType'] ?? ''}',
        playerType: '${j['playerType'] ?? ''}',
      );
}

class RexStream {
  const RexStream({
    required this.name,
    required this.url,
    this.description = '',
    this.headers = const {},
  });

  final String name;
  final String url;
  final String description;

  /// 播放必须带的请求头（防盗链 / 特定 UA）
  final Map<String, String> headers;

  factory RexStream.fromJson(Map<String, dynamic> j) {
    final raw = j['headers'];
    final headers = <String, String>{};
    if (raw is Map) raw.forEach((k, v) => headers['$k'] = '$v');
    return RexStream(
      name: '${j['name'] ?? '线路'}',
      url: '${j['url'] ?? ''}',
      description: '${j['description'] ?? ''}',
      headers: headers,
    );
  }
}

/// REX 相关异常（直接展示 message）
class RexException implements Exception {
  const RexException(this.message);
  final String message;
  @override
  String toString() => message;
}
