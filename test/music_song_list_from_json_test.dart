import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/music/models/models.dart';

/// 回归测试：`Song.listFromJson` 必须**逐条容错**。
///
/// ── 为什么这个测试重要（真丢数据）────────────────────────────────
/// 原来实现是**整份** try/catch：
/// ```dart
/// try {
///   return d.whereType<Map>().map((e) => Song.fromJson(...)).toList();
/// } catch (_) {
///   return const [];        // ← 一条坏数据 = 整个列表变空
/// }
/// ```
/// 而 `library_store` 的**收藏 / 最近播放 / 队列**都走这个方法：
///   · 只要一条记录坏了 → **整个收藏列表变空** ✗
///   · 下次 `toggleFavorite` 会把**这个空列表写回磁盘**
///     → 用户收藏**真丢了**，不可恢复 ✗
///
/// ── 本测试锁定的不变量（刻意不猜"哪种会被跳过"）────────────────
/// `Song.fromJson` 的字段转换**极其宽容**（`asInt`/`asDouble`/
/// `_firstNonEmpty`/`.toString()` 都不抛），所以**大多数畸形 Map 会被
/// 收下并把值退化成默认**（例如 id 变 0）—— 这是**好事**。
/// 真正要钉死的是：
///   ① 只要有东西抛异常，**好条目必须留下**（旧实现是整份丢）
///   ② 非 Map 元素（null / 字符串 / 数字 / bool）必须被跳过
///   ③ 整份 JSON 语法坏了才允许返回空
void main() {
  Song good(int id) => Song(
        id: id,
        name: '歌$id',
        artists: '歌手$id',
        source: SongSource.netease,
      );

  /// 把一首歌序列化成**单个** JSON 对象（去掉数组括号）
  Map<String, dynamic> one(Song s) {
    final arr = Song.listToJson([s]);
    return jsonDecode(arr.substring(1, arr.length - 1)) as Map<String, dynamic>;
  }

  group('Song.listFromJson 逐条容错', () {
    test('全部合法 → 全部保留（顺序不变）', () {
      final list = Song.listFromJson(Song.listToJson([good(1), good(2), good(3)]));
      expect(list.length, 3);
      expect(list.map((s) => s.id).toList(), [1, 2, 3], reason: '顺序必须保持');
    });

    test('🔴 坏条目不能吃掉好条目（这就是原来的 bug）', () {
      final raw = jsonEncode([
        one(good(1)),
        // 各种畸形：类型乱、值嵌套、源是数组
        {'id': ['坏'], 'name': {'x': 1}, 'source': []},
        // 真正会被**跳过**的：非 Map
        null,
        '字符串',
        42,
        true,
        one(good(3)),
      ]);

      late List<Song> list;
      expect(() => list = Song.listFromJson(raw), returnsNormally,
          reason: '坏条目绝不能让它抛（旧实现抛了就整份丢）');

      // ① 两首好歌**必须**原样留住
      final ids = list.map((s) => s.id).toList();
      expect(ids.contains(1), isTrue, reason: '前面那首好歌必须留住');
      expect(ids.contains(3), isTrue, reason: '后面那首好歌必须留住');

      // ② 非 Map 的 4 个（null/字符串/42/true）必须被跳过
      //    → 2 首好歌 + 1 个畸形 Map = 3
      expect(list.length, 3,
          reason: '应为：2 首好歌 + 1 个畸形 Map（宽容收下）；'
              'null/字符串/42/true 被跳过');

      // ③ 畸形 Map 的值退化成默认（而不是把整份搞坏）
      final bad = list[1];
      expect(bad.id, 0, reason: '畸形的 id 应退化成 0');
    });

    test('非 Map 元素被跳过（开头 / 中间 / 结尾都试）', () {
      final raw = jsonEncode([
        null,
        '开头就被跳过',
        one(good(1)),
        false,
        one(good(2)),
        3.14,
      ]);
      final list = Song.listFromJson(raw);
      expect(list.map((s) => s.id).toList(), [1, 2],
          reason: '只有两个 Map，其余 4 个非 Map 全跳过');
    });

    test('整份 JSON 语法坏了 → 返回空（这条只能放弃）', () {
      expect(Song.listFromJson('[{"id":1,'), isEmpty);
      expect(Song.listFromJson('not json at all'), isEmpty);
      expect(Song.listFromJson('[{],}'), isEmpty);
    });

    test('合法 JSON 但不是数组 → 空', () {
      expect(Song.listFromJson('{"id":1}'), isEmpty);
      expect(Song.listFromJson('"字符串"'), isEmpty);
      expect(Song.listFromJson('123'), isEmpty);
      expect(Song.listFromJson('null'), isEmpty);
    });

    test('空字符串 / 空数组 → 空（不抛）', () {
      expect(Song.listFromJson(''), isEmpty);
      expect(Song.listFromJson('[]'), isEmpty);
    });

    test('字段类型全乱 → 不抛，值退化成默认', () {
      final raw = jsonEncode([
        {
          'id': ['不是数字'],
          'name': 12345,
          'artist': false,
          'duration': '不是时间',
          'source': 42,
          'fee': {'a': 1},
        }
      ]);
      late List<Song> list;
      expect(() => list = Song.listFromJson(raw), returnsNormally,
          reason: '字段类型乱不该抛（`asInt`/`asDouble` 都是宽容的）');
      expect(list.length, 1, reason: '它是 Map，就该被收下');
      expect(list.first.id, 0);
      expect(list.first.name, '12345', reason: '`toString()` 会把它变成字符串');
    });

    test('往返一致：toJson → fromJson 保真', () {
      final src = [good(1), good(2)];
      final back = Song.listFromJson(Song.listToJson(src));
      expect(back.length, 2);
      expect(back.map((s) => s.identityKey).toList(),
          src.map((s) => s.identityKey).toList());
    });
  });
}
