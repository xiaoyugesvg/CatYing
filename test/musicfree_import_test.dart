import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/services/source_import_parser.dart';

/// MusicFree 插件导入的**契约测试**。
///
/// ── 背景 ──────────────────────────────────────────────────────
/// MusicFree 插件与 LX 源是两种形态：
///   LX 源：`lx.on('request')` / `module.exports = { musicUrl }`
///   MusicFree：`module.exports = { platform, getMediaSource, … }`
///             且**几乎都 `require('axios')`**
///
/// 导入时必须标对 `kind`：
///   · `kind: 'script'`    → Node 侧**强制**走 LX 路径（require 会被拒）
///   · `kind: 'musicfree'` → Node 侧走适配层（注入 axios/he 白名单）
///
/// ⚠️ 标错的后果：MusicFree 插件被当 LX 源 → `require('axios')` 被沙箱拒
/// → 报"脚本加载失败"。这正是用户实测到的。
void main() {
  group('MusicFree 插件识别', () {
    const kulaoLike = '''
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const axios_1 = require("axios");
const he = require("he");
module.exports = {
  platform: "裤佬SVIP音源",
  author: "TG",
  version: "8.8.8",
  supportedSearchType: ["music", "album"],
  async search(query, page, type) { return []; },
  async getMediaSource(musicItem, quality) {
    const url = await axios_1.default.get("http://music.nxinxz.com/kw.php?id=" + musicItem.id);
    return { url };
  },
  async getLyric(musicItem) { return { lyric: he.decode("&amp;") }; },
};
''';

    test('🔴 识别为 musicfree（不是 script）', () {
      final list = SourceImportParser.parse(kulaoLike);
      expect(list, isNotEmpty);
      expect(list.first.kind, 'musicfree',
          reason: '标成 script 会让 Node 强制走 LX 路径 → require(axios) 被拒');
      print('  kind=${list.first.kind}  name=${list.first.name}  '
          'quality=${list.first.quality}');
    });

    test('名字从 platform 取（不是"未命名音源"）', () {
      final list = SourceImportParser.parse(kulaoLike);
      expect(list.first.name, '裤佬SVIP音源');
    });

    test('脚本内容完整保留（不能只抠出 JSON 片段）', () {
      final list = SourceImportParser.parse(kulaoLike);
      final s = list.first.script ?? '';
      expect(s.contains('getMediaSource'), isTrue, reason: '入口方法必须保留');
      expect(s.contains("require(\"axios\")") || s.contains("require('axios')"),
          isTrue,
          reason: 'require 调用要保留（由 Node 适配层替换成白名单实现）');
    });

    test('🔴 LX 源**不能**被误判成 musicfree（也不能被弄坏）', () {
      // LX 源即使 require('axios')，只要出现 lx 标志就该走 LX 路径
      const lxWithAxios = '''
const { EVENT_NAMES, on } = globalThis.lx;
const axios = require('axios');
on(EVENT_NAMES.request, async (payload) => ({ url: 'https://x/' }));
''';
      final list = SourceImportParser.parse(lxWithAxios);
      expect(list, isNotEmpty);
      expect(list.first.kind, isNot('musicfree'),
          reason: '有 EVENT_NAMES/lx.on 标志 → 必须走 LX 路径');
      print('  LX+axios 被识别为 kind=${list.first.kind}');
    });

    test('纯 LX 源仍然识别为 script（回归）', () {
      const pureLx = '''
lx.on('musicUrl', async (info) => ({ url: 'https://cdn/' + info.musicInfo.id }));
''';
      final list = SourceImportParser.parse(pureLx);
      expect(list, isNotEmpty);
      expect(list.first.kind, 'script');
    });

    test('module.exports 但没有 axios/platform → 不误判', () {
      const plain = '''
module.exports = { musicUrl: async (info) => ({ url: 'https://x/' }) };
''';
      final list = SourceImportParser.parse(plain);
      expect(list, isNotEmpty);
      expect(list.first.kind, 'script',
          reason: '这是"module.exports 写法"的 LX 源，不是 MusicFree');
    });
  });
}
