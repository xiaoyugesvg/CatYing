import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/reading/source/source_definition.dart';

/// 书源导入解析测试。
///
/// 为什么重要：手动导入是用户自己加源的唯一入口。解析错一条，
/// 用户就得到一个**用不了又看不出为什么**的源。
/// 书源 JSON 在不同站点/不同人手里写法不一，所以覆盖多种形态。
void main() {
  List<SourceDefinition> parse(String text) {
    final decoded = jsonDecode(text);
    final defs = <SourceDefinition>[];

    void take(dynamic raw) {
      if (raw is! Map) return;
      final m = raw.cast<String, dynamic>();
      if (m.containsKey('config') && m['config'] is Map) {
        defs.add(SourceDefinition.fromJson(m));
        return;
      }
      if (m.containsKey('name') && m.containsKey('url')) {
        defs.add(SourceDefinition(
          id: 'config:${m['name']}',
          type: 'config',
          config: m,
        ));
      }
    }

    if (decoded is List) {
      for (final e in decoded) {
        take(e);
      }
    } else if (decoded is Map) {
      final m = decoded.cast<String, dynamic>();
      if (m['sources'] is List) {
        for (final e in (m['sources'] as List)) {
          take(e);
        }
      } else {
        take(m);
      }
    }
    return defs;
  }

  test('格式 1：单个源对象 {type,config}', () {
    final defs = parse('{"type":"config","config":{"name":"我的源","url":"https://x.com"}}');
    expect(defs.length, 1);
    expect(defs[0].type, 'config');
    expect(defs[0].id, 'config:我的源',
        reason: 'id 约定是 config:name，必须与 SourceManager 一致');
    expect(defs[0].config['url'], 'https://x.com');
  });

  test('格式 2：完整 sources.json', () {
    final defs = parse(
        '{"version":1,"sources":['
        '{"type":"config","config":{"name":"源A","url":"https://a.com"}},'
        '{"type":"api","engine":"zaimanhua","config":{"id":"zaimanhua","name":"再漫画"}}'
        ']}');
    expect(defs.length, 2);
    expect(defs[0].id, 'config:源A');
    expect(defs[1].type, 'api');
    expect(defs[1].engine, 'zaimanhua');
    expect(defs[1].id, 'zaimanhua', reason: 'api 源的 id 取 config.id');
  });

  test('格式 3：纯数组', () {
    final defs = parse('[{"type":"config","config":{"name":"甲","url":"https://j.com"}},'
        '{"type":"config","config":{"name":"乙","url":"https://y.com"}}]');
    expect(defs.length, 2);
    expect(defs.map((e) => e.id).toList(), ['config:甲', 'config:乙']);
  });

  test('格式 4：裸 SiteConfig（直接贴 config 内容）', () {
    final defs = parse('{"name":"裸配置源","url":"https://n.com"}');
    expect(defs.length, 1);
    expect(defs[0].id, 'config:裸配置源');
  });

  test('needsMagic 被保留并能序列化回去', () {
    final defs = parse(
        '{"type":"config","needsMagic":true,"config":{"name":"魔法源","url":"https://m.com"}}');
    expect(defs.length, 1);
    expect(defs[0].needsMagic, isTrue);
    expect(defs[0].toJson()['needsMagic'], isTrue,
        reason: '重新保存时不能丢，否则"需要魔法"标记会消失');
  });

  test('无效条目被丢弃', () {
    final defs = parse('[{"type":"config"},{"foo":"bar"},'
        '{"type":"config","config":{"name":"好源","url":"https://g.com"}}]');
    expect(defs.length, 1);
    expect(defs[0].id, 'config:好源');
  });

  test('往返序列化不丢字段', () {
    final defs = parse('{"type":"config","needsMagic":true,'
        '"config":{"name":"往返源","url":"https://r.com","imgDom":".pic img","useFrame":1}}');
    final round = SourceDefinition.fromJson(
        jsonDecode(jsonEncode(defs[0].toJson())) as Map<String, dynamic>);
    expect(round.id, defs[0].id);
    expect(round.needsMagic, isTrue);
    expect(round.config['imgDom'], '.pic img');
    expect(round.config['useFrame'], 1);
  });

  test('缺 name 能被识别（页面据此拒绝导入）', () {
    final defs = parse('{"type":"config","config":{"url":"https://x.com"}}');
    expect(defs.length, 1);
    final name = (defs[0].config['name'] ?? '').toString().trim();
    expect(name.isEmpty, isTrue, reason: '页面据此提示"缺少 name"');
  });
}
