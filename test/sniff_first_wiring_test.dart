// 守卫测试：四个播放入口必须都走「嗅探优先」，且预算够跟完 4 层 iframe。
//
// ── 为什么需要这条测试 ─────────────────────────────────────────────
// 2026-10-31 用户原话：「影视模块现在的解析线路和嗅探完全不是现在测试的
// 这种，我不满意」。
//
// 根因不是嗅探能力不够，而是**两条路不一样**：
//   · 探针页「点击播放」 → 纯嗅探优先，20s 全给嗅探 ⇒ 4 层跟得完 ⇒ 能播；
//   · 影视模块 → `MediaResolver` 里 HTTP 先吃 10s，嗅探只吃剩下 12s
//     ⇒ 第 4 层刚开始就被总预算砍断 ⇒ 0 候选 ⇒「这条线路播不了」。
//
// 这属于**接线问题**，不是逻辑问题：能力都在，只是入口没接上。
// 单测抓不到（每段代码单独看都对），只能靠静态守卫盯着。
//
// 谁以后新增一个播放入口（比如投屏、TV 版、车机），忘了传 sniffFirst，
// 这里会红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 项目根目录（`flutter test` 的 cwd 就是根）
String _read(String relative) => File(relative).readAsStringSync();

/// 去掉 `//` 行注释和 `/* */` 块注释，避免「注释里写了 sniffFirst: true」
/// 就让测试误判为通过（之前 `sniffer_hook_test` 踩过这个坑）。
String _stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');
}

