import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/services/source_import_parser.dart';

/// **真实音源脚本**的导入回归测试。
///
/// 样本放在 `test/samples/`（见该目录说明），是从用户实际使用的源下载的：
///   · `kulao.js`   —— MusicFree 插件（`module.exports = { platform, getMediaSource }`
///                     + `require('axios')` + `require('he')`）
///   · `xinghai.js` —— LX 源（解构写法 `const { EVENT_NAMES, on, send } = globalThis.lx`
///                     然后 `on(EVENT_NAMES.request, …)`）
///
/// ⚠️ 这两个样本覆盖了**两条容易互相误判**的路径，所以很适合当回归基准：
///   · `xinghai` 连 `lx.on` 字样都没有（是解构的），早期会被判"无法识别"
///   · `kulao` 的导出名被 esbuild 压过，靠 `platform:` + `getMediaSource` 识别
void main() {
  String? read(String name) {
    final f = File('test/samples/$name');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  test('真实 MusicFree 插件（kulao.js）→ kind=musicfree', () {
    final src = read('kulao.js');
    if (src == null) {
      markTestSkipped('test/samples/kulao.js 不存在');
      return;
    }
    final list = SourceImportParser.parse(src, fallbackName: 'kulao');
    expect(list, isNotEmpty, reason: '不该抛"无法识别的音源格式"');
    expect(list.first.kind, 'musicfree',
        reason: 'MusicFree 插件必须标 musicfree，否则 require(axios) 会被沙箱拒');
    expect(list.first.script, isNotNull);
    expect(list.first.script!.length, closeTo(src.length, 200),
        reason: '整份脚本要保留（截断会让插件缺函数）');
    print('  kulao → kind=${list.first.kind}  name=${list.first.name}');
  });

  test('真实 LX 源（xinghai.js）→ kind != musicfree 且能识别', () {
    final src = read('xinghai.js');
    if (src == null) {
      markTestSkipped('test/samples/xinghai.js 不存在');
      return;
    }
    final list = SourceImportParser.parse(src, fallbackName: 'xinghai');
    expect(list, isNotEmpty,
        reason: '解构写法 `const { EVENT_NAMES, on } = globalThis.lx` '
            '必须能被识别（早期版本会抛"无法识别的音源格式"）');
    expect(list.first.kind, isNot('musicfree'),
        reason: '有 EVENT_NAMES / on(...) 的必须走 LX 路径');
    print('  xinghai → kind=${list.first.kind}  name=${list.first.name}');
  });

  test('两个样本走不同路径（这是本适配层的核心保证）', () {
    final k = read('kulao.js');
    final x = read('xinghai.js');
    if (k == null || x == null) {
      markTestSkipped('样本不全');
      return;
    }
    final kk = SourceImportParser.parse(k, fallbackName: 'k').first.kind;
    final xk = SourceImportParser.parse(x, fallbackName: 'x').first.kind;
    expect(kk, 'musicfree');
    expect(xk, isNot('musicfree'));
    expect(kk == xk, isFalse, reason: '两者必须被分到不同 kind，否则会互相干扰');
  });
}
