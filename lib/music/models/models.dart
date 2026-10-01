import 'dart:convert';

// ============================================================
// 宽容的数值转换
// ============================================================
//
// ── 为什么需要这个（踩过的坑）─────────────────────────────────
// Node 侧的引擎**有时把数字转成字符串**再返回（例如 mapTrack 里
// `id: String(id)`），而 Dart 写 `j['id'] as num?` 在运行时遇到 String
// 会**直接抛异常**：
//     type 'String' is not a subtype of type 'num?' in type cast
// 症状极难定位 —— 整个页面只显示这一行英文报错，看不出是哪个字段。
//
// `as num?` 还漏了一种情况：JSON 里同一字段可能是 int 也可能是 double
// （比如 0 和 0.0），强转本身没问题，但一旦是 String 就崩。
//
// 所以统一用这两个函数：**能转就转，转不了给默认值**，
// 让"某个字段类型不对"退化成"这个字段显示 0"，而不是整页崩掉。

/// 任意值 → int（字符串数字也能转，失败返回 0）
int asInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is num) return v.toInt();
  if (v is bool) return v ? 1 : 0;
  return int.tryParse(v.toString().trim()) ?? 0;
}

/// 任意值 → double（字符串数字也能转，失败返回 0）
double asDouble(dynamic v) {
  if (v == null) return 0;
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().trim()) ?? 0;
}

/// 可空的 int（区分"没有"和"是 0"）
int? asIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return int.tryParse(s);
}

/// 音乐模块数据模型。
///
/// 移植自 Beans-Music 的 `Models.swift`（Swift）。
/// 去掉了原版的多平台字段（qqMid / kugouHash 等）—— 本项目只用网易云
/// 公开接口、不做账号，那些字段没有数据来源。
///
/// 保留原版的：
///   · `identityKey`  跨平台唯一标识
///   · `isVIP`        VIP/付费标记（列表与播放器角标）
///   · `formattedDuration`
///   · 完整的 LRC 解析（多时间标签 / 翻译对齐 / 纯文本兜底）

/// 音质档位（对应 Beans 的 BeansAudioQuality）
enum AudioQuality {
  standard('standard', '标准'),
  higher('higher', '较高'),
  exhigh('exhigh', '极高'),
  lossless('lossless', '无损'),
  hires('hires', 'Hi-Res');

  const AudioQuality(this.level, this.displayName);

  /// 网易云 songURL 的 level 参数
  final String level;
  final String displayName;

  /// 各档位对应的码率（拿不到 level 参数的老接口时用）
  int get bitrate => switch (this) {
        AudioQuality.standard => 128000,
        AudioQuality.higher => 192000,
        AudioQuality.exhigh => 320000,
        AudioQuality.lossless => 999000,
        AudioQuality.hires => 1900000,
      };

  static const storageKey = 'music.audioQuality';

  static AudioQuality fromName(String? name) =>
      AudioQuality.values.firstWhere(
        (q) => q.name == name,
        orElse: () => AudioQuality.hires,
      );
}

/// 歌曲来源。本项目只用网易云，保留枚举是为将来扩展。
enum SongSource {
  netease('netease', '网易云'),
  qq('qq', 'QQ音乐'),
  kugou('kugou', '酷狗');

  const SongSource(this.key, this.displayName);
  final String key;
  final String displayName;

  static SongSource fromKey(String? k) => SongSource.values.firstWhere(
        (s) => s.key == k,
        orElse: () => SongSource.netease,
      );
}

/// 歌曲。字段对齐 Beans 的 `Song`。
class Song {
  final int id;
  final String name;
  final String artists;
  final String album;
  final String? coverUrl;

  /// 时长（秒）
  final double duration;
  final SongSource source;

  /// 付费标记：网易云 0 免费 / 1 VIP / 4 付费单曲 / 8 免费资源（翻唱）
  final int fee;

  const Song({
    required this.id,
    required this.name,
    required this.artists,
    this.album = '',
    this.coverUrl,
    this.duration = 0,
    this.source = SongSource.netease,
    this.fee = 0,
  });