void main() {
  group('播放入口必须嗅探优先', () {
    // 每个入口：文件 + 为什么它必须传 true
    const entrypoints = <String, String>{
      'lib/pages/detail/controller.dart': '影视模块（_sniffPageForMedia）',
      'lib/hiker/pages/hiker_detail_page.dart': '海阔（_sniffThenPlay）',
      'lib/miniapp/services/ant_bridge.dart': '小程序 player.open',
      'lib/rss/pages/rss_article_page.dart': 'RSS 分集播放',
    };

    entrypoints.forEach((file, who) {
      test('$who 调 resolve 时传了 sniffFirst: true', () {
        final src = _stripComments(_read(file));
        expect(
          src.contains('sniffFirst: true'),
          isTrue,
          reason: '$file 没传 sniffFirst: true —— $who 会退回「HTTP 优先」，'
              '和探针页不是同一条路，症状就是「测试页能播、正片播不了」',
        );
      });

      test('$who 用到了 MediaResolver', () {
        final src = _stripComments(_read(file));
        expect(
          src.contains('MediaResolver'),
          isTrue,
          reason: '$file 没引用 MediaResolver —— 说明 $who 绕过了统一解析链路',
        );
      });
    });

    test('探针页「点击播放」先纯嗅探（不能被改回 HTTP 优先）', () {
      final src = _stripComments(_read('lib/pages/dev/sniffer_probe_page.dart'));
      final sniffIdx = src.indexOf('MediaSniffService.instance.sniff');
      final resolveIdx = src.indexOf('MediaResolver.instance.resolve');
      expect(sniffIdx, greaterThan(-1), reason: '探针页不再直接调嗅探了');
      expect(resolveIdx, greaterThan(-1), reason: '探针页没有 HTTP 兜底');
      expect(
        sniffIdx < resolveIdx,
        isTrue,
        reason: '探针页必须「先嗅探、后 HTTP」，顺序反了就和正片链路不一致',
      );
    });
  });

  group('嗅探预算够跟完 4 层', () {    test('_sniffReserve 覆盖 _maxHops × 每层最少时间', () {
      final resolver = _read('lib/services/media_resolver.dart');
      final sniffer = _read('lib/services/media_sniff_service.dart');

      final maxHops = int.parse(
        RegExp(r'static const int _maxHops = (\d+);').firstMatch(sniffer)!.group(1)!,
      );
      final minHopSec = int.parse(
        RegExp(r'static const Duration _minHop = Duration\(seconds: (\d+)\);')
            .firstMatch(sniffer)!
            .group(1)!,
      );
      final reserveSec = int.parse(
        RegExp(r'static const Duration _sniffReserve = Duration\(seconds: (\d+)\);')
            .firstMatch(resolver)!
            .group(1)!,
      );

      expect(
        reserveSec,
        greaterThanOrEqualTo(maxHops * minHopSec),
        reason: '嗅探预留 ${reserveSec}s < $maxHops 层 × ${minHopSec}s = '
            '${maxHops * minHopSec}s ⇒ 最后一层必被砍断（实测 jx.muiu.site 那条链'
            '要 4 层才出地址）',
      );
    });

    test('总预算容得下「嗅探优先」+ 一轮 HTTP 兜底', () {
      final resolver = _read('lib/services/media_resolver.dart');
      final total = int.parse(
        RegExp(r'static const Duration defaultBudget = Duration\(seconds: (\d+)\);')
            .firstMatch(resolver)!
            .group(1)!,
      );
      final reserve = int.parse(
        RegExp(r'static const Duration _sniffReserve = Duration\(seconds: (\d+)\);')
            .firstMatch(resolver)!
            .group(1)!,
      );
      expect(
        total,
        greaterThan(reserve),
        reason: '总预算 $total s 必须大于嗅探预留 $reserve s，'
            '否则嗅探优先跑完就没有 HTTP 兜底的余量了',
      );
    });
  });

  // ── 2026-10-31 用户：「这个就是正常嗅探视频不行吗？只是多了个解析线路的前缀」
  //
  // 对 —— 就是「前缀 + 正常嗅探」，代码里没有任何按层级写死的逻辑。
  // 但实测 `bd.jx.cn` 那条链**正好 4 层**，卡在原来的上限边界上：
  //   bd.jx.cn → jiexi.bot.cd/ → jiexi.bot.cd/jx/（Go WASM）→ 123.129.229.14:4433
  // 中间多一个中转页就整条废掉，所以下面三条必须钉住。
  group('长链路不能被上限砍断', () {
    test('平台页只试用户当前这一条线路（不替他连着试好几条）', () {
      final resolver = _read('lib/services/media_resolver.dart');
      final n = int.parse(
        RegExp(r'static const int _platformSniffLines = (\d+);')
            .firstMatch(resolver)!
            .group(1)!,
      );
      expect(
        n,
        1,
        reason: '用户 2026-10-31：「那么多线路你一个个弄吗，切换线路就是切换前缀，'
            '解析站不行那就是我自己切换线路」。自动试 $n 条 = 让他干等几十秒，'
            '还替他做了决定',
      );
    });

    test('层数上限留了余量（实测那条链正好 4 层）', () {
      final sniffer = _read('lib/services/media_sniff_service.dart');
      final maxHops = int.parse(
        RegExp(r'static const int _maxHops = (\d+);')
            .firstMatch(sniffer)!
            .group(1)!,
      );
      expect(
        maxHops,
        greaterThanOrEqualTo(5),
        reason: '上限 $maxHops 层：bd.jx.cn 那条链就是 4 层，正好等于上限'
            '等于「中间多一个中转页就废」，必须留余量',
      );
    });

    test('最后一层时间片能放宽（WASM / 混淆播放器 10s 差一口气）', () {
      final code = _stripComments(_read('lib/services/media_sniff_service.dart'));
      expect(
        code.contains('var hopDeadline'),
        isTrue,
        reason: '时间片写成 final 就没法在「发现没有下一层」时放宽，'
            '最后一层永远只有 _hopCap',
      );
      final cap = int.parse(
        RegExp(r'static const Duration _lastHopCap = Duration\(seconds: (\d+)\);')
            .firstMatch(code)!
            .group(1)!,
      );
      expect(
        cap,
        greaterThanOrEqualTo(12),
        reason: '最后一层上限 ${cap}s 比中转层还短，等于没放宽',
      );
    });

    test('解析站自己报错要提前收工（别把预算白等满）', () {      final code = _stripComments(_read('lib/services/media_sniff_service.dart'));
      expect(code.contains('Future<bool> _siteError('), isTrue);
      expect(
        code.contains('_siteError(c)'),
        isTrue,
        reason: '定义了但没调用，等于没写',
      );
      // 只认「明确是错误页」的措辞，不认裸 404（正常页面里也常有 404 字样）
      expect(
        code.contains('/请求上游'),
        isTrue,
        reason: '实测 api.php 上游挂掉时页面显示「请求上游解析接口失败」',
      );
      expect(
        RegExp(r'/\s*404\s*/\.test').hasMatch(code),
        isFalse,
        reason: '不许只凭「404」字样判定错误页 —— 会把正常页面误杀',
      );
    });

    test('主文档加载失败必须记下来（不能静默 0 候选）', () {
      final code = _stripComments(_read('lib/services/media_sniff_service.dart'));
      // 2026-10-31 实测：bd.jx.cn 那条链的第 4 层压根没加载起来，
      // 而日志里只写「被跳转到 jiexi.bot.cd/jx/」+「0 候选」，
      // 看的人（包括我）都以为是重定向，排查方向整个带偏。
      expect(
        code.contains('onWebResourceError'),
        isTrue,
        reason: '没有这个回调 ⇒ 某一层 TLS 失败 / 被拦时完全静默，'
            '和「页面没地址」长得一模一样',
      );
      expect(code.contains('_lastMainFrameError'), isTrue);
      expect(
        code.contains('这一层没加载起来'),
        isTrue,
        reason: '落地地址等于**上一层**地址时要说「没加载起来」，'
            '不能说「被跳转」—— 两件事的排查方向完全不同',
      );
      expect(
        code.contains('prevUrl'),
        isTrue,
        reason: '要判「还停在上一层」就必须知道上一层是哪个地址',
      );
    });
  });

  // ── 2026-10-31 用户：「播放器下面没有切换线路的按钮吗？不管是默认详情
  //    里面的还是纯竖屏的播放器呢」
  //
  // 「线路」在本 App 里 = **解析线路**（`jx.xx/?url=…` 那个前缀），不是 CMS
  // 播放源。因为 `_platformSniffLines = 1`（只试当前这一条），失败后必须让
  // 用户自己换 —— 没有这个入口，`_platformSniffLines = 1` 就等于「一旦选的
  // 那条挂了，这集永远播不了」。
  group('切换解析线路的入口必须存在', () {
    test('共享弹层导出 showParseLineSheet，且能区分「取消」和「自动」', () {
      final src = _stripComments(_read('lib/widgets/parse_line_sheet.dart'));
      expect(
        src.contains('Future<String?> showParseLineSheet('),
        isTrue,
        reason: '返回 String? 是刻意的：null = 取消，\'\' = 自动（不套线路），'
            '其它 = 线路 id。用 String 就分不出「取消」和「选了自动」',
      );
      expect(
        src.contains("Navigator.of(context).pop('')"),
        isTrue,
        reason: '「自动」这一项必须回空串，否则选自动会被当成取消',
      );
      expect(
        src.contains('ensureSyncedFromConfig'),
        isTrue,
        reason: '没打开过设置页时订阅线路是空的，弹层必须先自己懒同步一次',
      );
    });

    test('详情页把 onSwitchParseLine 传给播放器', () {
      final src = _stripComments(_read('lib/pages/detail/view.dart'));
      expect(
        src.contains('onSwitchParseLine:'),
        isTrue,
        reason: '不传回调，播放器底栏就不会出现「线路」按钮',
      );
      expect(
        src.contains('_openParseLineSheet'),
        isTrue,
        reason: '弹层 + 重新解析的实现在详情页（只有这层还留着原始播放页地址）',
      );
    });

    test('详情页「播放源」卡片里有「解析线路」段', () {
      final src = _stripComments(_read('lib/pages/detail/view.dart'));
      expect(
        src.contains("title: '解析线路'"),
        isTrue,
        reason: '用户 2026-10-31：要能在**详情页里**直接换，不用先点开播放器',
      );
      expect(
        src.contains('AnimatedBuilder('),
        isTrue,
        reason: '线路名来自 ParseLineStore（ChangeNotifier），不监听就换完不刷新',
      );
    });

    test('切换线路必须清解析缓存，否则换了跟没换一样', () {
      final src = _stripComments(_read('lib/pages/detail/controller.dart'));
      final i = src.indexOf('switchParseLine');
      expect(i, greaterThan(-1), reason: 'controller 没有 switchParseLine');
      final body = src.substring(i, i + 1400);
      expect(
        body.contains('setSelected'),
        isTrue,
        reason: '不落盘 ⇒ 下一集又用回旧线路',
      );
      expect(
        body.contains('clearCache'),
        isTrue,
        reason: 'MediaResolver 缓存 key 是**页面地址**，换线路后页面地址没变，'
            '不清缓存会直接把上一条线路的结果还回来',
      );
      expect(
        body.contains('retryCurrentEpisode'),
        isTrue,
        reason: '不清空重解，用户点了「换一条」画面不会有任何变化',
      );
    });

    test('竖屏播放器底栏有「线路」按钮，且父级不传就不显示', () {
      final src = _stripComments(_read('lib/widgets/video_player.dart'));
      expect(
        src.contains('final VoidCallback? onSwitchParseLine;'),
        isTrue,
        reason: '播放器只拿到最终直链，不知道原始网页地址 —— '
            '所以只能发信号，重新解析交给父级',
      );
      expect(
        src.contains('widget.onSwitchParseLine != null'),
        isTrue,
        reason: '直链 / 本地文件播放没有解析环节，硬显示一个按钮点了没用',
      );
      expect(
        src.contains('Icons.alt_route_rounded'),
        isTrue,
        reason: '底栏按钮图标',
      );
    });

    // 海阔 / RSS / 小程序共用 `MiniAppPlayerPage`。这三端原来把「原始网页
    // 地址」丢在了页面外面，进播放页后就没有"线路"这个概念了 —— 于是
    // 「探针页能换线路、海阔里不能」。
    const sharedPlayer = 'lib/miniapp/pages/mini_app_player_page.dart';

    test('共用播放页收得下原始网页地址，并自己重新嗅探', () {
      final src = _stripComments(_read(sharedPlayer));
      expect(
        src.contains('final String? sourcePageUrl;'),
        isTrue,
        reason: '没有原始网页地址就没法「换个前缀重新嗅探」',
      );
      expect(
        src.contains('Future<void> _switchParseLine('),
        isTrue,
        reason: '换线路的实现必须在播放页里，否则三端各写一遍',
      );
      final i = src.indexOf('Future<void> _switchParseLine(');
      final body = src.substring(i, i + 1800);
      expect(
        body.contains('clearCache'),
        isTrue,
        reason: '解析缓存 key 是页面地址，换线路后地址没变 ⇒ 不清就返回旧结果',
      );
      expect(
        body.contains('sniffFirst: true'),
        isTrue,
        reason: '重新嗅探必须还是「嗅探优先」，否则又和探针页不是同一条路',
      );
      expect(
        body.contains('_url = direct'),
        isTrue,
        reason: '拿到新地址要热替换，否则画面还是旧线路那条',
      );
    });

    test('海阔 / RSS / 小程序把原始网页地址带进播放页', () {
      const cases = <String, String>{
        'lib/hiker/pages/hiker_detail_page.dart': 'sourcePageUrl: pageUrl',
        'lib/rss/pages/rss_article_page.dart': 'srcPage: pageUrl',
        'lib/miniapp/services/ant_bridge.dart': 'sourcePageUrl: resolution.url',
      };
      cases.forEach((file, needle) {
        final src = _stripComments(_read(file));
        expect(
          src.contains(needle),
          isTrue,
          reason: '$file 没把原始网页地址传进播放页 ⇒ 播放器底栏不会出现'
              '「线路」按钮，用户只能退出去重进',
        );
      });
    });
  });
}
