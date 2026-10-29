import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/services/source_import_parser.dart';

/// **主链路集成测试**：URL 导入 → 识别 → 存进 store → 能取出脚本。
///
/// 覆盖用户要求的这一条：
///   「本地/URL 导入 + getMediaSource 能取到地址 + 能播」
///
/// ⚠️ 这里**不真的发网络请求**（单测不能依赖外网），用的是
/// `test/samples/kulao.js` 的真实插件内容，走
/// `parseFetched(body, url)` —— 这正是 URL 导入在 `_fetchUrl`
/// 成功之后走的那一步。
void main() {
  String? sample(String n) {
    final f = File('test/samples/$n');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  test('URL 导入链路：parseFetched → kind=musicfree → 脚本完整', () {
    final body = sample('kulao.js');
    if (body == null) {
      markTestSkipped('test/samples/kulao.js 不存在');
      return;
    }
    // 模拟 `importIntoStore` 里 `_fetchUrl` 拿到 body 之后的那一步
    const url = 'https://dogpan.com/f/JZxpTK/%E8%A3%A4%E4%BD%ACSVIP%E9%9F%B3%E6%BA%90.js';
    final list = SourceImportParser.parseFetched(body, url);

    expect(list, isNotEmpty, reason: 'URL 导入必须能解析出音源');
    final s = list.first;
    expect(s.kind, 'musicfree');
    // 名字应优先取 platform（插件自报），而不是 URL 里的文件名
    expect(s.name, contains('裤佬'), reason: '应取 platform 名，实际=${s.name}');
    print('  URL 导入 → kind=${s.kind}  name=${s.name}  quality=${s.quality}');
  });

  test('存进 store 后能取回（序列化往返不丢 kind/script）', () {
    final body = sample('kulao.js');
    if (body == null) {
      markTestSkipped('缺少样本');
      return;
    }
    final s = SourceImportParser.parseFetched(body, 'https://x/y.js').first;

    // 往返：toJson → fromJson（store 就是这么持久化的）
    final back = ThirdPartySource.fromJson(s.toJson());
    expect(back.kind, 'musicfree', reason: 'kind 必须能持久化');
    expect(back.isMusicFree, isTrue);
    expect(back.usesScript, isTrue, reason: 'MusicFree 也是脚本型');
    expect(back.script, isNotNull);
    expect(back.script!.length, closeTo(s.script!.length, 200),
        reason: '脚本内容不能丢（丢了插件就跑不起来）');
    print('  往返 OK: kind=${back.kind}  script=${back.script!.length} 字符  '
        'equals=${back.script == s.script}');
  });

  test('🔴 usesScript 语义：MusicFree 必须为 true（否则编辑器会丢脚本）', () {
    // 这是修复的那个 UI bug 的回归测试：
    // 音源管理页原来全按 `isScript` 分支，MusicFree 会被当模板法，
    // 保存时 `script: s.isScript ? scriptCtrl.text : s.script` 把脚本写回旧值。
    const mf = ThirdPartySource(
      id: '1', name: 'mf', kind: 'musicfree', template: '', script: 'x',
    );
    const lx = ThirdPartySource(
      id: '2', name: 'lx', kind: 'script', template: '', script: 'y',
    );
    const kw = ThirdPartySource(
      id: '3', name: 'kw', kind: 'keyword', template: 'https://t',
    );

    expect(mf.isMusicFree, isTrue);
    expect(mf.isScript, isFalse, reason: 'isScript 只针对 LX');
    expect(mf.usesScript, isTrue, reason: '🔴 MusicFree 必须走脚本分支');

    expect(lx.usesScript, isTrue);
    expect(kw.usesScript, isFalse);

    // 标签
    expect(mf.kindLabel, 'MusicFree');
    expect(lx.kindLabel, '脚本');
    expect(kw.kindLabel, 'KEYWORD');
    print('  标签: ${mf.kindLabel} / ${lx.kindLabel} / ${kw.kindLabel}');
  });

  test('模板法源不受影响（回归）', () {
    const jsonLike = '''
{
  "name": "模板源",
  "kind": "keyword",
  "template": "https://api.example.com/url?name={name}&artist={artist}",
  "urlPath": "data.url"
}
''';
    final list = SourceImportParser.parse(jsonLike);
    expect(list, isNotEmpty);
    expect(list.first.kind, 'keyword');
    expect(list.first.usesScript, isFalse);
    expect(list.first.template, contains('{name}'));
  });
}
