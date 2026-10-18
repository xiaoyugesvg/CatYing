import 'dart:math';

/// Emby 服务器配置（多服务器）。
class EmbyServer {
  EmbyServer({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.password,
    this.type = 'emby',
    this.accessToken,
    this.userId,
    this.deviceId = '',
  });

  final String id;
  String name;

  /// 服务器类型：autoDetect / emby / jellyfin / plex
  String type;

  /// 用户填的地址（保存原样，读取时用 [normalizedUrl]）
  String baseUrl;
  String username;
  String password;

  /// 登录后由 `/Users/AuthenticateByName` 返回
  String? accessToken;
  String? userId;

  /// Emby 用来区分设备的稳定 id（登录时带上，避免每次新设备）
  String deviceId;

  bool get isConfigured =>
      normalizedUrl.isNotEmpty &&
      (accessToken?.isNotEmpty ?? false) &&
      (userId?.isNotEmpty ?? false);

  /// 规范化地址：补 `http://`、去掉尾部 `/`
  String get normalizedUrl {
    var u = baseUrl.trim();
    if (u.isEmpty) return '';
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
    'accessToken': accessToken,
    'userId': userId,
    'deviceId': deviceId,
  };

  factory EmbyServer.fromJson(Map<String, dynamic> j) => EmbyServer(
    id: '${j['id'] ?? ''}',
    name: '${j['name'] ?? 'Emby'}',
    type: '${j['type'] ?? 'emby'}',
    baseUrl: '${j['baseUrl'] ?? ''}',
    username: '${j['username'] ?? ''}',
    password: '${j['password'] ?? ''}',
    accessToken: j['accessToken'] as String?,
    userId: j['userId'] as String?,
    deviceId: '${j['deviceId'] ?? ''}',
  );

  static String newId() {
    final r = Random();
    return 'emby_${DateTime.now().millisecondsSinceEpoch}_${r.nextInt(9999)}';
  }

