import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/models/models.dart';

/// 音乐封面字段名的**契约测试**。
///
/// ── 背景（修的真实 bug："好多歌没有封面"）────────────────────────
/// Node 的 `mapTrack()`（`music_source.js`）输出的字段是
///     `cover: album.picUrl || s.picUrl || ''`
/// 而 `Song.fromJson` 原来**只读 `coverUrl`** —— 名字对不上 → 永远 null。
///
/// 后果：**所有走 `Song.fromJson` 的接口都没有封面**：
///   search / newSongs / playlistDetail(列表) / simiSongs /
///   artistSongs / albumSongs
///
/// 而 `searchAlbums` / `personalized` / 歌单本身的封面是**手动 map**
/// 的（`e['cover']`），所以那些地方正常 —— 正好解释了
/// "有的地方有封面、有的地方没有"。
void main() {
  /// Node 侧 `mapTrack()` 的真实输出样例（字段名照抄 music_source.js）
  Map<String, dynamic> nodeTrack({String cover = ''}) => {
        'id': '12345', // ⚠️ Node 给的是**字符串**
        'name': '情话小姐',
        'artists': '王欣宇',
        'album': '情话小姐',
        'cover': cover, // ← 关键：Node 叫 cover
        'duration': 264.0,
        'fee': 1,
      };

  test('🔴 Node 的 cover 字段必须被读到（原来读的是 coverUrl → 永远 null）', () {
    const url = 'https://p1.music.126.net/rIi7Qzy2i2Y==/109951170048.jpg';
    final s = Song.fromJson(nodeTrack(cover: url));
    expect(s.coverUrl, url,
        reason: 'Node 输出的是 `cover`，只读 `coverUrl` 会让所有列表都没封面');
    print('  cover="$url" → Song.coverUrl=${s.coverUrl}');
  });

  test('兼容三种字段名：coverUrl / cover / picUrl', () {
    const url = 'https://p1.music.126.net/abc==/1.jpg';
    expect(Song.fromJson({'id': 1, 'coverUrl': url}).coverUrl, url);
    expect(Song.fromJson({'id': 1, 'cover': url}).coverUrl, url);
    expect(Song.fromJson({'id': 1, 'picUrl': url}).coverUrl, url);
  });

  test('字段缺失或空串时是 null（不能变成空串，否则 UI 会尝试加载空 URL）', () {
    expect(Song.fromJson({'id': 1, 'name': 'x'}).coverUrl, isNull);
    expect(Song.fromJson({'id': 1, 'cover': ''}).coverUrl, isNull);
    expect(Song.fromJson({'id': 1, 'cover': '   '}).coverUrl, isNull);
  });

  test('优先级：coverUrl 优先于 cover（本地持久化要能覆盖远端）', () {
    const a = 'https://local/a.jpg';
    const b = 'https://remote/b.jpg';
    final s = Song.fromJson({'id': 1, 'coverUrl': a, 'cover': b});
    expect(s.coverUrl, a);
  });

  test('封面 URL 里的 `==` 不能被破坏（网易云路径里真有它）', () {
    const url =
        'https://p1.music.126.net/rIi7Qzy2i2Y_1QD7cd0MYA==/109951170048506929.jpg';
    final s = Song.fromJson(nodeTrack(cover: url));
    expect(s.coverUrl, url);
    expect(s.coverUrl!.contains('=='), isTrue, reason: 'base64 填充符必须原样保留');
  });

  test('往返序列化后封面仍在（收藏/队列持久化依赖它）', () {
    const url = 'https://p1.music.126.net/x==/9.jpg';
    final s = Song.fromJson(nodeTrack(cover: url));
    final back = Song.fromJson(jsonDecode(jsonEncode(s.toJson())));
    expect(back.coverUrl, url);
  });

  test('Node 的字符串 id 不会让解析抛异常（历史坑）', () {
    expect(() => Song.fromJson(nodeTrack()), returnsNormally);
    expect(Song.fromJson(nodeTrack()).id, 12345);
  });
}
