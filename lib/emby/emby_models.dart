import 'dart:math';

/// Emby 服务器配置（多服务器）。
class EmbyServer {
  EmbyServer({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.password,
    this.accessToken,
    this.userId,
    this.deviceId = '',
  });

  final String id;
  String name;

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
    this.year,
    this.indexNumber,
    this.parentIndexNumber,
    this.rating,
    this.runTimeTicks,
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
  final int? year;
  final int? indexNumber;
  final int? parentIndexNumber;
  final double? rating;
  final int? runTimeTicks;

  bool get isSeries => type == 'Series';
  bool get isEpisode => type == 'Episode';
  bool get isMovie => type == 'Movie';
  bool get isFolderish => type == 'Folder' || type == 'CollectionFolder';

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
    return EmbyItem(
      id: '${j['Id'] ?? ''}',
      name: '${j['Name'] ?? ''}',
      type: '${j['Type'] ?? ''}',
      overview: '${j['Overview'] ?? ''}',
      seriesId: j['SeriesId'] as String?,
      seriesName: j['SeriesName'] as String?,
      collectionType: j['CollectionType'] as String?,
      imageTag: tags is Map ? '${tags['Primary'] ?? ''}' : null,
      year: (j['ProductionYear'] as num?)?.toInt(),
      indexNumber: (j['IndexNumber'] as num?)?.toInt(),
      parentIndexNumber: (j['ParentIndexNumber'] as num?)?.toInt(),
      rating: (j['CommunityRating'] as num?)?.toDouble(),
      runTimeTicks: (j['RunTimeTicks'] as num?)?.toInt(),
    );
  }
}
