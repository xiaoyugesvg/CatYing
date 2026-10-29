import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/cross_platform_matcher.dart';

/// 跨平台匹配的**防错配契约测试**（纯函数，不联网）。
///
/// ── 为什么这个测试最重要 ──────────────────────────────────────
/// 跨平台匹配做错的方向不是"找不到"，而是**匹错歌** ——
/// 用户在 QQ 点了《晴天》，结果放出来的是《晴天娃娃》或某个 Live 版。
/// **那种体验比"没有免费音源"差得多**（用户听到的是完全不同的东西，
/// 而且不知道发生了什么）。
///
/// 所以 `_score` 那三重校验（歌名归一化相等 / 歌手交集 / 时长差 ≤10s）
/// 必须逐条钉死。
///
/// ⚠️ `_score` 是私有的，这里通过**归一化函数的公开行为** +
/// 一个小的"模拟打分"来覆盖：归一化是三重校验里最容易被改坏的部分
///（一个正则改错，'晴天(Live)' 和 '晴天' 就被判成不同或相同）。
void main() {
  group('歌名归一化（① 防错配的基础）', () {
    test('版本修饰必须被抹掉：(Live) 【HD】 [Remix] （伴奏）', () {
      expect(CrossPlatformMatcher.normalizeTitle('晴天'), '晴天');
      expect(CrossPlatformMatcher.normalizeTitle('晴天(Live)'), '晴天');
      expect(CrossPlatformMatcher.normalizeTitle('晴天（Live）'), '晴天');
      expect(CrossPlatformMatcher.normalizeTitle('晴天 [Remix]'), '晴天');
      expect(CrossPlatformMatcher.normalizeTitle('晴天【HD】'), '晴天');
      expect(CrossPlatformMatcher.normalizeTitle('晴天（伴奏）'), '晴天');
    });

    test('feat./ft. 及其后内容被去掉', () {
      expect(CrossPlatformMatcher.normalizeTitle('晴天 feat. 方文山'), '晴天');
      expect(CrossPlatformMatcher.normalizeTitle('晴天 ft. 方文山'), '晴天');
    });

    test('标点与空白全部去掉（中英文都要）', () {
      expect(CrossPlatformMatcher.normalizeTitle('晴 天'), '晴天');
      expect(CrossPlatformMatcher.normalizeTitle('晴天！'), '晴天');
      expect(CrossPlatformMatcher.normalizeTitle('晴天, 稻香'), '晴天稻香');
      expect(CrossPlatformMatcher.normalizeTitle('  晴天  '), '晴天');
    });

    test('大小写不敏感', () {
      expect(CrossPlatformMatcher.normalizeTitle('Hello'), 'hello');
      expect(CrossPlatformMatcher.normalizeTitle('HELLO'), 'hello');
    });

    test('🔴 归一化后不同的歌名**必须**保持不同（防误配）', () {
      // 这几组如果归一化后相等，就会把《晴天》匹到别的歌
      expect(CrossPlatformMatcher.normalizeTitle('晴天'),
          isNot(CrossPlatformMatcher.normalizeTitle('晴天娃娃')));
      expect(CrossPlatformMatcher.normalizeTitle('晴天'),
          isNot(CrossPlatformMatcher.normalizeTitle('晴天+稻香')));
      expect(CrossPlatformMatcher.normalizeTitle('后来'),
          isNot(CrossPlatformMatcher.normalizeTitle('后来遇见他')));
    });
  });

  group('歌手归一化（② 防错配）', () {
    test('多歌手分隔符都要拆开', () {
      expect(CrossPlatformMatcher.normalizeArtists('周杰伦、方文山'),
          {'周杰伦', '方文山'});
      expect(CrossPlatformMatcher.normalizeArtists('周杰伦,方文山'),
          {'周杰伦', '方文山'});
      expect(CrossPlatformMatcher.normalizeArtists('周杰伦/方文山'),
          {'周杰伦', '方文山'});
      expect(CrossPlatformMatcher.normalizeArtists('周杰伦&方文山'),
          {'周杰伦', '方文山'});
    });

    test('单歌手', () {
      expect(CrossPlatformMatcher.normalizeArtists('周杰伦'), {'周杰伦'});
    });

    test('"群星/未知"必须被过滤（否则会被误判成"歌手一致"）', () {
      expect(CrossPlatformMatcher.normalizeArtists('群星'), isEmpty);
      expect(CrossPlatformMatcher.normalizeArtists('未知'), isEmpty);
      expect(CrossPlatformMatcher.normalizeArtists('Unknown'), isEmpty);
      expect(CrossPlatformMatcher.normalizeArtists('Various Artists'), isEmpty);
      // 混合时只保留有信息量的
      expect(CrossPlatformMatcher.normalizeArtists('群星、周杰伦'), {'周杰伦'});
    });

    test('空白与大小写', () {
      expect(CrossPlatformMatcher.normalizeArtists(' 周杰伦 '), {'周杰伦'});
      expect(CrossPlatformMatcher.normalizeArtists('Jay'), {'jay'});
      expect(CrossPlatformMatcher.normalizeArtists(''), isEmpty);
    });
  });

  group('默认搜索顺序', () {
    test('🔴 必须排除喜马拉雅（有声书语义完全不同）', () {
      expect(CrossPlatformMatcher.defaultOrder,
          isNot(contains(SongSource.ximalaya)),
          reason: '喜马拉雅会把《晴天》匹到朗读版');
    });

    test('包含三个单曲平台（网易/QQ/酷狗）', () {
      expect(CrossPlatformMatcher.defaultOrder, contains(SongSource.netease));
      expect(CrossPlatformMatcher.defaultOrder, contains(SongSource.qq));
      expect(CrossPlatformMatcher.defaultOrder, contains(SongSource.kugou));
    });
  });

  group('实际匹配（不联网时必须安全返回 null）', () {
    test('空歌名直接返回 null（不发请求）', () async {
      const s = Song(id: 1, name: '   ', artists: '周杰伦');
      final r = await CrossPlatformMatcher.instance.find(s);
      expect(r, isNull);
    });

    test('平台列表为空时返回 null', () async {
      const s = Song(id: 1, name: '晴天', artists: '周杰伦');
      final r = await CrossPlatformMatcher.instance.find(s, order: const []);
      expect(r, isNull);
    });

    test('order 只有自己那个平台时返回 null（不重复搜自己）', () async {
      const s = Song(
          id: 1, name: '晴天', artists: '周杰伦', source: SongSource.qq);
      final r = await CrossPlatformMatcher.instance
          .find(s, order: const [SongSource.qq]);
      expect(r, isNull, reason: 'includeOwnPlatform=false 时必须跳过自己');
    });
  });

  group('🔴 三重校验：score() 必须挡住错配', () {
    Song mk(String name, String artists,
            {double dur = 0, SongSource src = SongSource.netease, int id = 1}) =>
        Song(id: id, name: name, artists: artists, duration: dur, source: src);

    test('① 歌名不一致 → 拒绝（哪怕歌手一样）', () {
      final t = mk('晴天', '周杰伦', dur: 269);
      expect(CrossPlatformMatcher.score(t, mk('晴天娃娃', '周杰伦', dur: 269)),
          isNull);
      expect(CrossPlatformMatcher.score(t, mk('晴天+稻香', '周杰伦', dur: 269)),
          isNull);
      expect(CrossPlatformMatcher.score(t, mk('后来遇见他', '周杰伦', dur: 269)),
          isNull);
    });

    test('② 歌手无交集 → 拒绝（哪怕歌名一样）—— 挡翻唱', () {
      final t = mk('晴天', '周杰伦', dur: 269);
      expect(CrossPlatformMatcher.score(t, mk('晴天', '某某翻唱歌手', dur: 269)),
          isNull,
          reason: '翻唱是不同的人，不能当成同一首');
    });

    test('③ 时长差 > 10s → 拒绝 —— 挡 Live/纯音乐', () {
      final t = mk('晴天', '周杰伦', dur: 269);
      // Live 版通常长 30s+
      expect(CrossPlatformMatcher.score(t, mk('晴天', '周杰伦', dur: 305)),
          isNull);
      // 差 9s 仍算合格（容差内）
      expect(CrossPlatformMatcher.score(t, mk('晴天', '周杰伦', dur: 278)),
          isNotNull);
      expect(CrossPlatformMatcher.score(t, mk('晴天', '周杰伦', dur: 260)),
          isNotNull);
    });

    test('三条都过 → 通过，且能给出理由', () {
      final t = mk('晴天', '周杰伦', dur: 269);
      final m = CrossPlatformMatcher.score(
          t, mk('晴天', '周杰伦', dur: 270, src: SongSource.kugou));
      expect(m, isNotNull);
      expect(m!.song.source, SongSource.kugou,
          reason: '匹配结果必须带"找到它的那个平台"');
      expect(m.reason, contains('歌名一致'));
      expect(m.reason, contains('歌手一致'));
      print('  score=${m.score}  reason=${m.reason}');
    });

    test('时长越接近分越高', () {
      final t = mk('晴天', '周杰伦', dur: 269);
      final near = CrossPlatformMatcher.score(t, mk('晴天', '周杰伦', dur: 269))!;
      final far = CrossPlatformMatcher.score(t, mk('晴天', '周杰伦', dur: 262))!;
      expect(near.score, greaterThan(far.score));
    });

    test('任一边时长为 0（源没给时长）时不因时长被拒', () {
      final t = mk('晴天', '周杰伦', dur: 0);
      expect(CrossPlatformMatcher.score(t, mk('晴天', '周杰伦', dur: 999)),
          isNotNull,
          reason: '没时长信息就不能拿时长当拒绝理由');
    });

    test('🔴 歌手信息不全 → **拒绝**（不再"有才校验"）', () {
      // 这条是修的重点：原来"两边都有歌手才校验"，一旦字段名不匹配
      // 导致歌手恒为空，**最关键的防翻唱规则就被静默关闭**。
      // 现在歌手不全直接拒。
      final t = mk('晴天', '周杰伦', dur: 269);
      expect(CrossPlatformMatcher.score(t, mk('晴天', '', dur: 269)), isNull,
          reason: '候选没有歌手 → 不敢匹');
      expect(CrossPlatformMatcher.score(mk('晴天', '', dur: 269),
          mk('晴天', '周杰伦', dur: 269)), isNull,
          reason: '目标没有歌手 → 不敢匹');
      expect(CrossPlatformMatcher.score(mk('晴天', '群星', dur: 269),
          mk('晴天', '周杰伦', dur: 269)), isNull,
          reason: '"群星"被归一化过滤后等于没歌手');
    });
  });
}