  static String newDeviceId() {
    const chars = 'abcdef0123456789';
    final r = Random();
    return List.generate(32, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

/// Emby 条目里的一位演职人员（来自服务端自动刮削的 `People` 字段）。
///
/// `type`：Actor / GuestStar / Director / Writer / Producer …
/// `role`：饰演的角色名（导演/编剧通常为空）
class EmbyPerson {
  const EmbyPerson({
    required this.id,
    required this.name,
    this.role = '',
    this.type = '',
    this.imageTag,
  });

  final String id;
  final String name;
  final String role;
  final String type;
  final String? imageTag;

  bool get hasPhoto => id.isNotEmpty && (imageTag ?? '').isNotEmpty;

  bool get isDirector => type == 'Director';
  bool get isWriter => type == 'Writer';
  bool get isActor => type == 'Actor' || type == 'GuestStar';

  factory EmbyPerson.fromJson(Map<String, dynamic> j) => EmbyPerson(
    id: '${j['Id'] ?? ''}',
    name: '${j['Name'] ?? ''}',
    role: '${j['Role'] ?? ''}',
    type: '${j['Type'] ?? ''}',
    imageTag: j['PrimaryImageTag']?.toString(),
  );
}

/// Emby 媒体条目（电影 / 剧集 / 单集 / 媒体库视图）。
class EmbyItem {
  const EmbyItem({
    required this.id,
    required this.name,
    required this.type,
    this.overview = '',
    this.seriesId,
    this.seriesName,
    this.collectionType,
    this.imageTag,
    this.backdropTag,
    this.backdropItemId,
    this.playedPercentage,
    this.year,
    this.indexNumber,
    this.parentIndexNumber,
    this.rating,
    this.criticRating,
    this.runTimeTicks,
    this.genres = const [],
    this.people = const [],
    this.studios = const [],
    this.taglines = const [],
    this.officialRating = '',
    this.premiereDate = '',
    this.originalTitle = '',
  });

  final String id;
  final String name;
  final String type;
  final String overview;
  final String? seriesId;
  final String? seriesName;

  /// 仅媒体库视图有：`movies` / `tvshows` / `music` …
  final String? collectionType;
  final String? imageTag;

  /// 横版背景图（Emby Backdrop）。列表页幻灯片 / 详情页头图用。
  ///
  /// 分集的 backdrop 通常挂在父剧集上（`ParentBackdropItemId` +
  /// `ParentBackdropImageTags`），这里一并兼容。
  final String? backdropTag;
  final String? backdropItemId;

  /// 继续观看进度（0~100，来自 `UserData.PlayedPercentage`）。
  final double? playedPercentage;

  final int? year;
  final int? indexNumber;
  final int? parentIndexNumber;
  final double? rating;
  final double? criticRating;
  final int? runTimeTicks;

  /// ── 服务端自动刮削的元数据（TMDB / TVDB 抓回来的那套）─────────────
  /// 简介、海报之外的「详情页内容」都在这里；列表接口不请求时保持为空。
  final List<String> genres;
  final List<EmbyPerson> people;
  final List<String> studios;
  final List<String> taglines;
  final String officialRating;
  final String premiereDate;
  final String originalTitle;

  bool get isSeries => type == 'Series';
  bool get isEpisode => type == 'Episode';
  bool get isMovie => type == 'Movie';
  bool get isFolderish => type == 'Folder' || type == 'CollectionFolder';

  /// 宣传语（刮削到的 Tagline）
  String get tagline => taglines.isEmpty ? '' : taglines.first.trim();

  /// 导演（多人用「 / 」连接）
  String get directors => people
      .where((p) => p.isDirector)
      .map((p) => p.name)
      .where((n) => n.isNotEmpty)
      .join(' / ');

  /// 编剧（多人用「 / 」连接）
  String get writers => people
      .where((p) => p.isWriter)
      .map((p) => p.name)
      .where((n) => n.isNotEmpty)
      .join(' / ');

  /// 演员（刮削时按服务端给出的顺序，主角在前）
  List<EmbyPerson> get actors => people.where((p) => p.isActor).toList();

  /// 首播日期：`2026-01-01T00:00:00…` → `2026-01-01`
  String get premiereDateText {
    final s = premiereDate.trim();
    if (s.length >= 10) return s.substring(0, 10);
    return s;
  }

  /// 剧集显示 `S01E03`，电影为空
  String get episodeLabel {
    if (!isEpisode) return '';
    final s = parentIndexNumber;
    final e = indexNumber;
    final sTxt = s == null ? 'S' : 'S${s.toString().padLeft(2, '0')}';
    final eTxt = e == null ? 'E' : 'E${e.toString().padLeft(2, '0')}';
    return '$sTxt$eTxt';
  }

  String get durationText {
    final t = runTimeTicks;
    if (t == null || t <= 0) return '';
    final mins = (t / 10000000 / 60).round();
    if (mins < 60) return '$mins 分钟';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? '$h 小时' : '$h 小时 $m 分';
  }

  factory EmbyItem.fromJson(Map<String, dynamic> j) {
    final tags = j['ImageTags'];
    final backdrops = j['BackdropImageTags'];
    final parentBackdrops = j['ParentBackdropImageTags'];
    String? backdropTag;
    String? backdropItemId;
    if (backdrops is List && backdrops.isNotEmpty) {
      backdropTag = '${backdrops.first}';
    } else if (parentBackdrops is List && parentBackdrops.isNotEmpty) {
      backdropTag = '${parentBackdrops.first}';
      backdropItemId = j['ParentBackdropItemId']?.toString();
    }
    final userData = j['UserData'];
    final played = userData is Map ? userData['PlayedPercentage'] : null;
    return EmbyItem(
      id: '${j['Id'] ?? ''}',
      name: '${j['Name'] ?? ''}',
      type: '${j['Type'] ?? ''}',
      overview: '${j['Overview'] ?? ''}',
      seriesId: j['SeriesId'] as String?,
      seriesName: j['SeriesName'] as String?,
      collectionType: j['CollectionType'] as String?,
      imageTag: tags is Map ? '${tags['Primary'] ?? ''}' : null,
      backdropTag: backdropTag,
      backdropItemId: backdropItemId,
      playedPercentage: played is num ? played.toDouble() : null,
      year: (j['ProductionYear'] as num?)?.toInt(),
      indexNumber: (j['IndexNumber'] as num?)?.toInt(),
      parentIndexNumber: (j['ParentIndexNumber'] as num?)?.toInt(),
      rating: (j['CommunityRating'] as num?)?.toDouble(),
      criticRating: (j['CriticRating'] as num?)?.toDouble(),
      runTimeTicks: (j['RunTimeTicks'] as num?)?.toInt(),
      genres: _strings(j['Genres']),
      people: _people(j['People']),
      studios: _studios(j['Studios']),
      taglines: _strings(j['Taglines']),
      officialRating: '${j['OfficialRating'] ?? ''}',
      premiereDate: '${j['PremiereDate'] ?? ''}',
      originalTitle: '${j['OriginalTitle'] ?? ''}',
    );
  }

  static List<String> _strings(dynamic v) {
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e != null && e.toString().trim().isNotEmpty) e.toString().trim(),
    ];
  }

  static List<EmbyPerson> _people(dynamic v) {
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is Map) EmbyPerson.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// Emby 的 Studios 是对象数组（`{Name, Id}`），也兼容纯字符串
  static List<String> _studios(dynamic v) {
    if (v is! List) return const [];
    final out = <String>[];
    for (final e in v) {
      final name = e is Map ? '${e['Name'] ?? ''}' : '${e ?? ''}';
      final t = name.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  /// backdrop 属于哪个条目（分集时是父剧集）。
  String get backdropImageId =>
      (backdropItemId != null && backdropItemId!.isNotEmpty)
      ? backdropItemId!
      : id;

  /// 继续观看进度（0~1，无数据返回 null）。
  double? get progress {
    final p = playedPercentage;
    if (p == null || p <= 0) return null;
    return (p / 100).clamp(0.0, 1.0);
  }
}
