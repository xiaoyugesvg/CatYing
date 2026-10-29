import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/emby/emby_models.dart';

void main() {
  group('EmbyServer', () {
    test('地址规范化：补协议、去尾部斜杠', () {
      final s = EmbyServer(
        id: 'a',
        name: '家',
        baseUrl: ' 192.168.1.10:8096/ ',
        username: 'u',
        password: 'p',
      );
      expect(s.normalizedUrl, 'http://192.168.1.10:8096');
    });

    test('https 地址保持不变，序列化可往返', () {
      final s = EmbyServer(
        id: 'b',
        name: '远程',
        baseUrl: 'https://emby.example.com/',
        username: 'u',
        password: 'p',
        accessToken: 'tk',
        userId: 'uid',
        deviceId: 'dev',
      );
      expect(s.normalizedUrl, 'https://emby.example.com');
      expect(s.isConfigured, isTrue);
      final back = EmbyServer.fromJson(s.toJson());
      expect(back.name, '远程');
      expect(back.accessToken, 'tk');
      expect(back.userId, 'uid');
      expect(back.deviceId, 'dev');
    });

    test('未登录时 isConfigured=false', () {
      final s = EmbyServer(
        id: 'c',
        name: 'x',
        baseUrl: 'http://x',
        username: 'u',
        password: 'p',
      );
      expect(s.isConfigured, isFalse);
    });
  });

  group('EmbyItem', () {
    test('剧集字段解析与分集标签', () {
      final item = EmbyItem.fromJson({
        'Id': '1',
        'Name': '第一集',
        'Type': 'Episode',
        'SeriesId': 's1',
        'SeriesName': '测试剧',
        'ParentIndexNumber': 1,
        'IndexNumber': 3,
        'RunTimeTicks': 24 * 60 * 10000000,
        'ImageTags': {'Primary': 'tag1'},
      });
      expect(item.isEpisode, isTrue);
      expect(item.episodeLabel, 'S01E03');
      expect(item.durationText, '24 分钟');
      expect(item.imageTag, 'tag1');
    });

    test('剧集/电影类型判定', () {
      expect(
        EmbyItem.fromJson({'Id': '1', 'Name': 'a', 'Type': 'Series'}).isSeries,
        isTrue,
      );
      expect(
        EmbyItem.fromJson({'Id': '2', 'Name': 'b', 'Type': 'Movie'}).isMovie,
        isTrue,
      );
      expect(
        EmbyItem.fromJson(
          {'Id': '3', 'Name': 'c', 'Type': 'CollectionFolder'},
        ).isFolderish,
        isTrue,
      );
    });
  });
}
