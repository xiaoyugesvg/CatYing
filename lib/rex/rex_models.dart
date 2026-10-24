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

  /// 能当「浏览源」用：有分类列表或能搜索。
  ///
  /// 有些模块只导出了 `loadResource`（纯播放源，挂在影视详情上用），
  /// 它们没有可浏览的内容 —— 首页的源 chips 不显示，订阅管理里保留。
  bool get browsable =>
      listFunctions.isNotEmpty || canSearch || functionNames.contains('loadHome');

  /// 纯播放源（只有取流能力，没有列表）
  bool get streamOnly => !browsable && canPlay;

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

/// 一个 `.rex` 集合（订阅）里的**候选模块**。
///
/// 只是从集合 JSON 里读出来的元信息，还没有真正加载过 JS ——
/// 「市场」页先展示这份清单让用户勾选，勾完再逐个加载。
class RexCollectionItem {
  const RexCollectionItem({
    required this.url,
    required this.title,
    this.id = '',
    this.author = '',
    this.version = '',
    this.description = '',
  });

  final String url;
  final String title;
  final String id;
  final String author;
  final String version;
  final String description;

  factory RexCollectionItem.fromJson(Map<String, dynamic> j) => RexCollectionItem(
        url: '${j['url'] ?? ''}',
        title: '${j['title'] ?? ''}'.trim(),
        id: '${j['id'] ?? ''}',
        author: '${j['author'] ?? ''}',
        version: '${j['version'] ?? ''}',
        description: '${j['description'] ?? ''}',
      );

  /// 落盘用（市场把集合当订阅缓存下来，下次进来不用联网就能显示清单）
  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'id': id,
        'author': author,
        'version': version,
        'description': description,
      };
}

/// `.rex` 集合：`{ title, description, icon, widgets: [...] }`
class RexCollection {
  const RexCollection({
    required this.url,
    required this.title,
    this.description = '',
    this.icon = '',
    this.items = const [],
  });

  /// 集合自身的地址（用于去重 / 展示来源）
  final String url;
  final String title;
  final String description;
  final String icon;
  final List<RexCollectionItem> items;

  bool get isEmpty => items.isEmpty;

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'description': description,
        'icon': icon,
        'items': items.map((e) => e.toJson()).toList(),
      };

  factory RexCollection.fromJson(Map<String, dynamic> j) => RexCollection(
        url: '${j['url'] ?? ''}',
        title: '${j['title'] ?? ''}',
        description: '${j['description'] ?? ''}',
        icon: '${j['icon'] ?? ''}',
        items: [
          if (j['items'] is List)
            for (final e in j['items'] as List)
              if (e is Map)
                RexCollectionItem.fromJson(e.cast<String, dynamic>()),
        ],
      );
}

/// 批量导入结果
class RexImportResult {
  const RexImportResult({this.imported = const [], this.errors = const []});

  final List<RexModule> imported;

  /// 每个失败项一行：「模块名：原因」
  final List<String> errors;
}
