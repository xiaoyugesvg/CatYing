import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/services/ad_block_service.dart';

/// 网页去广告的**纯逻辑**回归：域名归一化 / 匹配 / 规则导入 / 注入脚本。
///
/// 不碰 WebView、不依赖插件（落盘/存档在单测里抛的异常都被服务内部吞掉了）。
void main() {
  // 初始化 binding：让 path_provider / SharedPreferences 正常抛 MissingPlugin
  // 并被服务内部吞掉（不初始化的话日志里全是 "Binding has not yet been initialized"）
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = AdBlockService.instance;

  setUp(() async {
    await svc.clearRules();
    await svc.setEnabled(true);
    await svc.setBuiltinEnabled(true);
    // 单条开关也要复位（否则用例之间互相污染）
    for (final s in AdBlockService.kBuiltinSelectors) {
      await svc.setBuiltinItemEnabled(s, true);
    }
  });

  group('域名归一化与匹配', () {
    test('normalizeHost：去 || / 协议 / 路径 / 通配', () {
      expect(AdBlockService.normalizeHost('||example.com^'), 'example.com');
      expect(AdBlockService.normalizeHost('https://a.b.com/x?y=1'), 'a.b.com');
      expect(AdBlockService.normalizeHost('  Example.COM  '), 'example.com');
      expect(AdBlockService.normalizeHost('*.ad.com'), '');
    });

    test('hostMatches：同域 / 子域命中，前缀伪造不命中', () {
      expect(AdBlockService.hostMatches('example.com', 'example.com'), isTrue);
      expect(AdBlockService.hostMatches('www.example.com', 'example.com'), isTrue);
      expect(AdBlockService.hostMatches('evil-example.com', 'example.com'), isFalse,
          reason: '域名边界匹配 —— 防止前缀伪造');
      expect(AdBlockService.hostMatches('example.com', ''), isTrue,
          reason: '空 scope = 全局规则');
      expect(AdBlockService.hostMatches('', 'example.com'), isFalse);
    });
  });

  group('规则导入（uBlock / AdGuard 的「元素隐藏」写法）', () {
    test('##选择器 / 域名##选择器 / 裸选择器 都认', () async {
      final (ok, _) = await svc.importText(
          '##.ad-box\nexample.com##.ad-banner\n.adsbygoogle');
      expect(ok, 3);
      expect(svc.rules.map((r) => r.host).toSet(), {'', 'example.com'});
      expect(svc.rules.any((r) => r.selector == '.adsbygoogle'), isTrue);
    });

    test('网络过滤语法与注释要跳过（我们注入不了请求层）', () async {
      final (ok, skip) = await svc.importText(
          '||ads.com^\n/ads/*\n! 注释\n# 也不是选择器');
      expect(ok, 0);
      expect(skip, 4);
    });

    test('重复导入不会产生重复规则', () async {
      await svc.importText('##.dup');
      final (ok, skip) = await svc.importText('##.dup');
      expect(ok, 0);
      expect(skip, 1);
      expect(svc.rules.length, 1);
    });

    test('asText 能原样再导入（编辑规则靠它）', () async {
      await svc.importText('example.com##.ad-box');
      final r = svc.rules.first;
      expect(r.asText, 'example.com##.ad-box');
      await svc.importText(r.asText);
      expect(svc.rules.length, 1, reason: '自己再导入一次不该多出重复项');
    });
  });

  group('按域名取选择器', () {
    test('内置通用 + 命中本域名的 + 全局的，都在', () async {
      await svc.importText('example.com##.site-ad\n##.global-ad');
      final mine = svc.selectorsFor('https://www.example.com/a/b');
      expect(mine, contains('.site-ad'));
      expect(mine, contains('.global-ad'));
      expect(mine, contains('.adsbygoogle'), reason: '内置通用选择器默认生效');

      final other = svc.selectorsFor('https://other.com/');
      expect(other, isNot(contains('.site-ad')), reason: '站点专属规则不能漏到别的站');
      expect(other, contains('.global-ad'));
    });

    test('关掉内置后只剩自己的规则', () async {
      await svc.setBuiltinEnabled(false);
      expect(svc.selectorsFor('https://other.com/'), isEmpty);
    });

    test('单条内置选择器可以单独关掉（设置页"点卡片开关"）', () async {
      await svc.setBuiltinItemEnabled('.adsbygoogle', false);
      expect(svc.builtinItemEnabled('.adsbygoogle'), isFalse);
      expect(svc.selectorsFor('https://x.com/'), isNot(contains('.adsbygoogle')));
      expect(svc.selectorsFor('https://x.com/'), contains('ins.adsbygoogle'),
          reason: '只关这一条，别的内置不受影响');

      await svc.setBuiltinItemEnabled('.adsbygoogle', true);
      expect(svc.selectorsFor('https://x.com/'), contains('.adsbygoogle'));
    });

    test('总开关关掉时页面侧不再注入', () async {
      await svc.setEnabled(false);
      // selectorsFor 仍会给出规则（设置页要展示），但 injectInto 有 enabled 兜底；
      // 这里断言开关本身
      expect(svc.enabled, isFalse);
    });
  });

  group('注入脚本', () {
    test('生成 display:none 的 CSS，且选择器按 JSON 安全嵌入', () {
      final js = AdBlockService.buildInjectJs(['.ad-box', 'div[class*="广告"]']);
      expect(js, contains('display:none !important'));
      expect(js, contains('var SEL = '), reason: '选择器以 JSON 数组形式嵌入');
      expect(js, contains('.ad-box'));
      expect(js, contains('MutationObserver'), reason: '动态插入的广告也要盖住');
      expect(js, contains('__tbAdBlockStyle'), reason: '只留一个 style，重复注入是替换内容');
    });

    test('整份 CSS 过滤器按 JSON 字符串嵌入（里面有 } 和换行，不能裸拼）', () {
      const css = '.a { display: none !important; }\n.b, .c { height: 0; }';
      final js = AdBlockService.buildInjectJs(['.ad-box'], extraCss: css);
      expect(js, contains('var EXTRA = "'), reason: 'CSS 要作为 JSON 字符串字面量');
      // 换行必须是转义形式（\n 两个字符），不能是真实换行 —— 否则 JS 语法就崩了
      expect(js, contains(r'\n.b, .c'),
          reason: '换行要被转义成 \\n（见 assets 里的 node 语法校验）');
      expect(js.contains('.a { display: none !important; }\n.b, .c'), isFalse,
          reason: '原始多行形态不该出现在生成脚本里');
      expect(js, contains('+ EXTRA'), reason: '拼接逻辑要用上 EXTRA');
    });

    test('没传 extraCss 时行为不变（只有选择器那一段）', () {
      final js = AdBlockService.buildInjectJs(['.ad-box']);
      expect(js, contains('var EXTRA = ""'));
      expect(js, contains('.ad-box'));
    });

    test('选元素脚本要回传选择器与命中数量', () {
      const js = AdBlockService.kPickStartJs;
      expect(js, contains("type:'pick'"));
      expect(js, contains('querySelectorAll'), reason: '要告诉用户这条规则命中几处');
      expect(js, contains('nth-of-type'), reason: '没有 class 时要能退化到结构化路径');
    });
  });
}
