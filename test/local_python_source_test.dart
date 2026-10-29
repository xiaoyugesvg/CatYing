import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/models/local_python_source.dart';
import 'package:tvbox/services/local_python_sources.dart';

void main() {
  test('本地 Python 源 → SourceBean：key/api 前缀映射正确', () {
    const s = LocalPythonSource(key: 'lp_abc123', name: '测试源', addedAt: 1);
    final bean = s.toSourceBean();

    expect(bean.key, 'localpy_lp_abc123');
    expect(bean.api, 'lp_abc123.py');
    expect(bean.type, 3);
    expect(bean.isSpiderSource, isTrue);
    // 这条必须为 true，SpiderService 才会走 CPython 分支
    expect(bean.isPythonScriptSource, isTrue);
    expect(bean.isSearchable, isTrue);
  });

  test('本地 Python 源 JSON 往返', () {
    const s = LocalPythonSource(key: 'lp_x', name: '名字', addedAt: 123);
    final back = LocalPythonSource.fromJson(s.toJson());
    expect(back.key, s.key);
    expect(back.name, s.name);
    expect(back.addedAt, s.addedAt);
    expect(back.sourceKey, 'localpy_lp_x');
  });

  test('空名字回退到 key（避免列表里出现空白行）', () {
    const s = LocalPythonSource(key: 'lp_y', name: '');
    expect(s.toSourceBean().name, 'lp_y');
  });

  test('批量 zip：没有 .py 时给出明确原因', () async {
    final bytes = ZipEncoder().encode(Archive())!;
    final r = await LocalPythonSources.instance.importZip(bytes);
    expect(r.imported, 0);
    expect(r.errors.join(), contains('没有 .py'));
  });

  test('批量 zip：能解析出 .py（非 iOS 环境由引擎守卫拦下）', () async {
    final a = Archive();
    final content = utf8.encode('print("hi")');
    a.addFile(ArchiveFile('demo.py', content.length, content));
    final bytes = ZipEncoder().encode(a)!;
    final r = await LocalPythonSources.instance.importZip(bytes);
    expect(r.imported, 0);
    // 测试机不是 iOS：应停在引擎守卫，而不是「zip 里没有 .py」
    expect(r.errors.join(), isNot(contains('没有 .py')));
  });
}

