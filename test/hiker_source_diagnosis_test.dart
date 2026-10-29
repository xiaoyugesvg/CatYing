import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/hiker/models/hiker_source.dart';

/// 「源诊断标签」的回归测试。
///
/// 用户 2026-10-17：把剩余缺口做成源详情里的标签（缺 Apollo / 缺 lazy /
/// 需填配置 …），而不是点进去才看到一句报错。
///
/// 纯静态判断：不联网、不读文件（文件清单由调用方传入）。
void main() {
  HikerSource make({
    String title = '测试源',
    String findRule = 'js:setResult([])',
    String detail = '',
    String searchFind = '',
    String url = 'https://a.com',
    List<Map<String, dynamic>>? pages,
    String? rawPages,
  }) {
    return HikerSource({
      'title': title,
      'author': 'tester',
      'url': url,
      'find_rule': findRule,
      'detail_find_rule': detail,
      'searchFind': searchFind,
      if (pages != null) 'pages': rawPages ?? jsonEncode(pages),
    });
  }

  List<String> labels(HikerSource s,
          {Set<String> assets = const {},
          Set<String> files = const {},
          Map<String, dynamic>? config}) =>
      s
          .diagnose(
            bundledAssets: assets,
            importedFiles: files,
            config: config,
          )
          .map((e) => e.label)
          .toList();

  group('缺 Apollo', () {
    test('hiker://page/Apollo 引用且源里没带 ⇒ 标出来', () {
      final s = make(
          findRule:
              "js:var html = fetch('hiker://page/Apollo#autoCache#');setResult([]);");
      expect(labels(s), contains('缺 Apollo'));
    });

    test(r"裸 $.require('Apollo') 也算（不只是 hiker:// 写法）", () {
      final s = make(findRule: 'js:\$.require("Apollo");setResult([]);');
      expect(labels(s), contains('缺 Apollo'));
    });

    test('源自己的 pages 里带了 Apollo ⇒ 不标', () {
      final s = make(
        findRule: 'js:\$.require("Apollo").go();setResult([]);',
        pages: [
          {'name': 'Apollo', 'path': 'apollo', 'rule': 'js:function go(){ }'},
        ],
      );
      expect(labels(s), isNot(contains('缺 Apollo')));
    });

    test('文件区里已有 rules/Apollo/... ⇒ 不标', () {
      final s = make(
          findRule:
              "js:var c=fetch('hiker://files/rules/Apollo/main.js');setResult([]);");
      expect(
        labels(s, files: {'rules/Apollo/main.js'}),
        isNot(contains('缺 Apollo')),
      );
      expect(
        labels(s, files: {'rules/Apollo/engine.js'}),
        isNot(contains('缺 Apollo')),
        reason: '只要 Apollo 目录下有文件就认为规则包已导入',
      );
    });
  });

  group('缺 lazy', () {
    test('引用内置页 lazy 但 pages 里没有 ⇒ 标出来', () {
      final s = make(
          findRule:
              "js:var p=fetch('hiker://page/lazy#autoCache#');setResult([]);");
      expect(labels(s), contains('缺 lazy'));
      expect(labels(s), isNot(contains('缺内置页')),
          reason: 'lazy 要单独成标签，不能混进"缺内置页"');
    });

    test('pages 里自带 lazy 模块 ⇒ 不标（漫小肆就是这种）', () {
      final s = make(
        findRule:
            "js:var p=fetch('hiker://page/lazy#autoCache#');setResult([]);",
        pages: [
          {'name': '解析', 'path': 'lazy', 'rule': "var lazy = \$('').lazyRule(() => {})"},
          {'name': '二級', 'path': 'er', 'rule': 'setResult([])'},
        ],
      );
      expect(labels(s), isNot(contains('缺 lazy')));
    });

    test(r"$.require('lazy') 没模块也算", () {
      final s = make(findRule: 'js:\$.require("lazy");setResult([]);');
      expect(labels(s), contains('缺 lazy'));
    });
  });

  group('缺内置页 / 缺文件 / 随包资源', () {
    test('引用了随包没有的 page 模块 ⇒ 缺内置页', () {
      final s = make(
          findRule:
              "js:var h=fetch('hiker://page/someThing');setResult([]);");
      expect(labels(s), contains('缺内置页'));
    });

    test('引用了随包资源（assets/home.js）⇒ 不标', () {
      final s = make(
          findRule:
              "js:eval(fetch('hiker://assets/home.js'));setResult([]);");
      expect(
        labels(s, assets: {'home.js'}),
        isNot(contains('缺内置页')),
      );
      expect(labels(s), contains('缺内置页'),
          reason: '清单没加载到时应保守地标出来');
    });

    test('hiker://files/libs/*.js 文件区里没有 ⇒ 缺文件', () {
      final s = make(
          findRule:
              "js:rc('hiker://files/libs/util.js');setResult([]);");
      expect(labels(s), contains('缺文件'));
      expect(labels(s, files: {'libs/util.js'}), isNot(contains('缺文件')));
    });

    test('缓存 / 运行时自建目录不算缺文件（否则会大面积误报）', () {
      final s = make(
        findRule: "js:var a=fetch('hiker://files/cache/douban.js');"
            "var b=fetch('hiker://files/data/api/start.js');"
            "setResult([]);",
      );
      expect(labels(s), isNot(contains('缺文件')));
    });

    test('动态拼接出来的路径不误报', () {
      final s = make(
          findRule:
              "js:var p='hiker://files/' + config.dir + '/x.js';setResult([]);");
      expect(labels(s), isNot(contains('缺文件')));
    });
  });

  group('需填配置', () {
    final s = make(
      findRule: 'js:var h=getHome(config.host);setResult([]);',
      url: '',
    );

    test('规则读 config.host 且没配置 ⇒ 需填配置', () {
      expect(labels(s), contains('需填配置'));
    });

    test('已经填过配置 ⇒ 不标', () {
      expect(
        labels(s, config: {'host': 'https://b.com'}),
        isNot(contains('需填配置')),
      );
    });

    test('说明里要指出具体键名', () {
      final d = s.diagnose().firstWhere((e) => e.label == '需填配置');
      expect(d.detail, contains('config.host'));
      expect(d.blocking, isFalse, reason: '填上就能用，不算硬阻塞');
    });

    test('中括号写法 config["key"] 也算配置键', () {
      final s = make(
        findRule: 'js:var h=getHome(config["host"]);setResult([]);',
      );
      expect(s.configKeys, contains('host'));
      expect(labels(s), contains('需填配置'));
    });
  });

  group('默认配置（填入默认配置）', () {
    test('优先抄规则里的兜底字面量', () {
      final s = make(
        findRule:
            "js:var h=getHome(config.host || 'https://fallback.com');"
            'setResult([]);',
      );
      expect(s.defaultConfig['host'], 'https://fallback.com');
    });

    test('没有兜底值时按源域名补 host 类键', () {
      final s = make(
        findRule:
            'js:var a=getHome(config.host);var b=api(config.apiBase);setResult([]);',
        url: 'https://a.com/book/1',
      );
      expect(s.defaultConfig['host'], 'https://a.com');
      expect(s.defaultConfig['apiBase'], 'https://a.com');
    });

    test('账号/口令类给空串，不编造假值', () {
      final s = make(
        findRule:
            'js:var t=config.token;var u=config.username;var k=config.apiKey;setResult([]);',
        url: 'https://a.com',
      );
      expect(s.defaultConfig['token'], '');
      expect(s.defaultConfig['username'], '');
      expect(s.defaultConfig['apiKey'], '',
          reason: 'apiKey 虽是 api 前缀，但属于密钥，不能填域名');
    });

    test('中括号兜底写法也能认', () {
      final s = make(
        findRule:
            'js:var h=getHome(config["host"] || "https://br.com");setResult([]);',
      );
      expect(s.defaultConfig['host'], 'https://br.com');
    });
  });

  group('诊断文案都带「怎么补」', () {
    test('六类诊断的说明里都有补法', () {
      final s = make(
        findRule:
            "js:var a=fetch('hiker://page/Apollo');"
            "var b=fetch('hiker://page/lazy');"
            "var c=fetch('hiker://page/someThing');"
            "var d=rc('hiker://files/libs/u.js');"
            "var e=getHome(config.host);setResult([]);",
        url: '',
      );
      final issues = s.diagnose();
      for (final d in issues) {
        expect(d.detail, contains('怎么补'), reason: '${d.label} 缺少补法说明');
      }
      // 无首页规则单独构造（否则上面的 find_rule 非空）
      final noHome = make(findRule: '');
      final d0 = noHome.diagnose().first;
      expect(d0.label, '无首页规则');
      expect(d0.detail, contains('怎么补'));
    });
  });

  group('整体', () {
    test('阻塞项排在前面，标签稳定', () {
      final s = make(
        findRule:
            "js:var a=fetch('hiker://page/Apollo');var b=getHome(config.host);setResult([]);",
        url: '',
      );
      final l = labels(s);
      expect(l.first, '缺 Apollo');
      expect(l, contains('需填配置'));
      expect(l.indexOf('缺 Apollo'), lessThan(l.indexOf('需填配置')));
    });

    test('没有 find_rule ⇒ 无首页规则', () {
      final s = make(findRule: '');
      expect(labels(s).first, '无首页规则');
    });

    test('正常源不应被乱标（漫小肆结构 + 已配好）', () {
      final s = make(
        findRule: 'js:var h=getResCode();setResult([]);',
        pages: [
          {'name': '二級', 'path': 'er', 'rule': 'setResult([])'},
          {'name': '解析', 'path': 'lazy', 'rule': "var lazy = \$('').lazyRule(() => {})"},
        ],
      );
      expect(labels(s), isEmpty);
    });
  });
}
