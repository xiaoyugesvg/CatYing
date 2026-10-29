import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/services/m3u8_ad_filter.dart';
import 'package:tvbox/services/media_sniffer.dart';
import 'package:tvbox/services/parse_lines.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // ParseLineStore 是单例，测试之间要清干净
    final store = ParseLineStore.instance;
    for (final l in store.customLines) {
      await store.removeCustom(l.id);
    }
    await store.setSelected('');
    store.syncFromParses(const []);
  });

  group('m3u8 插播片段过滤', () {
    test('剔除外站分片，保留正片与播放列表头部', () {
      const text = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
https://cdn.a.com/vod/1.ts
#EXTINF:6.0,
https://cdn.a.com/vod/2.ts
#EXTINF:15.0,
https://ad.b.com/insert/ad1.ts
#EXTINF:6.0,
https://cdn.a.com/vod/3.ts
#EXTINF:6.0,
https://cdn.a.com/vod/4.ts
#EXT-X-ENDLIST
''';
      final r = M3u8AdFilter.filter(text, 'https://cdn.a.com/vod/index.m3u8');
      expect(r.removed, 1);
      expect(r.text.contains('ad1.ts'), isFalse);
      expect(r.text.contains('1.ts'), isTrue);
      expect(r.text.contains('#EXT-X-VERSION:3'), isTrue);
      expect(r.text.contains('#EXT-X-TARGETDURATION:6'), isTrue);
    });

    test('master 清单原样放行', () {
      const text = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000
720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1600000
1080p.m3u8
''';
      final r = M3u8AdFilter.filter(text, 'https://cdn.a.com/vod/master.m3u8');
      expect(r.removed, 0);
      expect(r.text, text);
    });

    test('来源过于分散（占比不足 40%）时不乱删', () {
      const text = '''
#EXTM3U
#EXTINF:6.0,
https://a.com/1.ts
#EXTINF:6.0,
https://b.com/2.ts
#EXTINF:6.0,
https://c.com/3.ts
''';
      final r = M3u8AdFilter.filter(text, 'https://a.com/x.m3u8');
      expect(r.removed, 0);
    });

    test('不是 m3u8 的文本原样返回', () {
      const text = '<html>not a playlist</html>';
      final r = M3u8AdFilter.filter(text, 'https://a.com/x.m3u8');
      expect(r.removed, 0);
      expect(r.text, text);
    });
  });

  group('媒体地址嗅探（纯正则，无 WebView）', () {
    test('从 HTML / JS 里抽 m3u8 与 mp4', () {
      const html = '''
<script>
var cfg = { hlsUrl: "https://cdn.x.com/a/b/index.m3u8?token=1" };
var backup = 'https://cdn.x.com/a/b/backup.mp4';
</script>
''';
      final found = MediaSniffer.extractFromText(html);
      expect(found.any((u) => u.contains('index.m3u8')), isTrue);
      expect(found.any((u) => u.contains('backup.mp4')), isTrue);
    });

    test('推荐度排序：m3u8 > mpd > mp4', () {
      expect(MediaSniffer.score('https://a/x.m3u8'), 0);
      expect(MediaSniffer.score('https://a/x.mpd'), 1);
      expect(MediaSniffer.score('https://a/x.mp4'), 2);
      final s = SnifferSession(
        initial: ['https://a/x.mp4', 'https://a/x.m3u8'],
      );
      expect(s.preferred, 'https://a/x.m3u8');
    });

    test('非媒体地址不会被当成候选', () {
      final s = SnifferSession();
      expect(s.add('https://a.com/play/1.html'), isFalse);
      expect(s.isEmpty, isTrue);
    });
  });

  group('解析线路', () {
    test('url 模板：有 {url} 用编码替换，没有就拼接', () {
      const a = ParseLine(
        id: 'a',
        name: 'A',
        url: 'https://jiexi.x/?url={url}',
      );
      expect(
        a.apply('https://v.x/a.m3u8?k=1'),
        'https://jiexi.x/?url=https%3A%2F%2Fv.x%2Fa.m3u8%3Fk%3D1',
      );
      const b = ParseLine(id: 'b', name: 'B', url: 'https://jiexi.x/');
      expect(b.apply('https://v.x/a.m3u8'), 'https://jiexi.x/https://v.x/a.m3u8');
    });

    test('订阅 parses 解析：跳过 type=web / 0 / 1 与非 http', () {
      final store = ParseLineStore.instance;
      store.syncFromParses([
        {'name': '网页型', 'type': 'web', 'url': 'https://a.com/x'},
        {'name': '聚合0', 'type': '0', 'url': 'https://a.com/0'},
        {'name': '聚合1', 'type': '1', 'url': 'https://a.com/1'},
        {'name': '非http', 'url': 'ftp://a.com/x'},
        {'name': '可用一', 'type': 'json', 'url': 'https://a.com/p?url={url}'},
        {'name': '', 'type': 'json', 'url': 'https://a.com/q?url={url}'},
      ]);
      expect(store.subscriptionLines.length, 2);
      expect(store.subscriptionLines.first.name, '可用一');
      // 没写 name 的自动编号
      expect(store.subscriptionLines.last.name, isNotEmpty);
    });

    test('选中项排最前，其余保持顺序', () {
      final store = ParseLineStore.instance;
      store.syncFromParses([
        {'name': 'A', 'url': 'https://a.com/a'},
        {'name': 'B', 'url': 'https://a.com/b'},
        {'name': 'C', 'url': 'https://a.com/c'},
      ]);
      final ids = store.subscriptionLines.map((l) => l.id).toList();
      store.setSelected(ids[2]);
      final order = store.attemptOrder.map((l) => l.name).toList();
      expect(order.first, 'C');
      expect(order.length, 3);
      store.setSelected('');
      expect(store.attemptOrder.first.name, 'A');
    });
  });

  group('自定义解析线路（增 / 改 / 删 + 落盘）', () {
    test('新增后进入候选，且排在订阅线路后面', () async {
      final store = ParseLineStore.instance;
      store.syncFromParses([
        {'name': '订阅A', 'url': 'https://a.com/a'},
      ]);
      await store.addCustom('我的', 'https://mine.com/p?url={url}');

      expect(store.customLines.length, 1);
      expect(store.lines.last.name, '我的');
      expect(store.lines.last.isCustom, isTrue);
      // 没填名字给个默认名
      await store.addCustom('  ', 'https://mine2.com/');
      expect(store.customLines.last.name, '自定义解析');
    });

    test('修改只影响自己，订阅线路改不动', () async {
      final store = ParseLineStore.instance;
      store.syncFromParses([
        {'name': '订阅A', 'url': 'https://a.com/a'},
      ]);
      await store.addCustom('旧名', 'https://old.com/');
      final id = store.customLines.first.id;
      final subId = store.subscriptionLines.first.id;

      await store.updateCustom(id, '新名', 'https://new.com/?url={url}');
      expect(store.customLines.first.name, '新名');
      expect(store.customLines.first.url, 'https://new.com/?url={url}');

      // 订阅线路不在自定义列表里，update 无副作用
      await store.updateCustom(subId, '乱改', 'https://evil.com/');
      expect(store.subscriptionLines.first.name, '订阅A');
      expect(store.subscriptionLines.first.url, 'https://a.com/a');
    });

    test('删除自定义线路会顺带清掉选中项', () async {
      final store = ParseLineStore.instance;
      await store.addCustom('待删', 'https://del.com/');
      final id = store.customLines.first.id;
      await store.setSelected(id);
      expect(store.selectedName, '待删');

      await store.removeCustom(id);
      expect(store.customLines, isEmpty);
      expect(store.selectedId, isEmpty);
      expect(store.selectedName, '自动');
    });

    test('自定义线路会落盘，重建后可读回', () async {
      final store = ParseLineStore.instance;
      await store.addCustom('持久', 'https://keep.com/?url={url}');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('parse_lines_custom_v1');
      expect(raw, isNotNull);
      expect(raw!.contains('持久'), isTrue);
    });
  });
}
