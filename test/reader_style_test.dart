import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/models/reader_style.dart';
import 'package:tvbox/reading/models/reader_title_style.dart';
import 'package:tvbox/reading/services/reader_style_store.dart';

/// 站点「导入排版」给的真实 readConfig（取 yckceo id=70「现代排版」的实际字段）
const _legadoModern = {
  'bgAlpha': 100,
  'bgStr': '',
  'bgStrNight': '#000000',
  'bgType': 0,
  'darkStatusIcon': true,
  'footerMode': 0,
  'footerPaddingBottom': 20,
  'footerPaddingLeft': 0,
  'footerPaddingRight': 22,
  'footerPaddingTop': 30,
  'headerMode': 1,
  'headerPaddingBottom': 23,
  'headerPaddingLeft': 24,
  'headerPaddingRight': 0,
  'headerPaddingTop': 47,
  'letterSpacing': 0.05,
  'lineSpacingExtra': 14,
  'name': '现代',
  'paddingBottom': 0,
  'paddingLeft': 27,
  'paddingRight': 27,
  'paddingTop': 0,
  'pageAnim': 2,
  'paragraphIndent': '\u3000',
  'textColor': '#000000',
  'textSize': 19,
  'textFont': '',
};

void main() {
  group('ReaderStyle', () {
    test('内置样式非空、id 唯一、名字不重复', () {
      expect(ReaderStyle.builtins, isNotEmpty);
      final ids = ReaderStyle.builtins.map((s) => s.id).toSet();
      expect(ids.length, ReaderStyle.builtins.length);
      final names = ReaderStyle.builtins.map((s) => s.name).toSet();
      expect(names.length, ReaderStyle.builtins.length);
    });

    test('toJson / fromJson 往返不丢字段', () {
      for (final s in ReaderStyle.builtins) {
        final back = ReaderStyle.fromJson(
          Map<String, dynamic>.from(jsonDecode(jsonEncode(s.toJson())) as Map),
        );
        expect(back.id, s.id);
        expect(back.name, s.name);
        expect(back.bgIndex, s.bgIndex);
        expect(back.fontSize, s.fontSize);
        expect(back.lineHeight, s.lineHeight);
        expect(back.pageMode, s.pageMode);
        expect(back.statusItems, s.statusItems);
        expect(back.padLeft, s.padLeft);
        expect(back.chapterTitleHtmlNight, s.chapterTitleHtmlNight);
      }
    });

    test('Legado 排版换算：字号 / 行高 / 字距 / 缩进 / 页眉页脚 / 翻页', () {
      final s = ReaderStyle.fromLegado(_legadoModern, id: 'import:1');
      expect(s.name, '现代');
      expect(s.fontSize, 19);
      // 行高 = 1 + 14/19
      expect(s.lineHeight, closeTo(1.7368, 0.001));
      // 字距按逻辑像素原值（0.05），不再乘字号
      expect(s.letterSpacing, closeTo(0.05, 0.001));
      // 一个全角空格 = 缩进 1 字
      expect(s.indent, 1);
      expect(s.padLeft, 27);
      expect(s.padRight, 27);
      // headerMode=1 → 时间；footerMode=0 → 页脚无
      expect(s.statusItems, ['时间']);
      // pageAnim=2 → 左右滑动
      expect(s.pageMode, 'slide');
      // textColor #000000 → 黑色正文
      expect(s.fgColor, 0xFF000000);
    });

    test('Legado 背景图（bgType=2，本机路径）退化成纯色', () {
      final s = ReaderStyle.fromLegado({
        'bgType': 2,
        'bgStr': '/storage/emulated/0/Android/data/io.legado.app.release/files/bg/x.jpg',
        'textColor': '#333333',
        'textSize': 19,
        'name': '带图样式',
      }, id: 'import:2');
      expect(s.bgColor, isNull);
      // 深色文字 → 米黄（索引 3）
      expect(s.bgIndex, 3);
      expect(s.dayBgIndex, 3);
    });

    test('页脚映射：footerMode=3 → 页码 + 进度 + 章节', () {
      final s = ReaderStyle.fromLegado({
        'footerMode': 3,
        'headerMode': 0,
        'textSize': 20,
      }, id: 'import:3');
      expect(s.statusItems, containsAll(['页码', '进度', '章节']));
      expect(s.statusItems, isNot(contains('时间')));
    });

    // 2026-10-26 更新：内置「雲和·無青」（builtin:wuqing）已被移除，
    // 当前内置样式为 wxread / pomo / gufeng 三套。
    // 原用例 firstWhere 找不到 → 抛 `Bad state: No element`。
    // 这里改为校验现存「古风·夜读」的参数，保住「内置样式参数别被改坏」
    // 这条回归价值。
    test('内置「古风·夜读」参数符合预期', () {
      final s = ReaderStyle.builtins.firstWhere(
        (e) => e.id == 'builtin:gufeng',
      );
      expect(s.name, '古风·夜读');
      expect(s.fontSize, 24);
      expect(s.lineHeight, closeTo(1.625, 0.001));
      expect(s.letterSpacing, closeTo(0.2, 0.001));
      expect(s.paraSpacing, closeTo(0.333, 0.001));
      expect(s.indent, 2);
      expect(s.padLeft, 25);
      expect(s.padRight, 25);
      expect(s.fgColor, 0xFF323232);
      expect(s.fgColorNight, 0xFFFFFCF7);
      // 日间无背景图（纯色），夜间有古风壁纸
      expect(s.bgImageAsset, isNull);
      expect(
        s.bgImageAssetNight!.endsWith('reading_bg_gufeng_night.webp'),
        isTrue,
      );
      // 正文走内置宋体
      expect(s.fontId, 'builtin:serif');
    });

    test('内置标题模板都有夜版，且与日间版不同', () {
      for (final t in ReaderTitleStyle.values) {
        if (t == ReaderTitleStyle.none || t == ReaderTitleStyle.custom) {
          continue;
        }
        expect(t.nightHtml.isNotEmpty, isTrue, reason: t.label);
        expect(t.nightHtml, isNot(t.html), reason: t.label);
      }
    });
  });

  group('ReaderStyleImporter', () {
    test('extractUrl 支持 legado:// 导入链接与裸链接', () {
      const zip = 'https://www.yckceo.com/yuedu/theme/readcode/id/108.zip';
      expect(
        ReaderStyleImporter.extractUrl(
          'legado://import/readConfig?src=$zip',
        ),
        zip,
      );
      expect(ReaderStyleImporter.extractUrl(zip), zip);
      expect(ReaderStyleImporter.extractUrl('随便一串'), isNull);
      expect(ReaderStyleImporter.extractUrl('ftp://x/y.zip'), isNull);
    });

    test('decodeConfig 能从 readConfig.zip 里抠出 JSON', () {
      final json = utf8.encode(jsonEncode(_legadoModern));
      final archive = Archive()
        ..addFile(
          ArchiveFile('readConfig.json', json.length, Uint8List.fromList(json)),
        );
      final zipBytes = ZipEncoder().encode(archive);
      expect(zipBytes, isNotNull);
      final cfg = ReaderStyleImporter.decodeConfig(zipBytes!);
      expect(cfg, isNotNull);
      expect(cfg!['name'], '现代');
      expect(cfg['textSize'], 19);
    });

    test('decodeConfig 也吃裸 JSON', () {
      final bytes = utf8.encode(jsonEncode({'name': '裸json', 'textSize': 18}));
      final cfg = ReaderStyleImporter.decodeConfig(bytes);
      expect(cfg?['name'], '裸json');
    });

    test('decodeConfig 对坏数据返回 null 而不是抛异常', () {
      expect(ReaderStyleImporter.decodeConfig(<int>[]), isNull);
      expect(ReaderStyleImporter.decodeConfig(utf8.encode('not a json')), isNull);
      expect(ReaderStyleImporter.decodeConfig([0x50, 0x4B, 0x03, 0x04, 1, 2]), isNull);
    });
  });
}