  String get formattedDuration {
    final t = duration < 0 ? 0 : duration.toInt();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  /// 跨平台唯一标识（避免不同平台 id 撞车）
  String get identityKey => '${source.key}-$id';

  /// 是否 VIP / 付费单曲（列表与播放器角标用）
  ///
  /// 网易云：fee==1 或 4 需要会员；8 表示"免费资源"（如翻唱），不算 VIP；
  /// 0 免费。注意 fee==8 在有些歌上代表"免费但需登录"，这里按免费处理，
  /// 真拿不到地址时由播放器给出「无免费音源」提示。
  bool get isVIP => fee == 1 || fee == 4 || fee == 16 || fee == 64;

  /// 免费可播（用于列表上是否显示"会员"角标）
  bool get likelyFree => fee == 0 || fee == 8;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'artists': artists,
        'album': album,
        'coverUrl': coverUrl,
        'duration': duration,
        'source': source.key,
        'fee': fee,
      };

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        // ⚠️ 绝不能用 `(j['id'] as num?)`！
        // Node 侧 mapTrack 输出的是 `id: String(id)`（字符串），
        // 而 Dart 的 `as num?` 在运行时遇到 String 会**直接抛**
        //   type 'String' is not a subtype of type 'num?' in type cast
        // 表现就是"整个搜索页只显示这行报错"。用 asInt 宽容转换。
        id: asInt(j['id']),
        name: (j['name'] ?? '').toString(),
        artists: (j['artists'] ?? '').toString(),
        album: (j['album'] ?? '').toString(),
        coverUrl: j['coverUrl']?.toString(),
        duration: asDouble(j['duration']),
        source: SongSource.fromKey(j['source']?.toString()),
        fee: asInt(j['fee']),
      );

  static String listToJson(List<Song> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<Song> listFromJson(String raw) {
    try {
      final d = jsonDecode(raw);
      if (d is! List) return const [];
      return d
          .whereType<Map>()
          .map((e) => Song.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Song && other.identityKey == identityKey;

  @override
  int get hashCode => identityKey.hashCode;

  @override
  String toString() => 'Song($name - $artists)';
}

/// 歌单（对齐 Beans 的 `Playlist`）
class Playlist {
  final int id;
  final String name;
  final String? coverUrl;
  final int trackCount;
  final String? description;
  final String? creator;

  const Playlist({
    required this.id,
    required this.name,
    this.coverUrl,
    this.trackCount = 0,
    this.description,
    this.creator,
  });

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: asInt(j['id']),
        name: (j['name'] ?? '').toString(),
        coverUrl: j['coverUrl']?.toString(),
        trackCount: asInt(j['trackCount']),
        description: j['description']?.toString(),
        creator: j['creator']?.toString(),
      );
}

/// 排行榜条目（对齐 Beans 的 `TopList`）
class TopList {
  final int id;
  final String name;
  final String? coverUrl;
  final String? updateFrequency;

  const TopList({
    required this.id,
    required this.name,
    this.coverUrl,
    this.updateFrequency,
  });
}

/// 歌手（对齐 Beans 的 `Artist`）
class Artist {
  final int id;
  final String name;
  final String? avatarUrl;

  const Artist({required this.id, required this.name, this.avatarUrl});
}

/// 专辑（对齐 Beans 的 `Album`）
class Album {
  final int id;
  final String name;
  final String? coverUrl;
  final String? artist;

  const Album({required this.id, required this.name, this.coverUrl, this.artist});
}

/// 一行歌词
class LyricLine {
  final Duration time;
  final String text;

  /// 翻译（有则显示在原文下方）
  final String? translation;

  const LyricLine(this.time, this.text, {this.translation});

  @override
  String toString() => '[$time] $text';
}

/// LRC 解析器 —— 移植自 Beans 的 `LyricParser` / `LyricTiming`。
///
/// 支持：
///   · 一行多时间标签  `[00:12.34][01:20.00]词`
///   · 毫秒位 2 或 3 位
///   · 翻译对齐（按时间戳配对，容忍 ±200ms 误差）
///   · 纯文本兜底（不是 LRC 就整段当一行，避免显示空白）
class LyricParser {
  LyricParser._();

  static final _tag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// 解析 LRC 原文为按时间排序的歌词行
  static List<LyricLine> parse(String? lrc, {String? translation}) {
    if (lrc == null || lrc.trim().isEmpty) return const [];

    final transMap = <int, String>{};
    if (translation != null && translation.trim().isNotEmpty) {
      for (final line in translation.split('\n')) {
        final m = _tag.firstMatch(line);
        if (m == null) continue;
        final ms = _ms(m);
        final text = line.substring(m.end).trim();
        if (text.isNotEmpty) transMap[ms] = text;
      }
    }

    final out = <LyricLine>[];
    for (final raw in lrc.split('\n')) {
      // 一行可能有多个时间标签，全部展开
      final matches = _tag.allMatches(raw).toList();
      if (matches.isEmpty) continue;
      final text = raw.substring(matches.last.end).trim();
      // 跳过纯元信息行（[ti:] [ar:] 等已被 _tag 排除，这里只挡空文本）
      if (text.isEmpty) continue;
      for (final m in matches) {
        final ms = _ms(m);
        out.add(LyricLine(
          Duration(milliseconds: ms),
          text,
          translation: _nearestTranslation(transMap, ms),
        ));
      }
    }

    if (out.isEmpty) {
      // 不是 LRC：整段当一行，至少能显示
      final plain = lrc.trim();
      if (plain.isEmpty) return const [];
      return [LyricLine(Duration.zero, plain)];
    }

    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  static int _ms(RegExpMatch m) {
    final min = int.parse(m.group(1)!);
    final sec = int.parse(m.group(2)!);
    final fracRaw = m.group(3);
    var ms = 0;
    if (fracRaw != null) {
      // 2 位 = 百分秒，3 位 = 毫秒
      ms = fracRaw.length == 3
          ? int.parse(fracRaw)
          : int.parse(fracRaw) * 10;
    }
    return min * 60000 + sec * 1000 + ms;
  }

  /// 找最接近的翻译（容忍 200ms 误差 —— 两个文件的时间戳常有毫秒级偏差）
  static String? _nearestTranslation(Map<int, String> map, int ms) {
    if (map.isEmpty) return null;
    final exact = map[ms];
    if (exact != null) return exact;
    int? best;
    var bestDiff = 200;
    for (final k in map.keys) {
      final d = (k - ms).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = k;
      }
    }
    return best == null ? null : map[best];
  }

  /// 当前时间应高亮第几行（-1 = 还没到第一行）
  ///
  /// 用二分查找：歌词可能上千行，播放时每帧都要查，线性扫会掉帧。
  static int indexAt(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) return -1;
    final ms = position.inMilliseconds;
    if (ms < lines.first.time.inMilliseconds) return -1;
    var lo = 0;
    var hi = lines.length - 1;
    var ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (lines[mid].time.inMilliseconds <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}

/// 歌曲评论（对齐 Beans 的 `SongComment`）
class SongComment {
  final String id;
  final String user;
  final String? avatarUrl;
  final String content;
  final int likedCount;
  final int time;

  const SongComment({
    required this.id,
    required this.user,
    this.avatarUrl,
    required this.content,
    this.likedCount = 0,
    this.time = 0,
  });

  factory SongComment.fromJson(Map<String, dynamic> j) => SongComment(
        id: (j['id'] ?? '').toString(),
        user: (j['user'] ?? '').toString(),
        avatarUrl: j['avatarUrl']?.toString(),
        content: (j['content'] ?? '').toString(),
        likedCount: asInt(j['likedCount']),
        time: asInt(j['time']),
      );
}

/// 播放记录（对齐 Beans 的 `PlayRecordItem`）
class PlayRecord {
  final Song song;
  final int playedAt;

  const PlayRecord({required this.song, required this.playedAt});

  Map<String, dynamic> toJson() => {
        'song': song.toJson(),
        'playedAt': playedAt,
      };

  factory PlayRecord.fromJson(Map<String, dynamic> j) => PlayRecord(
        song: Song.fromJson(Map<String, dynamic>.from(j['song'] as Map)),
        playedAt: asInt(j['playedAt']),
      );
}

/// 通用 JSON 解码（本地存储用）
dynamic decodeJson(String raw) => jsonDecode(raw);
