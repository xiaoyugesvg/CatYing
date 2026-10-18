/// 阅读模块的**源订阅**记录（小说 / 漫画）。
///
/// 用户 2026-10-17：把订阅链接记下来，和本地已导入的源一起管理，
/// 随时更新 / 增删 / 分类。这里只存"链接记录"，源本体仍进 `BookSourceStore`。
enum SourceSubscriptionKind {
  novel('小说书源'),
  comic('漫画书源'),
  legado('Legado 综合源'),
  venera('Venera 漫画源');

  const SourceSubscriptionKind(this.label);
  final String label;

  /// Venera 的 ComicSource JS 运行时应由 `venera/` 适配层处理
  /// （直接跑源脚本，不转成 Legado 规则）。
  bool get supported => true;

  /// 这条订阅会喂给哪个"仓"：**一条订阅只属于一个仓**。
  ///
  /// 用户 2026-10-18：「我从哪个仓订阅就用哪个，书源仓库和漫源仓库的订阅
  /// 也不通用」—— 旧的 `legado` 综合源也归书源仓（书源仓本身也能收漫画源），
  /// 不再同时出现在两个仓。
  bool get feedsNovel =>
      this == SourceSubscriptionKind.novel ||
      this == SourceSubscriptionKind.legado;

  bool get feedsComic =>
      this == SourceSubscriptionKind.comic ||
      this == SourceSubscriptionKind.venera;
}

class SourceSubscription {
  const SourceSubscription({
    required this.id,
    required this.name,
    required this.url,
    required this.kind,
    this.enabled = true,
    this.builtin = false,
    this.lastUpdated = 0,
    this.count = 0,
    this.lastError = '',
    this.updateHours = 24,
    this.sourceIds = const [],
  });

  final String id;
  final String name;
  final String url;
  final SourceSubscriptionKind kind;
  final bool enabled;

  /// 随包预置的链接（可删；删了不会自动复活）
  final bool builtin;

  /// 最近一次成功更新的时间（毫秒，0 = 从未更新）
  final int lastUpdated;

  /// 最近一次成功导入的源数量
  final int count;

  /// 最近一次失败原因（空 = 正常）
  final String lastError;

  /// 自动更新间隔（小时）。0 = 只手动更新。
  final int updateHours;

  /// 这条订阅导入的源 id（书源 id / `venera:xxx`）。
  /// 用于「订阅 tab → 只显示这个订阅带来的源」，更新后覆盖写入。
  final List<String> sourceIds;

  SourceSubscription copyWith({
    String? name,
    String? url,
    SourceSubscriptionKind? kind,
    bool? enabled,
    int? lastUpdated,
    int? count,
    String? lastError,
    int? updateHours,
    List<String>? sourceIds,
  }) => SourceSubscription(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    kind: kind ?? this.kind,
    enabled: enabled ?? this.enabled,
    builtin: builtin,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    count: count ?? this.count,
    lastError: lastError ?? this.lastError,
    updateHours: updateHours ?? this.updateHours,
    sourceIds: sourceIds ?? this.sourceIds,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'kind': kind.name,
    'enabled': enabled,
    'builtin': builtin,
    'lastUpdated': lastUpdated,
    'count': count,
    'lastError': lastError,
    'updateHours': updateHours,
    'sourceIds': sourceIds,
  };

  static SourceSubscription? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString();
    final url = (raw['url'] ?? '').toString();
    if (id.isEmpty || url.isEmpty) return null;
    final kindName = (raw['kind'] ?? '').toString();
    final kind = SourceSubscriptionKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => SourceSubscriptionKind.novel,
    );
    int n(Object? v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
    final ids = raw['sourceIds'];
    return SourceSubscription(
      id: id,
      name: (raw['name'] ?? '').toString(),
      url: url,
      kind: kind,
      enabled: raw['enabled'] != false,
      builtin: raw['builtin'] == true,
      lastUpdated: n(raw['lastUpdated']),
      count: n(raw['count']),
      lastError: (raw['lastError'] ?? '').toString(),
      updateHours: raw.containsKey('updateHours') ? n(raw['updateHours']) : 24,
      sourceIds: ids is List
          ? ids.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
          : const [],
    );
  }
}
