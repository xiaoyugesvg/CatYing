// test/xbpq_p4_verify.dart
//
// P4 详情/分集/取址自检脚本（不属于正式单测，直接 `dart run` 跑）。
// 覆盖：播放串拆线路拆分集、分隔符自适应、线路标题、备选线路、
//       MacCMS 播放页兜底（player_data / encrypt / iframe base64）、
//       详情端到端、取址（直链 / 跳转 / 二级跳转 / parse:1 兜底）。

import 'dart:convert';

import 'package:tvbox/services/xbpq/xbpq_maccms.dart';
import 'package:tvbox/services/xbpq/xbpq_play.dart';
import 'package:tvbox/services/xbpq/xbpq_rule.dart';
import 'package:tvbox/services/xbpq/xbpq_source.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

int _pass = 0;
int _fail = 0;

void eq(String name, Object? actual, Object? expected) {
  if (actual == expected) {
    _pass++;
    print('PASS  $name');
  } else {
    _fail++;
    print('FAIL  $name\n      expected: $expected\n      actual  : $actual');
  }
}

void ok(String name, bool condition) => eq(name, condition, true);

/// 分类url 刻意选一个不命中任何模板家族的形态，
/// 这样测试里写的字段不会被内置模板干扰。
XbpqRule makeRule(Map<String, String> extra) {
  final map = <String, String>{
    '主页url': 'https://a.com',
    '分类url': 'https://a.com/x?p={catePg}',
    ...extra,
  };
  return XbpqRule.parse(jsonEncode(map))!;
}

XbpqSource sourceWith(Map<String, String> pages) {
  return XbpqSource(fetcher: (raw, referer, agent) async {
    for (final entry in pages.entries) {
      if (raw.startsWith(entry.key)) return entry.value;
    }
    throw const XbpqException('404 未命中夹具');
  });
}

String episodesText(XbpqEpisodes r) => r.routes
    .map((g) => g.map((e) => '${e.title}|${e.url}').join(' , '))
    .join(' / ');

