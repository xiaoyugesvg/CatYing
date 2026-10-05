import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../services/app_log.dart';
import '../models/models.dart';
import 'music_api.dart';

/// 一次跨平台匹配的候选（含"为什么选它"的依据，便于排错与展示）
class CrossPlatformMatch {
  const CrossPlatformMatch({
    required this.song,
    required this.score,
    required this.reason,
  });

  /// 匹配到的歌（**`song.source` 是找到它的那个平台**）
  final Song song;

  /// 匹配分（越高越像）
  final int score;

  /// 人话解释（如「歌名一致 · 歌手一致 · 时长差 2s」）
  final String reason;
}

/// 跨平台歌曲匹配 —— 解决「某平台的 VIP/无版权歌听不了」。
///
/// ── 要解决的真实问题 ──────────────────────────────────────────
/// 一首歌在不同平台是**不同的记录**（`identityKey = source-id`）：
///   网易云 `netease-186016` / QQ `qq-97773` / 酷狗 `kugou-158095`
///   都是《晴天》。
/// 而 `MusicApi.songUrl()` 只查**它自己那个平台**，所以：
///   · QQ 的《晴天》要会员 → 拿不到地址 → 直接失败
///   · 但同一首《晴天》在网易云/酷狗**可能是免费的**
///
/// 这个服务就是去别的平台**找同一首歌**，再拿它去解析播放地址。
///
/// ── 🔴 防错配（这是本服务最关键的部分）────────────────────────
/// 只按歌名找会匹到**完全不同的版本**：
///   · 原版 vs Live vs 翻唱 vs 纯音乐 vs 伴奏
///   · 同名不同曲（《后来》有多个版本）
/// 所以必须三重校验，且**宁可找不到，也不能匹错**
///（匹错的体验比"没有免费音源"差得多 —— 用户听到的是另一首歌）：
///
///   ① **歌名归一化后必须相等**
///      去掉 `(Live)`/`【】`/`feat. xxx` 等修饰后再比。
///      ⚠️ 只做"相等"不做"包含" —— 包含会把
///      《晴天》匹到《晴天+稻香》《晴天娃娃》。
///   ② **歌手必须有交集**
///      "周杰伦" vs "周杰伦、方文山" 算交集；
///      翻唱（"张某某"）不算。
///   ③ **时长差 ≤ 10 秒**（两边都有时长时）
///      这一条专门挡 Live（通常长 30s+）和纯音乐。
///
/// 三条**全过**才算候选，再按分数取最高。
class CrossPlatformMatcher {
  CrossPlatformMatcher._();
  static final CrossPlatformMatcher instance = CrossPlatformMatcher._();

  /// 单次匹配的总预算。
  ///
  /// ⚠️ 必须**有限**：这是"取地址失败后的补救"，不能把点歌变成等 10 秒。
  /// 3 个平台顺序搜、每个一个请求，2s 内基本能出结果；超时就放弃。
  static const Duration _budget = Duration(seconds: 6);

  /// 时长容差（秒）。超过就认为不是同一版。
  static const double _durationTolerance = 10.0;

  /// 默认搜索顺序。
  ///
  /// 顺序有讲究：**免费曲库大的排前面** ——
  /// 网易云/酷狗公开链路的免费比例比 QQ 高得多（QQ 免登录几乎拿不到地址）。
  /// 喜马拉雅**排除**（它是有声书，语义完全不同，会把《晴天》匹到朗读版）。
  static const List<SongSource> defaultOrder = [
    SongSource.kugou,
    SongSource.netease,
    SongSource.qq,
  ];

