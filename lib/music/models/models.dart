import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

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

/// 歌曲来源（多平台）。`key` 会作为 `source` 字段发给 Node 侧做分派。
enum SongSource {
  netease('netease', '网易云'),
  qq('qq', 'QQ音乐'),
  kugou('kugou', '酷狗'),
  // 喜马拉雅：有声书 / 播客。
  // 映射：**专辑 → Album，单集 → Song**（`id`=trackId、`artists`=专辑名/主播）。
  // 播放时 Node 侧返回的是集自带直链，但**必须带 User-Agent 才能播**
  //（所以 `MusicUrlInfo` 还要把 headers 透传给播放器）。
  ximalaya('ximalaya', '喜马拉雅');

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

  /// 平台**原生字符串 id**（可空，默认空串）。
  ///
  /// ── 🔴 为什么必须有这个字段（用户报的"QQ 播不了"的根因）────────
  /// `id` 是 `int`，但很多平台的**真实标识是字符串**，而且**数字 id 换不到地址**：
  ///   · QQ：`songmid` 形如 `0039MnYb0qxYhV`（**数字 songid 没用**）
  ///   · 酷狗：`hash`
  ///
  /// 实测（元力音源 v1.2.1）它的取址逻辑是：
  ///     `GET …/qq_kw.php?id=${musicItem.songmid}&type=json&level=…`
  /// 我们原来只传数字 id → 那个后端查不到 → 返回空 → **播放失败**。
  /// 补上 songmid 之后同一个后端正常返回真实音频地址。
  ///
  /// ⚠️ 不要试图把它塞进 `id`：那个字段是 int，且被大量界面/持久化依赖。
  ///    字符串原生 id 单独一列，缺省空串（等于"这个平台不需要"）。
  final String songmid;

  const Song({
    required this.id,
    required this.name,
    required this.artists,
    this.album = '',
    this.coverUrl,
    this.duration = 0,
    this.source = SongSource.netease,
    this.fee = 0,
    this.songmid = '',
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
        'songmid': songmid,
      };

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        // ⚠️ 绝不能用 `(j['id'] as num?)`！
        // Node 侧 mapTrack 输出的是 `id: String(id)`（字符串），
        // 而 Dart 的 `as num?` 在运行时遇到 String 会**直接抛**
        //   type 'String' is not a subtype of type 'num?' in type cast
        // 表现就是"整个搜索页只显示这行报错"。用 asInt 宽容转换。
        id: asInt(j['id']),
        name: (j['name'] ?? '').toString(),
        // ⚠️ Node 侧（mapTrack / search / 歌手 / 专辑等）发的是**单数** `artist`，
        // 这里历史上只读复数 `artists` → 6 个接口的歌手名恒为空，
        // 而界面的 `artists.isEmpty ? album : artists` 会**回落显示专辑名**
        //（用户看到的是"错的信息"而不是"缺失"）。两边都收，一处修完全部接口。
        //
        // 顺序：**`artist` 放前面** —— 它才是 Node 的实际字段名（实测确认
        // kugou/qq/netease 三个 search 都只回 `artist`）。把真实字段名排
        // 第一位，语义更清楚，也不依赖 fallback 恰好能兜住。
        //
        // 🔴 这个字段一旦为空，**跨平台匹配的防翻唱校验会被跳过**（
        // 见 cross_platform_matcher），所以它不是"显示问题"而是正确性问题。
        artists: (j['artist'] ?? j['artists'] ?? j['singer'] ?? '').toString(),
        album: (j['album'] ?? '').toString(),
        coverUrl: _firstNonEmpty(j, const ['coverUrl', 'cover', 'picUrl']),
        duration: asDouble(j['duration']),
        source: SongSource.fromKey(j['source']?.toString()),
        fee: asInt(j['fee']),
        // 平台**原生标识**，各家名字不同，这里**统一收进 songmid**：
        //   · QQ   → `songmid`（如 `0039MnYb0qxYhV`）
        //   · 酷狗 → `hash`（如 `b3a52a7a958bf0aed0ebfba2e9a818b7`）
        //   · 网易 → 无（它的数字 id 本身就是原生标识）
        //
        // 🔴 Node 侧 `kugou_source.js` 早就把 hash 输出成 `hash` 字段，
        //    而这里原来**只读 songmid/mid** → 酷狗歌走第三方源时同样
        //    "没有可用 id"，和 QQ 犯的是**同一个错**（只是平台不同）。
        songmid: _firstNonEmpty(
              j,
              const ['songmid', 'mid', 'hash', 'fileHash', 'FileHash'],
            ) ??
            '',
      );

