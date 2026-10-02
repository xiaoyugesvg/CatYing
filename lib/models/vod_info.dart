import 'movie.dart';

/// TMDB 演职人员条目（刮削增强：带头像与角色名）
class VodCastMember {
  /// 演员名
  final String name;
  /// 饰演角色（可为空）
  final String character;
  /// TMDB profile_path（不含域名，可为空）
  final String profilePath;
  /// TMDB 排序权重，越小越靠前
  final int order;

  const VodCastMember({
    required this.name,
    this.character = '',
    this.profilePath = '',
    this.order = 0,
  });

  bool get hasPhoto => profilePath.isNotEmpty;

  /// 拼成完整头像 URL；无头像返回空串（UI 侧用首字母占位）
  String get avatarUrl {
    if (profilePath.isEmpty) return '';
    if (profilePath.startsWith('http')) return profilePath;
    return 'https://image.tmdb.org/t/p/w185$profilePath';
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'character': character,
        'profilePath': profilePath,
        'order': order,
      };

  factory VodCastMember.fromJson(Map<String, dynamic> json) => VodCastMember(
        name: (json['name'] ?? '').toString(),
        character: (json['character'] ?? '').toString(),
        profilePath: (json['profilePath'] ?? '').toString(),
        order: (json['order'] as num?)?.toInt() ?? 0,
      );
}

/// TMDB 类似作品条目
class VodSimilarItem {
  final String id;
  /// 'movie' | 'tv'
  final String mediaType;
  final String title;
  final double voteAverage;
  final String year;
  /// TMDB poster_path（不含域名）
  final String posterPath;

  const VodSimilarItem({
    required this.id,
    this.mediaType = 'movie',
    this.title = '',
    this.voteAverage = 0,
    this.year = '',
    this.posterPath = '',
  });

  bool get hasRating => voteAverage > 0;

  String get posterUrl {
    if (posterPath.isEmpty) return '';
    if (posterPath.startsWith('http')) return posterPath;
    return 'https://image.tmdb.org/t/p/w342$posterPath';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'mediaType': mediaType,
        'title': title,
        'voteAverage': voteAverage,
        'year': year,
        'posterPath': posterPath,
      };

  factory VodSimilarItem.fromJson(Map<String, dynamic> json) => VodSimilarItem(
        id: (json['id'] ?? '').toString(),
        mediaType: (json['mediaType'] ?? 'movie').toString(),
        title: (json['title'] ?? '').toString(),
        voteAverage: (json['voteAverage'] as num?)?.toDouble() ?? 0,
        year: (json['year'] ?? '').toString(),
        posterPath: (json['posterPath'] ?? '').toString(),
      );
}

/// 视频详情模型 - 对应 Swift VodInfo
class VodInfo {
  /// 视频唯一 ID
  String id;
  /// 标题
  String name;
  /// 海报地址
  String pic;

  /// TMDB 背景大图（backdrop，横版头图用；未刮削为空）
  String backdrop;
  /// 备注（更新状态等）
  String note;
  /// 年份
  String year;
  /// 地区
  String area;
  /// 类型名
  String typeName;
  /// 导演
  String director;
  /// 演员
  String actor;
  /// 简介
  String des;
  /// 来源站点 key
  String sourceKey;

  /// 播放来源（线路）列表
  List<String> playFlags;

  /// key: flag名称, value: 剧集列表
  Map<String, List<Episode>> playUrlMap;

  /// 当前选中线路
  String playFlag;

  /// 当前播放剧集索引
  int playIndex;

  // ============================================================
  // TMDB 刮削增强字段（未刮削时保持默认值，UI 侧按空判断隐藏）
  // ============================================================

  /// TMDB 评分（0 表示无）
  double rating;

  /// 片长（分钟，0 表示未知；剧集通常为单集时长或 0）
  int runtime;

  /// 演职人员（带头像与角色名），最多 20 条
  List<VodCastMember> castList;

  /// 类似作品（similar + recommendations 合并去重），最多 12 条
  List<VodSimilarItem> similarList;

  /// 剧集缩略图（键 = 集号 1 起，值 = TMDB still 图 URL）。
  /// 媒体库刮削视图「选集缩略图条」用真实剧照，未刮削到则回退海报底。
  Map<int, String> episodeStills;

  /// TMDB 官方标题（媒体库刮削视图优先显示；不覆盖 info.name，
  /// 换源/收藏/历史仍用 Spider 源原名）
  String tmdbName;

  /// TMDB 播出日期（release_date / first_air_date，完整日期如 2026-09-15）
  String releaseDate;

  /// TMDB 剧集状态（Returning Series / Ended / …，参考图元数据行）
  String tmdbStatus;

  /// TMDB 总集数（number_of_episodes；参考图 "47 ep"）
  int episodeCount;

  /// 剧集标题（键 = 集号 1 起，值 = TMDB 每集标题，如「沈家灭门，嘉兰入林府」）
  Map<int, String> episodeTitles;

  VodInfo({
    required this.id,
    this.name = '',
    this.pic = '',
    this.backdrop = '',
    this.note = '',
    this.year = '',
    this.area = '',
    this.typeName = '',
    this.director = '',
    this.actor = '',
    this.des = '',
    this.sourceKey = '',
    this.playFlags = const [],
    this.playUrlMap = const {},
    this.playFlag = '',
    this.playIndex = 0,
    this.rating = 0,
    this.runtime = 0,
    this.castList = const [],
    this.similarList = const [],
    this.episodeStills = const {},
    this.tmdbName = '',
    this.releaseDate = '',
    this.tmdbStatus = '',
    this.episodeCount = 0,
    this.episodeTitles = const {},
  });

  /// 当前线路下的剧集
  List<Episode> get currentEpisodes => playUrlMap[playFlag] ?? [];

  /// 当前线路 + 当前索引对应的剧集对象
  Episode? get currentEpisode {
    final eps = currentEpisodes;
    if (playIndex < 0 || playIndex >= eps.length) return null;
    return eps[playIndex];
  }

  /// 从 Movie.Video 和详情数据构建
  static VodInfo fromVideo({
    required Video video,
    required String playFrom,
    required String playUrl,
  }) {
    final info = VodInfo(
      id: video.id,
      name: video.name,
      pic: video.pic,
      note: video.note,
      year: video.year,
      area: video.area,
      typeName: video.type,
      director: video.director,
      actor: video.actor,
      des: _stripHtml(video.des),
      sourceKey: video.sourceKey,
    );

    // 解析播放列表：
    // playFrom 格式: "线路1$$$线路2$$$线路3"
    // playUrl  格式: "第1集$url1#第2集$url2$$$第1集$url3#第2集$url4"
    final flags = playFrom.split('\$\$\$').where((s) => s.isNotEmpty).toList();
    final urls = playUrl.split('\$\$\$');

    info.playFlags = flags;
    info.playUrlMap = {};
    for (int i = 0; i < flags.length; i++) {
      if (i < urls.length) {
        final episodes = urls[i]
            .split('#')
            .map((item) {
              final parts = item.split('\$');
              if (parts.length >= 2) {
                return Episode(name: parts[0], url: parts[1]);
              }
              return null;
            })
            .whereType<Episode>()
            .toList();
        info.playUrlMap[flags[i]] = episodes;
      }
    }

    if (flags.isNotEmpty) {
      info.playFlag = flags.first;
    }

    return info;
  }

  static String _stripHtml(String text) {
    return text.replaceAll(RegExp(r'<[^>]+>'), '');
  }
}

/// 单集信息
class Episode {
  /// 集标题
  final String name;
  /// 集播放地址
  final String url;

  const Episode({required this.name, required this.url});
}
