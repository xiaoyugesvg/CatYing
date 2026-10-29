import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/models/reader_title_style.dart';
import 'package:tvbox/reading/services/title_html_parser.dart';

/// 用户 2026 提供的「源阅读」标题样式（第三个，带 text-shadow / 网络图）
const _userStyle = '''
cmt: 
<div style="
    background-image: url('`https://s3.bmp.ovh/imgs/2022/02/afdcd499fc9ceb2d.png`');
    background-repeat: no-repeat;
    background-position:left;
    background-size: auto 100%;
  "> 
 <div style="text-align:left;"> 
  <h3 style="color:#236178;text-shadow:0 0 10px #236178;margin-left:0em;margin:0em 0.5em 3em 0em;font-weight:200;font-size:1.5em;font-family: 'PingFang SC'"> 章节数</h3> 
  <h4 style="box-shadow:0px 15px 10px -15px #000; display: inline-block;background-color: rgba(35,97,120,0.5);border-radius:16px;margin: 3em 0em 2em 0;padding:0.5em 2em 0.5em 2em; text-align:left; color: #f3f7fa; text-shadow:0 0 10px #f3f7fa;font-weight:200;font-size:1em;"> 章节名 </h4> 
 </div> 
</div>
''';

void main() {
  group('TitleHtml 解析', () {
    // 2026-10-26 更新：用户 2026-10-25 要求**不渲染「章节数」**
    //（阅读界面左上角那枚孤立数字），实现见 title_html_parser.dart 里
    // 「『章节数』占位符不渲染」那段。原用例还断言 texts 含 '12'，
    // 属于测试没跟上产品变更。
    test('占位符：章节数被隐藏 / 章节名被替换', () {
      final doc = TitleHtml.compile(
        ReaderTitleStyle.qingLan.html,
        chapterNumber: '12',
        chapterName: '风起于青萍之末',
      );
      final texts = <String>[];
      void walk(TitleBlock b) {
        if (b is TitleTextBlock) texts.add(b.text);
        if (b is TitleBoxBlock) b.children.forEach(walk);
      }

      walk(doc.root);
      expect(texts, contains('风起于青萍之末'));
      expect(texts, isNot(contains('12')), reason: '「章节数」应被隐藏，不再渲染');
    });

    test('用户提供的样式：反引号链接 / rgba / text-shadow / text-align:left', () {
      final doc = TitleHtml.compile(
        _userStyle,
        chapterNumber: '7',
        chapterName: '第七章节',
      );
      TitleBoxBlock? art;
      TitleBoxBlock? pill;
      void walk(TitleBlock b) {
        if (b is TitleBoxBlock) {
          if (b.style.backgroundImage != null) art = b;
          if (b.style.background != null) pill = b;
          b.children.forEach(walk);
        }
      }

      walk(doc.root);
      expect(
        art?.style.backgroundImage,
        'https://s3.bmp.ovh/imgs/2022/02/afdcd499fc9ceb2d.png',
      );
      expect(pill, isNotNull);
      final p = pill!;
      // rgba(35,97,120,0.5)
      expect(p.style.background, const Color(0x80236178));
      expect(p.style.color, const Color(0xFFF3F7FA));
      expect(p.style.shadows, isNotNull);
      expect(p.style.shadows!.first.blurRadius, 10);
      expect(p.style.textAlign, TextAlign.left);
      // h4 是 inline-block，宽度天然收缩（Flutter 侧无额外处理）
      expect(p.style.fontWeight, FontWeight.w200);
    });

    test('未支持的标签会被拍平，子节点不丢', () {
      final doc = TitleHtml.compile(
        '<section><table><tr><td style="color:#ff0000">章节名</td></tr></table></section>',
        chapterNumber: '1',
        chapterName: '标题A',
      );
      final texts = <String>[];
      void walk(TitleBlock b) {
        if (b is TitleTextBlock) texts.add(b.text);
        if (b is TitleBoxBlock) b.children.forEach(walk);
      }

      walk(doc.root);
      expect(texts, contains('标题A'));
    });

    test('border-bottom 省略颜色时按 currentColor 处理（不吞边框宽度）', () {
      final doc = TitleHtml.compile(
        '<h3 style="border-bottom: 1px solid; color:#123456">章节名</h3>',
        chapterNumber: '1',
        chapterName: '标题',
      );
      final box = doc.root.children.whereType<TitleBoxBlock>().first;
      expect(box.style.borderBottom, 1);
      expect(box.style.borderColor, isNull);
      // 边框宽度会计入内衬（左右为 0，只加底边 1px）
      final pad = box.style.resolvedPadding(box.style.fontSize(18));
      expect(pad.bottom, 1);
      expect(pad.left, 0);
    });

    test('空模板 / 空字符串 ⇒ isEmpty', () {
      final doc = TitleHtml.compile(
        '   ',
        chapterNumber: '1',
        chapterName: 'x',
      );
      expect(doc.isEmpty, isTrue);
    });
  });

  group('TitleHtml 渲染', () {
    test('带网络背景图的模板能构建 Widget（不联网、不抛异常）', () {
      final doc = TitleHtml.compile(
        _userStyle,
        chapterNumber: '2',
        chapterName: '第二章',
      );
      final w = TitleHtml.build(doc, baseFontSize: 18, fallbackColor: Colors.black);
      expect(w, isA<Column>());
    });

    // 2026-10-26：内置模板实际只有两套（weRead / qingLan），
    // 用例名原写「三套」是历史遗留；「章节数」已按用户要求隐藏，
    // 因此只断言章节名渲染成功 + 无异常。
    testWidgets('两套内置模板都能渲染出章节名且不报错', (tester) async {
      for (final style in [
        ReaderTitleStyle.weRead,
        ReaderTitleStyle.qingLan,
      ]) {
        final doc = TitleHtml.compile(
          style.html,
          chapterNumber: '9',
          chapterName: '第九章 测试',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 340,
                child: TitleHtml.build(
                  doc,
                  baseFontSize: 18,
                  fallbackColor: Colors.black,
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('第九章 测试'), findsOneWidget);
        // 「章节数」占位符按用户 2026-10-25 要求不渲染，故不再断言 '9'。
      }
    });
  });
}
