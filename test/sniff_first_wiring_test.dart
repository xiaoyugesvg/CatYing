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

  group('嗅探预算够跟完 4 层', () {
    test('_sniffReserve 覆盖 _maxHops × 每层最少时间', () {
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
}