void main() async {
  // ══════════════════════════════════════════════════════════
  // 分集：单线路 # 分隔
  // ══════════════════════════════════════════════════════════
  final ruleA = makeRule({
    '播放数组': '<ul class="pl"&&</ul>',
    '播放列表': '<a',
    '播放标题': '>&&</a>',
    '播放链接': 'href="&&"',
  });
  const bodyA = '<ul class="pl">'
      '<li><a href="/p/1-1-1.html">第1集</a></li>'
      '<li><a href="/p/1-1-2.html">第2集</a></li>'
      '</ul>';
  final a = XbpqPlay.episodes(bodyA, 'https://a.com/d/1.html', ruleA);
  eq('single route count', a.routes.length, 1);
  eq('single route eps', a.routes.first.length, 2);
  eq('ep title', a.routes.first.first.title, '第1集');
  eq('ep url absolute', a.routes.first.first.url, 'https://a.com/p/1-1-1.html');
  eq('route title default', a.routeTitles.first, '线路1');
  eq('best is longest', a.best.length, 2);

  // ══════════════════════════════════════════════════════════
  // 分集：$$$ 多线路
  // ══════════════════════════════════════════════════════════
  final ruleB = makeRule({'播放数组': 'id="raw">&&</div>'});
  const bodyB = '<div id="raw">'
      '第1集\$/p/1-1-1.html#第2集\$/p/1-1-2.html'
      r'$$$'
      '第1集\$/p/1-2-1.html#第2集\$/p/1-2-2.html#第3集\$/p/1-2-3.html'
      '</div>';
  final b = XbpqPlay.episodes(bodyB, 'https://a.com/d/1.html', ruleB);
  eq('multi route count', b.routes.length, 2);
  eq('multi route1 eps', b.routes[0].length, 2);
  eq('multi route2 eps', b.routes[1].length, 3);
  eq('multi best picks longest', b.best.length, 3);
  eq('multi title from \$', b.routes[0].first.title, '第1集');
  eq('multi route names',
      b.routeTitles.join(','), '线路1,线路2');

  // ══════════════════════════════════════════════════════════
  // 分集：线路数组（每个容器一条线路）
  // ══════════════════════════════════════════════════════════
  final ruleC = makeRule({
    '播放数组': '<ul class="pl"&&</ul>',
    '线路数组': 'class="rl"&&</div>',
    '播放列表': '<a',
  });
  const bodyC = '<div class="rl"><a href="/p/1-1-1.html">第1集</a>'
      '<a href="/p/1-1-2.html">第2集</a></div>'
      '<div class="rl"><a href="/p/1-2-1.html">第1集</a></div>';
  final c = XbpqPlay.episodes(bodyC, 'https://a.com/d/1.html', ruleC);
  eq('routeArray routes', c.routes.length, 2);
  eq('routeArray eps', '${c.routes[0].length}/${c.routes[1].length}', '2/1');

  // ══════════════════════════════════════════════════════════
  // 分集：分隔符自适应（模板给了 <li，站点实际是 <a 连排）
  // ══════════════════════════════════════════════════════════
  final ruleD = makeRule({
    '播放数组': 'id="pl">&&</div>',
    '播放列表': '<li',
  });
  const bodyD = '<div id="pl">'
      '<a href="/p/1.html">A</a><a href="/p/2.html">B</a></div>';
  final d = XbpqPlay.episodes(bodyD, 'https://a.com/d/1.html', ruleD);
  eq('separator adapt count', d.routes.first.length, 2);
  eq('separator adapt title', d.routes.first.first.title, 'A');

  // ══════════════════════════════════════════════════════════
  // 分集：清洗规则
  // ══════════════════════════════════════════════════════════
  final ruleE = makeRule({'播放数组': 'id="raw">&&</div>'});
  const bodyE = '<div id="raw">'
      '第1集\$/p/1.html\r\n'
      '花絮\r\n'
      '第2集\$123\r\n'
      r'$https://cdn.x/3.m3u8'
      '</div>';
  final e = XbpqPlay.episodes(bodyE, 'https://a.com/d/1.html', ruleE);
  eq('crlf to #', e.routes.first.length, 2);
  // 纯文字「花絮」和「第2集$123」（地址不成链接）都被丢弃，
  // 剩下无标题的那条自动编号为「第3集」。
  eq('text only dropped', e.routes.first[1].title, '第3集');
  eq('bare id dropped + auto name', e.routes.first[1].url,
      'https://cdn.x/3.m3u8');

  final ruleF = makeRule({'播放数组': 'id="raw">&&</div>'});
  const bodyF = '<div id="raw">标题\$\$abc#第1集\$/p/1.html</div>';
  final f = XbpqPlay.episodes(bodyF, 'https://a.com/d/1.html', ruleF);
  eq('dollar address skipped', f.routes.first.length, 1);
  eq('dollar skip kept good one', f.routes.first.first.title, '第1集');

  // ── 空规则 ──
  final ruleEmpty = makeRule({});
  ok('no 播放数组 → empty',
      XbpqPlay.episodes('<div></div>', 'https://a.com/', ruleEmpty).isEmpty);

  // ══════════════════════════════════════════════════════════
  // 备选线路
  // ══════════════════════════════════════════════════════════
  final groups = [
    [
      const XbpqEpisode(title: '第1集', url: 'https://a.com/p/1-1-1.html'),
      const XbpqEpisode(title: '第2集', url: 'https://a.com/p/1-1-2.html'),
    ],
    [
      const XbpqEpisode(title: '第1集', url: 'https://a.com/p/1-2-1.html'),
      const XbpqEpisode(title: '第2集', url: 'https://a.com/p/1-2-2.html'),
    ],
    [
      const XbpqEpisode(title: '第01集', url: 'https://a.com/p/1-3-1.html'),
    ],
  ];
  final alternates = XbpqPlay.alternateRoutes(
    groups,
    0,
    groups[0][0],
    'https://a.com/p/1-1-1.html',
    'https://a.com/p/1-1-1.html',
  );
  eq('alternates count', alternates.length, 1);
  eq('alternates skips main', alternates.first, 'https://a.com/p/1-2-1.html');
  eq('alternates needs 2 groups',
      XbpqPlay.alternateRoutes([groups[0]], 0, groups[0][0], 'x', 'y').length, 0);

  // ══════════════════════════════════════════════════════════
  // MacCMS 播放页兜底
  // ══════════════════════════════════════════════════════════
  eq('normalize unescape slash',
      XbpqMaccms.normalizePlaybackUrl(r'https:\/\/a.com\/x.m3u8'),
      'https://a.com/x.m3u8');
  eq('normalize trim punctuation',
      XbpqMaccms.normalizePlaybackUrl('https://a.com/x.m3u8，'), 'https://a.com/x.m3u8');
  eq('normalize p. unicode folder',
      XbpqMaccms.normalizePlaybackUrl(
          r'https://a.com/v/p.abc/\u7b2c01\u96c6/index.m3u8'),
      'https://a.com/v/p.abc/%E7%AC%AC01%E9%9B%86/index.m3u8');
  eq('normalize plain untouched',
      XbpqMaccms.normalizePlaybackUrl('https://a.com/v/1/2.m3u8'),
      'https://a.com/v/1/2.m3u8');

  eq('decodeUnicode', XbpqMaccms.decodeUnicode(r'\u7b2c01'), '第01');
  eq('unescapeJs percent', XbpqMaccms.unescapeJs('a%20b'), 'a b');
  eq('unescapeJs unicode', XbpqMaccms.unescapeJs('%u7b2c01'), '第01');

  // player_data（encrypt=0）
  const playerPlain = '<script>var player_aaaa={"url":"https:\\/\\/cdn.x\\/a.m3u8",'
      '"encrypt":"0"}</script>';
  eq('playerUrl plain', XbpqMaccms.playerUrl(playerPlain),
      'https://cdn.x/a.m3u8');
  eq('playerFields encrypt', XbpqMaccms.playerFields(playerPlain)['encrypt'], '0');

  // encrypt=1（JS escape）
  const playerJs = '<script>var player_aaaa={"url":"https%3A%2F%2Fcdn.x%2Fb.m3u8",'
      '"encrypt":"1"}</script>';
  eq('playerUrl encrypt=1', XbpqMaccms.playerUrl(playerJs),
      'https://cdn.x/b.m3u8');

  // encrypt=2（base64）
  final b64 = base64Encode(utf8.encode('https://cdn.x/c.m3u8'));
  final playerB64 =
      '<script>var player_aaaa={"url":"$b64","encrypt":"2"}</script>';
  eq('playerUrl encrypt=2', XbpqMaccms.playerUrl(playerB64),
      'https://cdn.x/c.m3u8');

  // iframe base64（mxone）
  final iframePayload =
      base64Encode(utf8.encode('https://cdn.x/d.m3u8,https://cdn.x/e.m3u8'));
  final iframeHtml =
      '<html><iframe src="/url?url=$iframePayload"></iframe></html>';
  eq('playerUrl iframe base64', XbpqMaccms.playerUrl(iframeHtml),
      'https://cdn.x/d.m3u8');

  // 正则兜底
  eq('playerUrl bare regex',
      XbpqMaccms.playerUrl('<div>https://cdn.x/f.m3u8</div>'),
      'https://cdn.x/f.m3u8');
  eq('playerUrl none', XbpqMaccms.playerUrl('<div>nothing</div>'), '');

  // ══════════════════════════════════════════════════════════
  // 跳转播放链接
  // ══════════════════════════════════════════════════════════
  const jumpBody = '<script>var x = {"url":"https://cdn.x/j.m3u8"};</script>';
  eq('jumpValue', XbpqPlay.jumpValue(jumpBody, '"url":"&&"'),
      'https://cdn.x/j.m3u8');
  eq('jumpValue truncates newline',
      XbpqPlay.jumpValue('"url":"https://cdn.x/j.m3u8"\nrest', '"url":"&&"'),
      'https://cdn.x/j.m3u8');
  eq('jumpCandidates dedupe',
      XbpqPlay.jumpCandidates(jumpBody, '"url":"&&"').length, 1);
  eq('jumpCandidates none', XbpqPlay.jumpCandidates('<p>x</p>', '"url":"&&"').length, 0);

  // ══════════════════════════════════════════════════════════
  // 详情端到端
  // ══════════════════════════════════════════════════════════
  const detailHtml = '<html><head>'
      '<meta property="og:image" content="/img/c.jpg"></head><body>'
      '<h1>测试剧名</h1>'
      '<div class="intro">这是简介</div>'
      '<div id="pl"><a href="/p/1.html">第1集</a><a href="/p/2.html">第2集</a></div>'
      '</body></html>';
  final detailRule = makeRule({
    '详情url': '/detail/{id}.html',
    '影片名称': '<h1>&&</h1>',
    '简介': 'class="intro">&&</div>',
    '播放数组': 'id="pl">&&</div>',
    '播放列表': '<a',
  });
  final detailSource = sourceWith({'https://a.com/detail/101.html': detailHtml});
  final play = XbpqPlay(source: detailSource);
  final detail = await play.detail(
      rule: detailRule, base: 'https://a.com', sourceId: '101');
  final info = (detail['list'] as List).first as Map<String, dynamic>;
  eq('detail title', info['vod_name'], '测试剧名');
  eq('detail intro', info['vod_content'], '这是简介');
  eq('detail cover og', info['vod_pic'], 'https://a.com/img/c.jpg');
  eq('detail play_from', info['vod_play_from'], '线路1');
  eq('detail play_url', info['vod_play_url'],
      '第1集\$https://a.com/p/1.html#第2集\$https://a.com/p/2.html');

  // 无分集 → 抛错
  String? detailError;
  final noEps = sourceWith({'https://a.com/detail/102.html': '<h1>x</h1>'});
  try {
    await XbpqPlay(source: noEps).detail(
        rule: detailRule, base: 'https://a.com', sourceId: '102');
  } on XbpqException catch (err) {
    detailError = err.message;
  }
  eq('detail no episodes', detailError, '规则未解析到分集');

  // ══════════════════════════════════════════════════════════
  // 取址
  // ══════════════════════════════════════════════════════════
  final playRule = makeRule({'跳转播放链接': '"url":"&&"'});

  // 1) 地址本身就是直链：不该发请求
  final noFetch = XbpqSource(fetcher: (raw, referer, agent) async {
    throw const XbpqException('不该发请求');
  });
  final direct = await XbpqPlay(source: noFetch).playUrl(
      rule: playRule, base: 'https://a.com', pageUrl: 'https://cdn.x/a.m3u8');
  eq('playUrl direct parse', direct['parse'], 0);
  eq('playUrl direct url', direct['url'], 'https://cdn.x/a.m3u8');

  // 2) 跳转播放链接直接命中
  final jumpSource = sourceWith({
    'https://a.com/p/1.html': '<div>"url":"https://cdn.x/b.m3u8"</div>',
  });
  final jumped = await XbpqPlay(source: jumpSource).playUrl(
      rule: playRule, base: 'https://a.com', pageUrl: 'https://a.com/p/1.html');
  eq('playUrl jump parse', jumped['parse'], 0);
  eq('playUrl jump url', jumped['url'], 'https://cdn.x/b.m3u8');
  eq('playUrl jump referer', (jumped['header'] as Map)['Referer'],
      'https://a.com/p/1.html');

  // 3) 跳转到二级播放页，再取一次
  final hopSource = sourceWith({
    'https://a.com/p/2.html': '<div>"url":"https://a.com/play2"</div>',
    'https://a.com/play2': '<div>"url":"https://cdn.x/c.m3u8"</div>',
  });
  final hopped = await XbpqPlay(source: hopSource).playUrl(
      rule: playRule, base: 'https://a.com', pageUrl: 'https://a.com/p/2.html');
  eq('playUrl second hop url', hopped['url'], 'https://cdn.x/c.m3u8');
  eq('playUrl second hop referer', (hopped['header'] as Map)['Referer'],
      'https://a.com/play2');

  // 4) 没有跳转字段时走 player_data
  final noJumpRule = makeRule({});
  final playerSource = sourceWith({
    'https://a.com/p/3.html':
        '<script>var player_aaaa={"url":"https://cdn.x/d.m3u8","encrypt":"0"}</script>',
  });
  final fromPlayer = await XbpqPlay(source: playerSource).playUrl(
      rule: noJumpRule, base: 'https://a.com', pageUrl: 'https://a.com/p/3.html');
  eq('playUrl player_data', fromPlayer['url'], 'https://cdn.x/d.m3u8');
  eq('playUrl player_data parse', fromPlayer['parse'], 0);

  // 5) 什么都拿不到 → parse:1 交给嗅探管线
  final deadSource = sourceWith({
    'https://a.com/p/4.html': '<html><body>无直链</body></html>',
  });
  final fallback = await XbpqPlay(source: deadSource).playUrl(
      rule: noJumpRule, base: 'https://a.com', pageUrl: 'https://a.com/p/4.html');
  eq('playUrl fallback parse', fallback['parse'], 1);
  eq('playUrl fallback url', fallback['url'], 'https://a.com/p/4.html');

  print('\n==== $_pass passed, $_fail failed ====');
  if (_fail > 0) throw StateError('P4 verification failed');
}
