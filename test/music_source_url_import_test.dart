import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/services/source_import_parser.dart';

/// 复核用户实测：粘贴音源**URL** 点导入 → 报"无法识别的音源格式"。
///
/// ── 推断 ──────────────────────────────────────────────────────
/// 导入弹层的 `onPressed` 直接把输入框文本喂给
/// `SourceImportParser.importIntoStore(text)`，
/// 也就是**把那一行 URL 当成脚本内容去解析**，从来没去下载它。
/// 一个 http(s) 地址：
///   · 不是 JSON
///   · 不含 `module.exports` / `SERVER_SCRIPT_CONFIG` / `EVENT_NAMES`
///   · 无 `//` 注释头里的 `@name/@template`
///   · 长度够但不像脚本
/// → 必然走到 `unsupported('无法识别的音源格式')`。
void main() {
  const url = 'https://raw.githubusercontent.com/wangshiyulin/'
      'LXmusic-source/refs/heads/main/星海音乐源v2.3.14.js';

  test('把 URL 当内容解析 → 必然 unsupported（复现用户报错）', () {
    expect(
      () => SourceImportParser.parse(url),
      throwsA(isA<SourceImportException>().having(
        (e) => e.error,
        'error',
        SourceImportError.unsupported,
      )),
      reason: '这就是用户看到的那条报错 —— 说明导入路径没有"识别 URL 并下载"这一步',
    );
  });

  test('识别 URL 的判据：http/https 开头（供修复使用）', () {
    expect(url.startsWith('http://') || url.startsWith('https://'), isTrue);
    // 注意路径里有中文 —— 请求前必须百分号编码
    final u = Uri.parse(url);
    // ignore: avoid_print
    print('[probe] host=${u.host} path=${u.path}');
    // ignore: avoid_print
    print('[probe] 编码后 path=${Uri.encodeFull(u.path)}');
    expect(Uri.encodeFull(u.path).contains('%'), isTrue,
        reason: '中文路径必须编码，否则 raw.githubusercontent 会返回 400/404');
  });

  test('真正的 LX 脚本内容应该能解析成功（对照组）', () {
    const lxScript = '''
/**
 * @name 星海音乐源
 * @description 测试用
 * @version 2.3.14
 */
const { EVENT_NAMES, request, on, send } = globalThis.lx;
module.exports = { test: () => {} };
''';
    final list = SourceImportParser.parse(lxScript);
    expect(list, isNotEmpty, reason: '一份完整 LX 脚本应当导入成功');
    expect(list.first.kind, 'script');
  });
}
