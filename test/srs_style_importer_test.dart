import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/services/srs_style_importer.dart';
import 'package:tvbox/reading/services/title_html_parser.dart';

/// 一份贴近真实 `.srs` 解密结果的样本（字段名/取值都按用户文件里的来）
Map<String, dynamic> sample() => {
  'style': {
    'id': 1632468268.541199,
    'name': '源阅读-古风·侠客江湖',
    'config': {
      'textSize': 19,
      'lineSpacingExtra': 19,
      'letterSpacing': 0.2,
      'paragraphSpacing': 19,
      'paragraphIndent': '\u3000\u3000',
      'paddingLeft': 25,
      'paddingRight': 25,
      'paddingTop': 14,
      'paddingBottom': 14,
      'headerPaddingTop': 48,
      'footerPaddingBottom': 28,
      'textColor': '#394554',
      'textColorNight': '#97897A',
      'bgType': 2,
      'bgStr': 'custom_1632488782.png',
      'bgTypeNight': 2,
      'bgStrNight': 'custom_1631789599.png',
      'titleStyleHtml':
          'cmt:\n<div style="text-align:right;">\n'
          '<h3 style="color:#3a4654">章节数</h3>\n'
          '<h4 style="color:#cbba75">章节名</h4>\n</div>',
      'titleStyleHtmlNight':
          'cmt:\n<div style="text-align:right;">\n'
          '<h3 style="color:#97897a">章节数</h3>\n'
          '<h4 style="color:#2d3b6c">章节名</h4>\n</div>',
      'topComponent': {
        'items': [
          {'alignment': 0, 'type': 'chapterTitle', 'format': '#'},
          {'alignment': 1, 'type': 'readProgress', 'format': '#%'},
          {'alignment': 1, 'type': 'pageNO', 'format': '#'},
        ],
      },
      'bottomComponent': {
        'items': [
          {'alignment': 0, 'type': 'time', 'format': '#'},
          {'alignment': 2, 'type': 'batteryRate', 'format': '#%'},
          {'alignment': 2, 'type': 'author', 'format': '人生苦短，及時行樂。'},
          {'alignment': 2, 'type': 'batteryIcon', 'format': '#'},
        ],
      },
    },
  },
  'dayBGImageData': base64Encode([1, 2, 3]),
  'nightBGImageData': base64Encode([4, 5, 6]),
};

void main() {
  test('.srs 解码：Base64 → 逐字节 XOR 0x60', () {
    final text = jsonEncode(sample());
    final b64 = base64Encode(utf8.encode(text));
    final bytes = [for (final c in b64.codeUnits) c ^ 0x60];
    final decoded = SrsStyleImporter.parse(bytes);
    expect(decoded?['style']?['name'], '源阅读-古风·侠客江湖');
  });

  test('明文 JSON（.decrypted.json）也能直接解析', () {
    final bytes = utf8.encode(jsonEncode(sample()));
    expect(SrsStyleImporter.parse(bytes)?['style']?['name'], '源阅读-古风·侠客江湖');
    expect(SrsStyleImporter.parse(utf8.encode('not json')), isNull);
  });

  test('映射：排版 / 颜色 / 标题样式 / 页眉页脚组件', () {
    final s = SrsStyleImporter.toReaderStyle(
      sample(),
      id: 'srs:1',
      bgImagePath: '/tmp/a.png',
      bgImagePathNight: '/tmp/a_n.png',
    );
    expect(s.name, '源阅读-古风·侠客江湖');
    expect(s.fontSize, 19);
    expect(s.lineHeight, 2.0); // 1 + 19/19
    expect(s.paraSpacing, 1.0); // 19px / 19
    // 字距按逻辑像素原值（0.2），不再乘字号
    expect(s.letterSpacing, closeTo(0.2, 0.001));
    expect(s.indent, 2);
    expect(s.padLeft, 25);
    expect(s.padRight, 25);
    expect(s.padTop, 14);
    expect(s.padBottom, 14);
    expect(s.headerPadTop, 48);
    expect(s.footerPadBottom, 28);
    expect(s.fgColor, 0xFF394554);
    expect(s.bgImagePath, '/tmp/a.png');
    expect(s.bgImagePathNight, '/tmp/a_n.png');
    expect(s.statusTextScale, 1.0);
    // 标题样式：去掉 cmt: 前缀并作为自定义 HTML 带进样式（日 / 夜各存一份）
    expect(s.chapterTitleStyle, 'custom');
    expect(s.chapterTitleHtml.contains('cmt:'), isFalse);
    expect(s.chapterTitleHtml.contains('章节名'), isTrue);
    expect(s.chapterTitleHtml.contains('#cbba75'), isTrue); // 日间标题名颜色
    expect(s.chapterTitleHtmlNight.contains('#97897a'), isTrue); // 夜间标题数字颜色
    // 页眉：左 = 章节名；中 = 进度 + 页码；右 = 空
    expect(s.headerL, '#');
    expect(s.headerC, '%p');
    expect(s.headerR, '');
    // 页脚：左 = 时间；右 = 电量 + 自定义文案（batteryIcon 被跳过）
    expect(s.footerL, 't');
    expect(s.footerC, '');
    expect(s.footerR, 'n%人生苦短，及時行樂。');
    // 夜间字色也一起带进来（切夜间不会变成深底深字）
    expect(s.fgColorNight, 0xFF97897A);
    // 标题文档能正常解析
    final doc = TitleHtml.compile(
      s.chapterTitleHtml,
      chapterNumber: '1',
      chapterName: '松紧',
    );
    expect(doc.isEmpty, isFalse);
  });

  test('日 / 夜配色独立：不再随导入时的模式对调', () {
    final s = SrsStyleImporter.toReaderStyle(sample(), id: 'srs:2');
    // 日间色永远来自 textColor，夜间色来自 textColorNight
    expect(s.fgColor, 0xFF394554);
    expect(s.fgColorNight, 0xFF97897A);
    // 深色日间字 ⇒ 纯色兜底用米黄(3)，不是夜间(5)
    expect(s.bgIndex, 3);
    expect(s.chapterTitleHtml.contains('#cbba75'), isTrue); // 日间那份
    expect(s.chapterTitleHtmlNight.contains('#97897a'), isTrue);
  });

  test('纯色底：bgStr / bgStrNight 各自独立', () {
    final cfg = {
      'style': {
        'name': '双色',
        'config': {
          'textSize': 19,
          'bgType': 0,
          'bgStr': '#F5EFE0',
          'bgTypeNight': 0,
          'bgStrNight': '#101010',
          'textColor': '#333333',
          'textColorNight': '#DDDDDD',
        },
      },
    };
    final s = SrsStyleImporter.toReaderStyle(cfg, id: 'srs:3');
    expect(s.bgColor, 0xFFF5EFE0);
    expect(s.bgColorNight, 0xFF101010);
    expect(s.fgColor, 0xFF333333);
    expect(s.fgColorNight, 0xFFDDDDDD);
  });

  test('背景图：白天 / 夜间取不同字节', () {
    expect(SrsStyleImporter.backgroundBytes(sample(), night: false), [1, 2, 3]);
    expect(SrsStyleImporter.backgroundBytes(sample(), night: true), [4, 5, 6]);
    expect(
      SrsStyleImporter.backgroundBytes({'style': {}}, night: false),
      isNull,
    );
  });
}
