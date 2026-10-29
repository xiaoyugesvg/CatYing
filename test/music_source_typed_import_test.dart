import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/services/source_import_parser.dart';

/// **两张卡各自强制类型**的契约测试。
///
/// ── 背景 ──────────────────────────────────────────────────────
/// 界面上有两个**独立**的导入入口：
///   · 「洛雪音乐源」卡 —— 期待 LX 源（`script`）或模板法（`keyword`）
///   · 「MusicFree 源」卡 —— 只期待 MusicFree 插件（`musicfree`）
///
/// 如果只靠自动识别，用户在洛雪卡里粘一个 MusicFree 插件会**被静默接受**
/// （解析是成功的），但用户的心智是"我要加一个洛雪源" ——
/// 结果他只会困惑"我明明加在洛雪里，怎么跑 MusicFree 去了"。
///
/// 所以 `importIntoStoreTyped` 必须能**拒绝并说明原因**。
void main() {
  // ⚠️ 必须初始化 binding：`importIntoStoreTyped` 成功时会调
  // `ThirdPartySourceStore.addAll` → 落盘 SharedPreferences。
  // 不初始化的话会打一堆
  //   "Binding has not yet been initialized"
  // 噪音（测试仍会过，但日志很脏，而且掩盖真正的问题）。
  TestWidgetsFlutterBinding.ensureInitialized();

  String? sample(String n) {
    final f = File('test/samples/$n');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  const lxScript = '''
const { EVENT_NAMES, on } = globalThis.lx;
on(EVENT_NAMES.request, async (payload) => ({ url: 'https://cdn/' + payload.musicInfo.id }));
''';

  const mfPlugin = '''
const axios = require('axios');
const he = require('he');
module.exports = {
  platform: "测试MusicFree源",
  async getMediaSource(musicItem, quality) { return { url: 'https://cdn/' + musicItem.id }; },
};
''';

  const templateSource = '''
{
  "name": "模板源",
  "kind": "keyword",
  "template": "https://api.example.com/url?name={name}",
  "urlPath": "data.url"
}
''';

  test('🔴 把 MusicFree 插件粘到「洛雪音乐源」卡 → 必须拒绝并说明', () async {
    final r = await SourceImportParser.importIntoStoreTyped(
      mfPlugin,
      expectMusicFree: false,
    );
    expect(r.count, 0, reason: '不能入库');
    expect(r.mismatch, isNotNull, reason: '必须给用户一个原因');
    expect(r.mismatch, contains('MusicFree'), reason: '要指明它到底是什么');
    expect(r.mismatch, contains('洛雪'), reason: '要指明该去哪张卡');
    print('  洛雪卡 ← MusicFree 插件: ${r.mismatch}');
  });

  test('🔴 把洛雪源粘到「MusicFree 源」卡 → 必须拒绝并说明', () async {
    final r = await SourceImportParser.importIntoStoreTyped(
      lxScript,
      expectMusicFree: true,
    );
    expect(r.count, 0);
    expect(r.mismatch, isNotNull);
    expect(r.mismatch, contains('洛雪'));
    print('  MusicFree卡 ← 洛雪源: ${r.mismatch}');
  });

  test('模板法也是洛雪生态 → 洛雪卡必须接受它（不能被一起拒掉）', () async {
    final r = await SourceImportParser.importIntoStoreTyped(
      templateSource,
      expectMusicFree: false,
    );
    // 这里不断言 count（可能因 store 里已存在而返回 0），
    // 只断言**没有被类型校验拒绝**
    expect(r.mismatch, isNull,
        reason: '模板法(keyword)属于洛雪一侧，类型校验必须放行');
  });

  test('真实 MusicFree 插件 → MusicFree 卡放行', () async {
    final src = sample('kulao.js');
    if (src == null) {
      markTestSkipped('缺少 test/samples/kulao.js');
      return;
    }
    final r = await SourceImportParser.importIntoStoreTyped(
      src,
      expectMusicFree: true,
      fallbackName: 'kulao',
    );
    expect(r.mismatch, isNull, reason: '真实插件在正确的卡里不能被拒');
  });

  test('真实 MusicFree 插件 → 洛雪卡拒绝', () async {
    final src = sample('kulao.js');
    if (src == null) {
      markTestSkipped('缺少 test/samples/kulao.js');
      return;
    }
    final r = await SourceImportParser.importIntoStoreTyped(
      src,
      expectMusicFree: false,
      fallbackName: 'kulao',
    );
    expect(r.mismatch, isNotNull);
    expect(r.count, 0);
  });

  test('真实洛雪源 → 洛雪卡放行、MusicFree 卡拒绝', () async {
    final src = sample('xinghai.js');
    if (src == null) {
      markTestSkipped('缺少 test/samples/xinghai.js');
      return;
    }
    final ok = await SourceImportParser.importIntoStoreTyped(
      src,
      expectMusicFree: false,
      fallbackName: 'xinghai',
    );
    expect(ok.mismatch, isNull, reason: '洛雪源在洛雪卡里必须放行');

    final bad = await SourceImportParser.importIntoStoreTyped(
      src,
      expectMusicFree: true,
      fallbackName: 'xinghai',
    );
    expect(bad.mismatch, isNotNull, reason: '洛雪源在 MusicFree 卡里必须被拒');
  });
}
