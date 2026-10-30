import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/hiker/pages/hiker_detail_page.dart';

/// 海阔详情页的两类"噪音"（用户 2026-10-30 的截图）：
///   ① 解析结果里混进源站 5xx 错误页的正文；
///   ② 「操作与提示」展开后是 46 张一模一样的「第N集 / 本集暂无720p」。
void main() {
  group('hikerIsServerErrorText —— 认出错误页正文', () {
    test('用户截图里那条原样命中', () {
      expect(
        hikerIsServerErrorText(
            'Web server is returning an unknown error Error code 520'),
        isTrue,
      );
    });

    test('常见网关措辞命中', () {
      for (final t in [
        '502 Bad Gateway',
        '503 Service Temporarily Unavailable',
        '504 Gateway Time-out',
        'Internal Server Error',
        'Enable JavaScript and cookies to continue',
        'Just a moment...',
        'Attention Required! | Cloudflare',
      ]) {
        expect(hikerIsServerErrorText(t), isTrue, reason: t);
      }
    });

    test('正常分节标题**不能**被误杀', () {
      for (final t in [
        '第520集', // 带中文 ⇒ 一律放过
        '第 502 话',
        '—— 选集（3 集）——',
        '连播已就绪',
        '播放线路：高清',
        '',
        '   ',
      ]) {
        expect(hikerIsServerErrorText(t), isFalse, reason: t);
      }
    });

    test('英文正常标题不被误杀', () {
      // 没有错误码也没有网关措辞 ⇒ 不是错误页
      expect(hikerIsServerErrorText('Season 2 Episode 5'), isFalse);
      expect(hikerIsServerErrorText('Full HD'), isFalse);
    });
  });

  group('hikerCollapsedHintTitle —— 46 张卡合并成一张', () {
    test('首尾不同 → 区间 + 条数', () {
      expect(
        hikerCollapsedHintTitle('第1集', '第46集', 46),
        '第1集 – 第46集（共46项）',
      );
    });

    test('首尾相同 → 只写一次', () {
      expect(hikerCollapsedHintTitle('第3集', '第3集', 1), '第3集（共1项）');
    });

    test('标题全空 → 只给条数', () {
      expect(hikerCollapsedHintTitle('', '', 2), '共 2 项');
      expect(hikerCollapsedHintTitle('  ', '  ', 5), '共 5 项');
    });

    test('只有尾部有标题 → 用它', () {
      expect(hikerCollapsedHintTitle('', '第5集', 2), '第5集（共2项）');
    });
  });

  group('源码级不变量', () {
    final src = File('lib/hiker/pages/hiker_detail_page.dart').readAsStringSync();

    test('简介固定显示，空时写「无」', () {
      // 原来整块包在 `if (it.desc.isNotEmpty)` 里 ⇒ 没简介时这一节凭空消失
      expect(src, isNot(contains('if (it.desc.isNotEmpty) ...[')));
      expect(src, contains("if (it.desc.isEmpty)"));
      expect(src, contains("'无'"));
    });

    test('噪音标题被过滤，提示卡被合并', () {
      expect(src, contains('_isNoiseLabel(c)'));
      expect(src, contains('_collapseHints(infos)'));
    });

    test('取不出图片地址的候选退回普通卡片（不留灰框）', () {
      expect(src, contains('imgWithSrc'));
      expect(src, contains('imgNoSrc'));
    });
  });
}
