import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/services/media_sniff_service.dart';
import 'package:tvbox/services/sniffer_hook_js.dart';
import 'package:tvbox/services/webview_sniffer.dart';

/// 嗅探 hook 的回归测试。
///
/// 这里的被测对象是**拼在 Dart 字符串里的 JS** —— `flutter analyze` 管不到它，
/// 语法写错 / 少调一个函数都要等真机跑起来才发现。所以：
///   1. 关键采集点用「必须包含某段代码」钉住（改坏了立刻红）；
///   2. 有 node 时再跑一遍 `node --check`（真语法校验，CI 上有 node）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('注入脚本：采集点不能少', () {
    test('XHR 必须读响应体（解析接口把地址放在 JSON 里）', () {
      // 实测 jx.muiu.site：api.php?tp=checkPlay 返回
      //   {"type":"hls","url":"https://…/a.m3u8"}
      // 请求 URL 没有媒体特征、content-type 是 application/json，
      // 只读 URL + content-type 的话一条都抓不到。
      expect(kSnifferHookJs, contains('scanXhrBody'));
      expect(
        _hasLiveCode(kSnifferHookJs, 'scanXhrBody(self)'),
        isTrue,
        reason: 'loadend 回调里必须真的调用，光定义不调（或注释掉）等于没写',
      );
      expect(kSnifferHookJs, contains('responseText'));
    });

    test('fetch 必须读响应体（clone 一份，别消费调用方的 body）', () {
      expect(_hasLiveCode(kSnifferHookJs, 'resp.clone()'), isTrue);
      expect(_hasLiveCode(kSnifferHookJs, "scanText(t, 'fetch-body')"), isTrue);
    });

    test('响应体里的 \\/ 转义必须还原', () {
      // JSON 原文是 https:\/\/a.com\/x.m3u8（斜杠前有反斜杠），
      // 不还原的话 MEDIA_RE 匹配不到扩展名，等于白扫。
      expect(kSnifferHookJs, contains(r"s.indexOf('\\/')"));
      expect(kSnifferHookJs, contains(r's.replace(/\\\//g'));
    });

    test('响应体扫描要有大小上限（别把 m3u8 正文整段缓冲）', () {
      expect(kSnifferHookJs, contains('BODY_MAX'));
    });

    test('变量层必须认识 xyplay（MUAO 系解析站的播放器）', () {
      // jx.muiu.site 用 xyplayer，把地址存成实例属性 xyplay.url。
      // 不在 VAR_NAMES 里就永远扫不到 —— 而它是这条链的源头。
      expect(kSnifferHookJs, contains("'xyplay'"));
    });

    test('变量层要挖播放器实例的 .url（明文在这，stray.url 是密文）', () {
      // api-api.789jiexi.net：密文放 stray.url（不是 http 开头，直接跳过），
      // 明文只在 console.log 和 `stray.ad = new Artplayer({url: …})` 里。
      // 前者要求 hook 早于那句 log；后者只要实例建出来就一直有效，
      // 是「hook 晚到」时的唯一兜底。
      expect(_hasLiveCode(kSnifferHookJs, 'if (o.ad) dig(o.ad'), isTrue);
      expect(_hasLiveCode(kSnifferHookJs, 'if (o.player) dig(o.player'), isTrue);
    });

    test('四类采集 + iframe 跟随都还在（且在定时器里被调用）', () {
      for (final fn in ['scanDom', 'scanPerf', 'scanVars', 'scanFrames']) {
        expect(
          _hasLiveCode(kSnifferHookJs, 'function $fn('),
          isTrue,
          reason: '$fn 的定义没了',
        );
        expect(
          _hasLiveCode(kSnifferHookJs, '$fn();'),
          isTrue,
          reason: '$fn 定义了但没被调用（定时器 / load 事件里）',
        );
      }
      // iframe 必须当 'frame' 回传，否则会被当成播放候选
      expect(kSnifferHookJs, contains("kind: 'frame'"));
    });

    test('hook 幂等（重复注入不能重复装）', () {
      expect(kSnifferHookJs, contains('__catSniffInstalled'));
    });
  });

  group('注入脚本：语法', () {
    final hasNode = _nodeAvailable();

    test('三段 JS 都能通过 node --check', () {
      for (final e in {
        'kSnifferHookJs': kSnifferHookJs,
        'kAutoPlayNudgeJs': kAutoPlayNudgeJs,
        'kSilenceMediaJs': kSilenceMediaJs,
      }.entries) {
        final f = File(
          '${Directory.systemTemp.path}/cat_sniff_${e.key}.js',
        )..writeAsStringSync(e.value);
        final r = Process.runSync('node', ['--check', f.path]);
        expect(
          r.exitCode,
          0,
          reason: '${e.key} 语法错误：${r.stderr}',
        );
        f.deleteSync();
      }
    }, skip: hasNode ? false : '本机没有 node，跳过语法校验');
  });

  group('iframe 跟随顺序', () {
    test('优先挑带 url= 的（避开广告落地页）', () {
      final c = SnifferCollector();
      c.add('https://ad.top/?shareName=x', kind: 'frame', via: 'frame');
      c.add('https://jx.com/?url=https%3A%2F%2Fv.qq.com%2Fa', kind: 'frame', via: 'frame');
      expect(c.nextFrame(<String>{}), contains('url='));
    });

    test('已访问过的要跳过（防止 302 回环原地打转）', () {
      // 实测 ckplayer.vip：jx.php 不带 Referer 会 302 回 jiexi/，
      // 而 jiexi/ 又指向 jx.php —— 不排除已访问就会来回跳。
      final c = SnifferCollector();
      const a = 'https://ck.com/jiexi/?url=x';
      const b = 'https://ck.com/jx.php?url=x';
      c.add(a, kind: 'frame', via: 'frame');
      c.add(b, kind: 'frame', via: 'frame');

      expect(c.nextFrame(<String>{}), a);
      expect(c.nextFrame({a}), b);
      expect(c.nextFrame({a, b}), isNull);
    });

    test('iframe 不进播放候选（它是下一层要跟的地址，不是媒体）', () {
      final c = SnifferCollector();
      c.add('https://x.com/a.m3u8', kind: 'frame', via: 'frame');
      expect(c.count, 0);
      expect(c.frames, hasLength(1));
    });
  });

  group('分层诊断（SniffHop）', () {
    SniffHop hop({
      required String url,
      String? landed,
      int index = 1,
      String note = '',
    }) =>
        SniffHop(
          index: index,
          url: url,
          landedUrl: landed,
          elapsed: const Duration(seconds: 4),
          candidateCount: 0,
          frameCount: 2,
          note: note,
        );

    test('落地地址和请求地址不同 ⇒ 判定为被跳转', () {
      // 实测 ckplayer.vip/jx.php 不带 Referer 就是这种情况：
      // 请求 jx.php，落地在 jiexi/ —— 跟帧循环原地打转。
      final h = hop(
        url: 'https://www.ckplayer.vip/jx.php?url=x',
        landed: 'https://www.ckplayer.vip/jiexi/?url=x',
      );
      expect(h.redirected, isTrue);
    });

    test('只有 query 不同不算跳转（解析链每层都带不同的 url= 参数）', () {
      final h = hop(
        url: 'https://a.com/jiexi/?url=https%3A%2F%2Fv.qq.com%2F1',
        landed: 'https://a.com/jiexi/?url=https%3A%2F%2Fv.qq.com%2F2',
      );
      expect(h.redirected, isFalse,
          reason: 'query 变了就报「被跳转」会满屏假警报，真问题反而被淹掉');
    });

    test('落地地址未知 ⇒ 不判定为跳转', () {
      expect(hop(url: 'https://a.com/x', landed: null).redirected, isFalse);
      expect(hop(url: 'https://a.com/x', landed: '').redirected, isFalse);
    });

    test('路径不同要报（/jx.php → / 也算换了页面）', () {
      expect(
        hop(url: 'https://a.com/jx.php', landed: 'https://a.com/').redirected,
        isTrue,
      );
    });

    test('SniffResult 默认没有分层（没跑过嗅探时界面不该画空壳）', () {
      expect(const SniffResult().hops, isEmpty);
    });
  });
}

bool _nodeAvailable() {
  try {
    final r = Process.runSync('node', ['--version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 这段代码是否**真的在执行**（不在注释行里）。
///
/// 只用 `contains` 的话，把调用注释掉测试照样绿 —— 而这个仓库里
/// 「注释说做了、代码其实没做」已经踩过两次（`BackdropFilter` 不要 child、
/// `play_url_sanitizer` 的「query 里的 | 不会被误伤」）。
bool _hasLiveCode(String js, String snippet) {
  for (final line in js.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('//')) continue;
    if (t.contains(snippet)) return true;
  }
  return false;
}
