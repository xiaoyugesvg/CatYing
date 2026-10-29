import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/services/source_import_parser.dart';

/// 音源导入解析器的真实验证。
///
/// 这个功能是「用户自己导来源」的入口 —— 解析错一条，用户就多一个
/// 用不了的源，而且**报错信息还看不出哪里错**。所以 5 种格式都要测。
void main() {
  group('格式 1：JSON', () {
    test('数组形式', () {
      final list = SourceImportParser.parse('''
[
  {"name": "源A", "template": "https://a.com/url?name={name}", "quality": "320k"},
  {"name": "源B", "template": "https://b.com/url?id={id}", "urlPath": "data.url"}
]
''');
      expect(list.length, 2);
      expect(list[0].name, '源A');
      expect(list[0].kind, 'keyword');
      expect(list[1].urlPath, 'data.url');
    });

    test('{"sources":[...]} 包装形式', () {
      final list = SourceImportParser.parse('''
{"sources": [{"name": "包装源", "template": "https://x.com/{id}"}]}
''');
      expect(list.length, 1);
      expect(list[0].name, '包装源');
    });

    test('单个对象', () {
      final list = SourceImportParser.parse(
          '{"name": "单源", "template": "https://s.com/{id}"}');
      expect(list.length, 1);
      expect(list[0].name, '单源');
    });

    test('字段同义兼容：title/url/apiUrl', () {
      final list = SourceImportParser.parse('{"title": "别名源", "apiUrl": "https://z.com/{id}"}');
      expect(list.length, 1);
      expect(list[0].name, '别名源');
      expect(list[0].template, 'https://z.com/{id}');
    });

    test('headers 与 quality 被带上', () {
      final list = SourceImportParser.parse('''
{"name":"带头源","template":"https://h.com/{id}","quality":"flac",
 "headers":{"User-Agent":"test/1.0","Referer":"https://h.com"}}
''');
      expect(list[0].quality, 'flac');
      expect(list[0].headers['User-Agent'], 'test/1.0');
      expect(list[0].headers['Referer'], 'https://h.com');
    });

    test('既无 template 也无 script 的条目被丢弃', () {
      final list = SourceImportParser.parse('[{"name":"空源"},{"name":"好源","template":"https://g.com/{id}"}]');
      expect(list.length, 1);
      expect(list[0].name, '好源');
    });
  });

  group('格式 2：完整 LX 脚本（整份保留，不抠配置）', () {
    test('module.exports 的脚本按 script 保存', () {
      const script = '''
const { EVENT_NAMES, request, on, send } = globalThis.lx;
function translate(song) { return song.name + ' ' + song.singer; }
module.exports = { name: '测试音源', version: '1.0' };
''';
      final list = SourceImportParser.parse(script);
      expect(list.length, 1);
      expect(list[0].kind, 'script', reason: '完整脚本必须走 script 分支');
      expect(list[0].script, isNotNull);
      expect(list[0].script, contains('translate'),
          reason: '整份脚本要保留，而不是只抠出 name/version');
      expect(list[0].name, '测试音源');
    });

    test('SERVER_SCRIPT_CONFIG 的脚本也被识别', () {
      const script = '''
const SERVER_SCRIPT_CONFIG = { name: '配置源' };
function handle(request) { return request.url; }
''';
      final list = SourceImportParser.parse(script);
      expect(list[0].kind, 'script');
      expect(list[0].name, '配置源');
    });
  });

  group('格式 3：JS 里嵌的 JSON', () {
    test('const x = {...} 能被抠出来', () {
      const src = '''
// 这是源配置
const config = { "name": "嵌入源", "template": "https://e.com/{id}", "quality": "320k" };
console.log(config);
''';
      final list = SourceImportParser.parse(src);
      expect(list.length, 1);
      expect(list[0].name, '嵌入源');
      expect(list[0].kind, 'keyword');
    });

    test('const x = [{...},{...}] 数组配置能整段抠出（不截断）', () {
      const src = '''
const sources = [
  { "name": "A源", "template": "https://a.com/{id}" },
  { "name": "B源", "template": "https://b.com/{id}" }
];
''';
      final list = SourceImportParser.parse(src);
      expect(list.length, 2, reason: '数组里两个源都该被抠出来，不能只吃到第一个 }');
      expect(list.map((e) => e.name), containsAll(['A源', 'B源']));
    });
  });

  group('格式 4：注释头风格 @key value', () {
    test('@name / @template 解析成功', () {
      const src = '''
/**
 * @name 注释源
 * @template https://c.com/url?name={name}&artist={artist}
 * @quality flac
 * @urlpath data.playUrl
 */
export default {};
''';
      final list = SourceImportParser.parse(src);
      expect(list.length, 1);
      expect(list[0].name, '注释源');
      expect(list[0].template, contains('{name}'));
      expect(list[0].quality, 'flac');
      expect(list[0].urlPath, 'data.playUrl');
    });
  });

  group('格式 5：宽松脚本兜底', () {
    test('看着像 JS 但没有配置对象 → 整份当脚本', () {
      const src = '''
function doWork(input) {
  var result = input.split(',');
  return result.map(function (x) { return x.trim(); });
}
''';
      final list = SourceImportParser.parse(src);
      expect(list.length, 1);
      expect(list[0].kind, 'script');
      expect(list[0].script, contains('doWork'));
    });
  });

  group('失败路径', () {
    test('空内容报 empty', () {
      expect(
        () => SourceImportParser.parse('   '),
        throwsA(isA<SourceImportException>()
            .having((e) => e.error, 'error', SourceImportError.empty)),
      );
    });

    test('完全不像源的内容报 unsupported', () {
      expect(
        () => SourceImportParser.parse('这是一段普通的中文说明文字，没有任何配置。'),
        throwsA(isA<SourceImportException>()
            .having((e) => e.error, 'error', SourceImportError.unsupported)),
      );
    });

    test('短文本不会被误判成脚本', () {
      expect(
        () => SourceImportParser.parse('const a = 1;'),
        throwsA(isA<SourceImportException>()),
        reason: '太短的不该当脚本导入（否则用户导什么都能"成功"）',
      );
    });
  });

  group('去重', () {
    test('同名重复条目只留一条', () {
      final list = SourceImportParser.parse('''
[{"name":"重复源","template":"https://d.com/1"},
 {"name":"重复源","template":"https://d.com/2"}]
''');
      expect(list.length, 1, reason: '同名应去重');
    });
  });
}
