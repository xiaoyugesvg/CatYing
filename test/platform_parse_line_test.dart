// 平台链接（爱奇艺 / 腾讯 / 优酷 / 芒果 / B站 / PPTV）的解析规则。
//
// ── 用户 2026-10-31 ────────────────────────────────────────────
// 「爱奇艺、腾讯、优酷、芒果、哔哩哔哩、PPTV 这些域名链接的解析弄了么？
//   这些域名的播放链接要加解析线路才能嗅探呢」
//
// 这句话点出了两个必须成立的事实，本文件把它们钉死：
//   ① 这些域名**要认出来**，不能当直链丢给播放器（B站 URL 连 .html 都没有）；
//   ② 嗅探的对象是「**套过线路的地址**」（`jx.xx/?url=v.qq.com/...`），
//      不是平台页本身 —— 直接嗅探平台页是确定性的 0 候选
//      （SPA + 会员校验 + DRM）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/services/media_resolver.dart';
import 'package:tvbox/services/parse_lines.dart';
import 'package:tvbox/services/platform_domains.dart';
import 'package:tvbox/services/play_pipeline.dart';

String _read(String relative) => File(relative).readAsStringSync();

void main() {
  group('六个平台的域名都要认出来', () {
    // 平台 → 一条真实形态的正片页
    const cases = <String, String>{
      '爱奇艺': 'https://www.iqiyi.com/v_19rr7qhfxs.html',
      '腾讯视频': 'https://v.qq.com/x/cover/mzc00200803dr6b/g4102ay41nf.html',
      '优酷': 'https://v.youku.com/v_show/id_XNTk1MjM3MjAw.html',
      '芒果TV': 'https://www.mgtv.com/b/123456/7890123.html',
      '哔哩哔哩': 'https://www.bilibili.com/video/BV1xx411c7mD',
      'PPTV': 'https://v.pptv.com/show/abcdef.html',
    };

    cases.forEach((name, url) {
      test('$name → $url', () {
        expect(
          matchVideoPlatform(url)?.name,
          name,
          reason: '$name 的正片页没被认出来 ⇒ 会被当直链丢给播放器白卡，'
              '或者被当普通网页去抓 HTML（SPA 一定空手）',
        );
      });
    });

    test('子域名 / 短链也算', () {
      expect(matchVideoPlatform('https://m.iqiyi.com/v_1.html')?.name, '爱奇艺');
      expect(matchVideoPlatform('https://b23.tv/abc123')?.name, '哔哩哔哩');
      expect(matchVideoPlatform('https://m.mgtv.com/b/1/2.html')?.name, '芒果TV');
      expect(matchVideoPlatform('https://www.tudou.com/x')?.name, '优酷');
    });

    test('长得像但不是的域名不能误判', () {
      for (final bad in const [
        'https://v.qq.com.evil.example/x.html',
        'https://fakeiqiyi.com/v_1.html',
        'https://notbilibili.com/video/BV1',
        'https://example.com/play/1.html',
      ]) {
        expect(
          matchVideoPlatform(bad),
          isNull,
          reason: '$bad 被误判成平台页 ⇒ 会白套一条解析线路，还可能把别人的'
              '正常播放页解析坏',
        );
      }
    });
  });

  group('选路：平台页 / 已套接口 / 普通页', () {
    test('平台页 → platform', () {
      expect(
        PlayPipeline.routeFor('https://v.qq.com/x/cover/a/b.html'),
        PlayRoute.platform,
      );
    });

    test('已套过接口的地址 → parseUrl（不能重复套一层线路）', () {
      const wrapped =
          'https://jx.muiu.site/?url=https://v.qq.com/x/cover/a/b.html';
      expect(PlayPipeline.routeFor(wrapped), PlayRoute.parseUrl);
      // 顺序有讲究：parseUrl 必须先于 platform 判，否则会再套一层
      // `jx.xx/?url=jx.xx/?url=...`，接口直接拒。
      expect(looksLikeParseUrl(wrapped), isTrue);
    });

    test('普通播放页 → plainPage', () {
      expect(
        PlayPipeline.routeFor('https://www.example.com/play/1.html'),
        PlayRoute.plainPage,
      );
      expect(PlayPipeline.routeFor(''), PlayRoute.plainPage);
    });
  });

  group('平台页不能被当直链丢给播放器', () {
    test('B站 URL 没有 .html 也不会被误判成媒体', () {
      final r = PlayPipeline.instance
          .resolve('https://www.bilibili.com/video/BV1xx411c7mD');
      expect(r.isPage, isTrue);
      expect(r.route, PlayRoute.platform);
    });

    test('腾讯 cover 页同理', () {
      final r = PlayPipeline.instance
          .resolve('https://v.qq.com/x/cover/mzc00200803dr6b/g4102ay41nf.html');
      expect(r.isPage, isTrue);
      expect(r.route, PlayRoute.platform);
    });

    test('但平台 CDN 上的真媒体仍要当直链', () {
      // `apd-xxx.v.qq.com` 命中平台域名规则，可它是真 mp4 ——
      // 一律拦成网页就等于「能播的地址被判死」。
      final r =
          PlayPipeline.instance.resolve('https://apd-xxx.v.qq.com/a/b/c.mp4');
      expect(r.isMedia, isTrue);
      expect(
        PlayPipeline.instance
            .resolve('https://apd-xxx.v.qq.com/a/b/c.m3u8')
            .isMedia,
        isTrue,
      );
    });
  });

  group('解析线路拼接（平台页要套的就是它）', () {
    test('`?url=` 后缀式：原样拼', () {
      const line = ParseLine(id: 'l1', name: '示例', url: 'https://jx.x/?url=');
      expect(
        line.apply('https://v.qq.com/x/cover/a/b.html'),
        'https://jx.x/?url=https://v.qq.com/x/cover/a/b.html',
      );
    });

    test('`{url}` 模板式：占位符换成编码后的地址', () {
      const line = ParseLine(
        id: 'l2',
        name: '示例',
        url: 'https://jx.x/jx.php?u={url}&t=0',
      );
      final out = line.apply('https://v.qq.com/x/cover/a/b.html');
      expect(out, contains('t=0'));
      expect(out, isNot(contains('{url}')));
      // 编码过：`://` 变成 `%3A%2F%2F`
      expect(out.toLowerCase(), contains('%3a%2f%2f'));
    });

    test('applyEncoded 整条编码（有的接口只认这种）', () {
      const line = ParseLine(id: 'l3', name: '示例', url: 'https://jx.x/?url=');
      final out = line.applyEncoded('https://v.qq.com/x.html?a=1&b=2');
      expect(out, isNot(contains('?a=1')));
      expect(out.toLowerCase(), contains('%3a%2f%2f'));
      expect(out.toLowerCase(), contains('%26'));
    });
  });

  group('sniffTargetFor：决定嗅探哪个地址', () {
    test('普通播放页 → 原样嗅探', () async {
      const url = 'https://www.example.com/play/1.html';
      final t = await MediaResolver.instance.sniffTargetFor(url);
      expect(t.url, url);
      expect(t.viaParseLine, isFalse);
      expect(t.label, '原页面');
    });

    test('已套过接口的地址 → 原样嗅探（不再套第二层）', () async {
      const url = 'https://jx.muiu.site/?url=https://v.qq.com/x/cover/a/b.html';
      final t = await MediaResolver.instance.sniffTargetFor(url);
      expect(t.url, url);
      expect(t.viaParseLine, isFalse);
    });

    test('平台页 → 套线路（有线路时），没有线路也不抛异常', () async {
      // 单测环境里 ParseLineStore 读不到配置 ⇒ 拿不到线路。
      // 这里只保证「不抛、不静默变成空 URL」，具体套哪条由集成侧验证。
      final t = await MediaResolver
          .instance
          .sniffTargetFor('https://v.qq.com/x/cover/a/b.html');
      expect(t.url, isNotEmpty);
      expect(t.url, startsWith('http'));
    });
  });

  group('静态守卫：平台页嗅探的必须是线路页', () {
    test('两处嗅探调用都传 target.url，不是 pageUrl', () {
      final src = _read('lib/services/media_resolver.dart');
      final sniffCalls =
          RegExp(r'MediaSniffService\.instance\.sniff\(').allMatches(src).length;
      final targetUses = RegExp(r'target\.url').allMatches(src).length;
      expect(sniffCalls, 2, reason: '嗅探调用点数量变了（嗅探优先 + 兜底），请核对');
      expect(
        targetUses,
        greaterThanOrEqualTo(2),
        reason: '嗅探传的又变回 pageUrl 了 ⇒ 平台页会去嗅探平台页本身，'
            '一定 0 候选（用户 2026-10-31 说的「要加解析线路才能嗅探」）',
      );
    });

    test('平台页有独立的宽预算', () {
      final src = _read('lib/services/media_resolver.dart');
      expect(src.contains('_platformBudget'), isTrue);
      final m = RegExp(
        r'static const Duration _platformBudget = Duration\(seconds: (\d+)\);',
      ).firstMatch(src);
      expect(m, isNotNull, reason: '找不到 _platformBudget 定义');
      final platformSec = int.parse(m!.group(1)!);
      final defSec = int.parse(
        RegExp(r'static const Duration defaultBudget = Duration\(seconds: (\d+)\);')
            .firstMatch(src)!
            .group(1)!,
      );
      expect(
        platformSec,
        greaterThan(defSec),
        reason: '平台页要先套线路再嗅探，比普通页多一整步，预算不能一样',
      );
    });

    test('选路必须在嗅探优先分支之前算出来', () {
      final src = _read('lib/services/media_resolver.dart');
      final routeIdx = src.indexOf('final route = PlayPipeline.routeFor(pageUrl);');
      final sniffFirstIdx = src.indexOf('if (sniffFirst && allowSniff)');
      expect(routeIdx, greaterThan(-1));
      expect(sniffFirstIdx, greaterThan(-1));
      expect(
        routeIdx < sniffFirstIdx,
        isTrue,
        reason: '嗅探对象取决于选路（平台页要套线路），route 必须先算',
      );
    });
  });
}