  /// 在**其它平台**上找到的**所有**合格候选，按分数从高到低。
  ///
  /// ── 🔴 为什么需要"多个候选"而不是只取最高分 ──────────────────
  /// 实测（`_probe_url_availability.cjs`）：**同一平台、同一首歌，
  /// 不同条目的可播性完全不同** ——
  /// ```
  /// kugou 「晴天」:  id=32100650   无免费音源
  ///                  id=130783548  有地址
  /// kugou 「稻香」:  id=32042828   无免费音源
  ///                  id=259470438  有地址
  /// netease「晴天」: id=2652820720 无免费音源
  ///                  id=3440441479 有地址
  /// ```
  /// 只取分数最高那一条时，恰好撞上"无免费音源"的条目就会**误判为失败**
  ///（而同一首其实有能播的条目）。
  ///
  /// 所以调用方应该**按序逐个试**：拿到地址就停。
  ///
  /// 去重规则：**归一化歌名 + 歌手集合**相同只保留分最高的那个 ——
  /// 否则同一首原版会有十几条重复候选，逐个试会非常慢。
  Future<List<CrossPlatformMatch>> findAll(
    Song song, {
    List<SongSource> order = defaultOrder,
    bool includeOwnPlatform = false,
    int maxCandidates = 15,
  }) async {
    if (song.name.trim().isEmpty) return const [];

    final targets = order
        .where((s) => includeOwnPlatform || s != song.source)
        // 喜马拉雅是有声书，不是"同一首歌"的候选
        .where((s) => s != SongSource.ximalaya)
        .toList();
    if (targets.isEmpty) return const [];

    final sw = Stopwatch()..start();
    final keyword = _searchKeyword(song);
    final all = <CrossPlatformMatch>[];

    for (final platform in targets) {
      if (sw.elapsed > _budget) {
        AppLog.instance.log('[CrossPlatform] 预算用尽（${sw.elapsedMilliseconds}ms）');
        break;
      }
      try {
        final r = await MusicApi.instance
            .search(keyword, limit: 20, source: platform)
            .timeout(_budget - sw.elapsed);
        if (!r.ok || r.list.isEmpty) continue;

        // ── 🔴 防错配前提：歌手信息**必须**拿到 ──────────────────
        //
        // 实测踩过：Node 侧 `mapTrack()` 输出的字段是**单数 `artist`**，
        // 而 `Song.fromJson` 历史读的是复数 `artists`。
        // 歌手一旦为空，`normalizeArtists` 就返回空集，而空集在 [_score]
        // 里曾经意味着"跳过歌手校验" —— **最核心的防翻唱规则被静默关闭**。
        //
        // 现在 [_score] 里歌手不全直接拒绝；这里再兜一道（过滤掉无歌手的）。
        final candidates = r.list.where((s) => s.artists.trim().isNotEmpty);
        for (final c in candidates) {
          final m = _score(song, c);
          if (m != null) all.add(m);
        }
        // ⚠️ **不 break** —— 继续搜下一个平台，攒够候选再让调用方挑
        //（这也是 findAll 比旧的 find 慢的原因：它要多搜几个平台）。
        if (all.length >= maxCandidates) break;
      } catch (e) {
        // 单个平台失败/超时不该中断整体（下一个平台还有机会）
        AppLog.instance.log('[CrossPlatform] $platform 搜索失败: $e');
      }
    }

    if (all.isEmpty) {
      AppLog.instance.log('[CrossPlatform] 「${song.name}」在其它平台没找到可信的同一首'
          '（试了 ${targets.length} 个平台，${sw.elapsedMilliseconds}ms）');
      return const [];
    }

    // 按分数降序
    all.sort((a, b) => b.score.compareTo(a.score));

    // ── 不去重（按用户要求 + 实测数据支持）────────────────────
    //
    // 原设计按「归一化歌名 + 歌手」去重，把多次出现的同一首歌合并成一个。
    // 但实测（`_probe_cross_playable.cjs`）发现**合格候选本来就很少**：
    //     QQ「晴天」   → kugou 合格 3 条 / netease 合格 **0** 条
    //     QQ「稻香」   → kugou 合格 3 条 / netease 合格 **0** 条
    //     QQ「小星星」 → kugou 合格 3 条 / netease 合格 3 条
    // 而且**同一首的多个条目可播性完全不同**（一个 no_free_source、
    // 另一个有地址）。把候选合并掉等于主动放弃了能播的那些条目。
    //
    // 所以：**一个都不删**，只按分数降序 + 封顶 [maxCandidates] 条，
    // 由调用方逐个试（拿到地址就停）。
    // 排序保留"最像的优先"，只是不再当作"唯一的"。
    final out = all.length > maxCandidates ? all.sublist(0, maxCandidates) : all;

    AppLog.instance.log('[CrossPlatform] 「${song.name}」找到 ${out.length} 个候选'
        '（合格 ${all.length} 条，**未去重**，${sw.elapsedMilliseconds}ms）'
        '${out.isEmpty ? "" : " 最高分: ${out.first.song.source.displayName} "
            "id=${out.first.song.id} score=${out.first.score}"}');
    return out;
  }

  /// 在**其它平台**上找 [song] 的同一首歌（只返回最好的一个）。
  ///
  /// ⚠️ 实际播放请用 [findAll] **逐个试** —— 最高分那条可能恰好是
  /// "无免费音源"的条目（见 [findAll] 的实测说明）。
  ///
  /// 返回 null 表示"没找到可信的同一首"—— 调用方应保留原来的失败提示
  ///（**绝不要**退回"随便拿第一条"）。
  ///
  /// [order] 可自定义搜索顺序；会自动**跳过 `song.source` 自己**
  ///（同一个平台上再搜一次没有意义）。
  Future<CrossPlatformMatch?> find(
    Song song, {
    List<SongSource> order = defaultOrder,
    /// 是否把 `song.source` 也纳入搜索（默认否）
    bool includeOwnPlatform = false,
  }) async {
    final all = await findAll(song,
        order: order, includeOwnPlatform: includeOwnPlatform, maxCandidates: 1);
    return all.isEmpty ? null : all.first;
  }

