import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/utils/header_footer_format.dart';

void main() {
  const vars = {
    '#': '第十二章 松紧',
    'c': '12',
    'C': '611',
    'p': '3',
    'P': '15',
    '%': '50%',
    't': '19:07',
    'b': '84%',
    'B': '枪炮、病菌与钢铁',
  };

  test('常规变量替换', () {
    expect(resolveHeaderFooterTemplate('#', vars), '第十二章 松紧');
    expect(resolveHeaderFooterTemplate('p/P', vars), '3/15');
    expect(
      resolveHeaderFooterTemplate('第c章 / 共C章', vars),
      '第12章 / 共611章',
    );
    expect(resolveHeaderFooterTemplate('t · b', vars), '19:07 · 84%');
    expect(resolveHeaderFooterTemplate('%', vars), '50%');
    expect(resolveHeaderFooterTemplate('B', vars), '枪炮、病菌与钢铁');
  });

  test('替换结果不会被二次替换', () {
    // 章节名里带 p / t / b，只能换一次
    expect(
      resolveHeaderFooterTemplate('#', const {'#': 'ptb'}),
      'ptb',
    );
  });

  test('未定义变量原样保留、空模板返回空串', () {
    expect(resolveHeaderFooterTemplate('第c章 xyz', vars), '第12章 xyz');
    expect(resolveHeaderFooterTemplate('', vars), '');
    expect(resolveHeaderFooterTemplate('第章', vars), '第章');
  });
}
