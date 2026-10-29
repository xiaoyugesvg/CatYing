import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/services/webview_page_color.dart';

/// 「顶栏跟随网页配色」的颜色解析回归测试。
///
/// 解析错了的后果不是"难看"而是**刷错颜色**（比如把 #RRGGBBAA 当成 ARGB 用，
/// 红色会变成全透明）⇒ 这里把支持的写法逐条钉死。
void main() {
  group('parseCssColor', () {
    test('#RRGGBB', () {
      expect(parseCssColor('#0a84ff'), const Color(0xff0a84ff));
      expect(parseCssColor('  #0A84FF  '), const Color(0xff0a84ff));
    });

    test('#RGB 短写法要展开成两位', () {
      expect(parseCssColor('#abc'), const Color(0xffaabbcc));
      expect(parseCssColor('#FFF'), const Color(0xffffffff));
    });

    test('#RRGGBBAA 的 alpha 在**末尾**（CSS 顺序 ≠ Flutter 顺序）', () {
      // 关键：不能直接 int.parse 当 ARGB 用
      expect(parseCssColor('#0a84ff80'), const Color(0x800a84ff));
      expect(parseCssColor('#00000000'), const Color(0x00000000));
    });

    test('rgb() / rgba()', () {
      expect(parseCssColor('rgb(247, 245, 241)'), const Color(0xfff7f5f1));
      expect(parseCssColor('rgb( 10 , 132 , 255 )'), const Color(0xff0a84ff));
      // rgba 的 alpha 是 0~1
      expect(parseCssColor('rgba(0, 0, 0, 0.5)'), const Color(0x80000000));
      expect(parseCssColor('rgba(0,0,0,1)'), const Color(0xff000000));
    });

    test('百分比写法', () {
      expect(parseCssColor('rgb(100%, 0%, 0%)'), const Color(0xffff0000));
      expect(parseCssColor('rgba(0, 0, 0, 50%)'), const Color(0x80000000));
    });

    test('认不出的写法一律返回 null（宁可不上色，也别刷错色）', () {
      expect(parseCssColor(null), isNull);
      expect(parseCssColor(''), isNull);
      expect(parseCssColor('   '), isNull);
      expect(parseCssColor('transparent'), isNull);
      expect(parseCssColor('white'), isNull); // 具名色不支持
      expect(parseCssColor('hsl(1, 2%, 3%)'), isNull);
      expect(parseCssColor('#12345'), isNull); // 位数不对
      expect(parseCssColor('rgb(a, b, c)'), isNull);
      expect(parseCssColor('rgb(1, 2)'), isNull);
    });
  });

  test('探测脚本非空且是个自执行表达式', () {
    expect(kPageColorProbeJs.trim(), isNotEmpty);
    expect(kPageColorProbeJs.trim().startsWith('(function'), isTrue);
  });
}