  /// 搜索关键词：`歌名 歌手` 能显著提高召回（尤其同名歌多的情况）
  static String _searchKeyword(Song song) {
    final artist = _firstArtist(song.artists);
    return artist.isEmpty ? song.name.trim() : '${song.name.trim()} $artist';
  }

  /// 三重校验 + 打分。返回 null = **不合格**（绝不放宽到"差不多就行"）。
  ///
  /// ⚠️ 标 `visibleForTesting` 是为了**让防错配规则可被单测钉死** ——
  /// 这是整个服务最不能出错的部分（匹错歌比找不到更糟）。
  @visibleForTesting
  static CrossPlatformMatch? score(Song target, Song candidate) =>
      _score(target, candidate);

  /// 三重校验 + 打分。返回 null = **不合格**（绝不放宽到"差不多就行"）。
  static CrossPlatformMatch? _score(Song target, Song candidate) {
    // ── ① 歌名归一化后必须相等 ────────────────────────────────
    final tn = normalizeTitle(target.name);
    final cn = normalizeTitle(candidate.name);
    if (tn.isEmpty || cn.isEmpty) return null;
    if (tn != cn) return null;

    // ── ② 歌手必须有交集 ──────────────────────────────────────
    final ta = normalizeArtists(target.artists);
    final ca = normalizeArtists(candidate.artists);
    // ── 🔴 歌手校验是**必需**的，不是"有才校验"────────────────
    //
    // 原来写的是"两边都有歌手信息时才校验"，这在**字段名不匹配导致
    // 歌手恒为空**的情况下会**静默关闭最关键的一条防错配规则** ——
    // 实测踩过这个坑（Node 给 `artist`，Dart 读 `artists`）。
    //
    // 现在改成：**歌手信息不全就拒绝**（宁可少匹到，也不在信息不全时匹）。
    // `find()` 里也有一道同样的兜底（过滤掉无歌手的候选）。
    if (ta.isEmpty || ca.isEmpty) return null;
    if (ta.intersection(ca).isEmpty) return null;

    // ── ③ 时长差 ≤ 10s（两边都有时长时）─────────────────────
    double? delta;
    if (target.duration > 0 && candidate.duration > 0) {
      delta = (target.duration - candidate.duration).abs();
      if (delta > _durationTolerance) return null;
    }

    // ── 打分（都是"合格"的候选，比谁更可信）──────────────────
    var score = 100;
    final reasons = <String>['歌名一致'];
    if (ta.isNotEmpty && ca.isNotEmpty) {
      score += 40;
      reasons.add('歌手一致');
    }
    if (delta != null) {
      score += (30 - delta).clamp(0, 30).round(); // 时长越接近越高
      reasons.add('时长差 ${delta.toStringAsFixed(0)}s');
    }
    if (candidate.coverUrl != null && candidate.coverUrl!.isNotEmpty) {
      score += 5;
    }

    return CrossPlatformMatch(
      song: candidate,
      score: score,
      reason: reasons.join(' · '),
    );
  }

  /// 歌名归一化：抹掉版本修饰与标点，只留下"这首歌叫什么"。
  ///
  /// ⚠️ 归一化必须**对称**（两边用同一套规则），否则 "晴天(Live)" 和
  /// "晴天" 会被判成不同。
  static String normalizeTitle(String raw) {
    var s = raw.toLowerCase();

    // 去掉成对括号里的版本说明：(Live) 【HD】 [Remix] （伴奏）…
    // 注意全角/半角都要处理 —— 中文源里两种都常见
    s = s.replaceAll(RegExp(r'[\(\（\[【][^\)\）\]】]{0,24}[\)\）\]】]'), ' ');

    // 去掉 feat./ft./with 及其后面
    s = s.replaceAll(RegExp(r'\b(feat|ft|with)\b.*$'), ' ');

    // 去掉常见版本关键词（去掉括号后仍可能裸露在外面）
    for (final w in [
      'live', 'remix', '伴奏', '纯音乐', '翻唱', '原唱', '完整版', '现场版',
      '铃声', '高音质', '无损', 'dj版', 'dj',
    ]) {
      s = s.replaceAll(w, ' ');
    }

    // 去掉标点与空白（中英文标点都去）
    s = s.replaceAll(RegExp(r'[\s\-_~·、,，.。!！?？:：;；"“”''`]'), '');
    return s.trim();
  }

  /// 歌手归一化 → 集合。
  ///
  /// 多歌手用 `、`/`,`/`/`/`&` 分隔（本 App 的 `artists` 就是这几种拼接的）。
  static Set<String> normalizeArtists(String raw) {
    return raw
        .split(RegExp(r'[、,，/&]'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        // 过滤掉"群星/未知"这类无信息量的值（否则会误判成"歌手一致"）
        .where((s) => !const ['群星', '未知', 'unknown', 'various artists'].contains(s))
        .toSet();
  }

  static String _firstArtist(String raw) {
    final set = raw.split(RegExp(r'[、,，/&]'));
    for (final s in set) {
      final t = s.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }
}