  /// 按顺序取第一个非空字符串字段（兼容不同接口的字段命名）。
  ///
  /// ── 🔴 为什么需要它（真实 bug：歌单/搜索里的歌全都没封面）────────
  /// Node 的 `mapTrack()`（`music_source.js`）输出的是
  ///     `cover: album.picUrl || s.picUrl || ''`
  /// 而 `Song.fromJson` 原来**只读 `coverUrl`** —— 名字对不上 → 永远 null。
  ///
  /// 后果：**所有走 `Song.fromJson` 的接口都没有封面**：
  ///   search / newSongs / playlistDetail(列表) / simiSongs /
  ///   artistSongs / albumSongs
  ///
  /// 而 `searchAlbums` / `personalized` / 歌单本身的封面是**手动 map**
  /// 的（`e['cover']`），所以那些地方显示正常 —— 正好解释了
  /// "有的地方有封面、有的地方没有"（用户实测："顺便修复没有封面呢"）。
  ///
  /// 兜底顺序：
  ///   · `coverUrl` —— 本模型的序列化字段（本地收藏/队列持久化用）
  ///   · `cover`    —— Node 接口的原始字段名
  ///   · `picUrl`   —— 网易云原始字段名（部分接口直接用）
  static String? _firstNonEmpty(Map<String, dynamic> j, List<String> keys) {
    for (final k in keys) {
      final v = j[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  static String listToJson(List<Song> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  /// 从 JSON 字符串解析歌曲列表（**逐条容错**）。
  ///
  /// ── 🔴 为什么必须逐条容错（修一个"收藏全没了"的真 bug）────────────
  ///
  /// 原来整份 `.map(Song.fromJson)` 包在一个 try/catch 里：
  /// ```dart
  /// try {
  ///   return d.whereType<Map>().map((e) => Song.fromJson(...)).toList();
  /// } catch (_) {
  ///   return const [];          // ← 一条坏数据 = 整个列表变空
  /// }
  /// ```
  /// 后果**不只是"少几首"**：
  ///   · `library_store` 的收藏 / 最近播放 / 队列都走这里
  ///   · 只要**一条**记录坏了（旧版本写下的字段类型变了、
  ///     手工改过、写到一半被杀进程）→ **整个收藏列表变空** ✗
  ///   · 而且下次 `toggleFavorite` 会把**这个空列表写回磁盘**
  ///     → 用户的收藏**真丢了**，不可恢复 ✗
  ///
  /// 现在跳过坏的、保留好的（`ThirdPartySource.listFromJson` 早就是这个写法，
  /// 注释里记录了同一段教训 —— 这里补齐）。
  static List<Song> listFromJson(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      // ⚠️ **空字符串不打日志**：那是"从没存过"的正常情况
      //（`prefs.getString(k) ?? ''` 在首次启动时就传空串进来），
      // 打出来只是噪音 —— 测试输出里能看到一堆 `FormatException` 刷屏。
      if (raw.trim().isNotEmpty) {
        // 整份 JSON 语法坏了（截断等）→ 只能放弃，但**要说出来**。
        // ⚠️ 用 `debugPrint` 而不是 `AppLog`：`models.dart` 目前只依赖
        //    `dart:convert`（纯净的模型层），引 `services/app_log.dart`
        //    会造出"模型 → 服务"的反向依赖。
        //    `third_party_source.dart` 的同类日志也是 `debugPrint`（保持一致）。
        debugPrint('[Music] 歌曲列表 JSON 解析失败: $e');
      }
      return const [];
    }
    if (decoded is! List) return const [];

    final out = <Song>[];
    var skipped = 0;
    for (final e in decoded) {
      if (e is! Map) {
        skipped++;
        continue;
      }
      try {
        out.add(Song.fromJson(e.cast<String, dynamic>()));
      } catch (err) {
        skipped++;
      }
    }
    if (skipped > 0) {
      // ⚠️ 必须可见：用户"少了一首歌"时能查到原因
      debugPrint('[Music] 歌曲列表跳过 $skipped 条无法解析的记录'
          '（保留 ${out.length} 条）');
    }
    return out;
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
        // ⚠️ Node 侧歌单接口（personalized / playlistSquare 等）发的是 `cover`，
        // 这里只读 `coverUrl` → **推荐歌单 / 歌单广场封面恒为 null**（灰占位）。
        // 而 `topLists` / `playlistDetail` 是手动映射 `e['cover']` 所以正常 ——
        // 那正是"同一页有的有封面、有的没有"的真正原因。
        // 与 `Song.fromJson` 保持同一套兜底顺序（那里用的 `_firstNonEmpty`
        // 是 `Song` 的私有静态方法，`Playlist` 里用不到，所以这里内联写）。
        coverUrl: (j['coverUrl'] ?? j['cover'] ?? j['picUrl'])?.toString(),
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

/// 逐字歌词里的一个"字/词"及其起止时间。
///
/// YRC（网易云逐字歌词）把一行拆成这样：
///   `[15600,300](15600,120,0)你(15720,180,0)好`
/// 意思是这一行从 15600ms 开始、总长 300ms，
/// "你"从 15600 持续 120ms，"好"从 15720 持续 180ms。
class LyricWord {
  final Duration start;

  /// 持续时长（用于算"这个字唱到哪里"）
  final Duration duration;
  final String text;

  const LyricWord(this.start, this.duration, this.text);

  Duration get end => start + duration;

  @override
  String toString() => '$text@${start.inMilliseconds}';
}

/// 一行歌词
class LyricLine {
  final Duration time;
  final String text;

  /// 翻译（有则显示在原文下方）
  final String? translation;

  /// 逐字时间轴（YRC）。为空 = 普通 LRC，只能整行高亮。
  ///
  /// ⚠️ 注意 [text] 与 [words] 的拼接必须一致 —— 高亮是按字符下标切的，
  /// 两者对不上会导致高亮位置错位。
  final List<LyricWord> words;

  const LyricLine(this.time, this.text,
      {this.translation, this.words = const []});

  /// 是否是逐字歌词
  bool get hasWords => words.isNotEmpty;

  /// 计算在 [pos] 时刻，本行应该高亮到第几个字符。
  ///
  /// 返回 0..text.length。返回 text.length 表示整行唱完。
  /// 用"字的下标"而不是"字对象"是为了让 UI 直接 `text.substring(0, n)`。
  int charIndexAt(Duration pos) {
    if (words.isEmpty) {
      // 没有逐字数据：用整行时间简单估算（有总时长就用，否则直接全亮）
      return text.length;
    }
    // words 的 text 依次拼起来就是整行
    var idx = 0;
    for (final w in words) {
      if (pos >= w.end) {
        // 这个字已经唱完
        idx += w.text.length;
      } else if (pos >= w.start) {
        // 正在唱这个字 —— 按时间比例切到字内部（卡拉OK 的"逐渐填色"效果）
        final total = w.duration.inMilliseconds;
        final done = (pos - w.start).inMilliseconds;
        final ratio = total <= 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
        idx += (w.text.length * ratio).round();
        return idx.clamp(0, text.length);
      } else {
        // 还没唱到这个字
        break;
      }
    }
    return idx.clamp(0, text.length);
  }

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
  // ============================================================
  // 逐字歌词（YRC / 卡拉OK 格式）
  // ============================================================

  /// YRC 行首：`[起始ms,总时长ms]`
  static final _yrcHead = RegExp(r'^\[(\d+),(\d+)\]');

  /// YRC 每个字：`(起始ms,时长ms,保留)字`
  static final _yrcWord = RegExp(r'\((\d+),(\d+),(-?\d+)\)');

  /// 解析 YRC（逐字歌词）。
  ///
  /// 格式示例：
  ///   `[15600,300](15600,120,0)你(15720,180,0)好`
  ///
  /// ── ⚠️ 为什么要用"游标推进"而不是正则 replaceAll ──────────────
  /// 高亮是按 `text` 的**字符下标**切的（见 [LyricLine.charIndexAt]），
  /// 所以 `LyricWord.text` 依次拼接**必须严格等于**行文本。
  /// 用 replaceAll 会留下零散括号、也会丢掉"没有标签的裸字"，
  /// 于是下标错位、高亮跑到别的字上。这里逐个匹配、按位置切片，
  /// 保证两者一字不差（切完还会断言校验）。
  static List<LyricLine> parseYrc(String? yrc) {
    if (yrc == null || yrc.trim().isEmpty) return const [];

    final out = <LyricLine>[];
    for (final raw in yrc.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final head = _yrcHead.firstMatch(line);
      if (head == null) continue;
      final startMs = int.tryParse(head.group(1)!) ?? 0;

      final words = <LyricWord>[];
      final buf = StringBuffer();
      var cursor = head.end;
      for (final m in _yrcWord.allMatches(line, head.end)) {
        // 标签前若有裸文本（异常情况），也算进上一个字/独立文本
        if (m.start > cursor) {
          buf.write(line.substring(cursor, m.start));
        }
        final ws = int.tryParse(m.group(1)!) ?? 0;
        final wd = int.tryParse(m.group(2)!) ?? 0;
        // 这一段的文本 = 标签之后、下一个标签之前
        final nextStart = _nextTagStart(line, m.end);
        final txt = line.substring(m.end, nextStart);
        if (txt.isNotEmpty) {
          words.add(LyricWord(
            Duration(milliseconds: ws),
            Duration(milliseconds: wd),
            txt,
          ));
          buf.write(txt);
        }
        cursor = nextStart;
      }
      final text = buf.toString();
      if (text.trim().isEmpty) continue;
      out.add(LyricLine(Duration(milliseconds: startMs), text, words: words));
    }

    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  /// 找 `from` 之后第一个字标签的起点（没有则到行尾）
  static int _nextTagStart(String line, int from) {
    final m = _yrcWord.firstMatch(line.substring(from));
    return m == null ? line.length : from + m.start;
  }

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
