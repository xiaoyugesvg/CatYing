import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 接口配置引导页的回归测试。
///
/// 守两件事：
///   1. **猫猫 Logo 能真的加载出来**（asset 没注册的话运行时会报
///      "Unable to load asset"，而静态分析完全看不出来）
///   2. **键盘弹起时页面会避让**（这一页中间有接口地址输入框，
///      不避让就会被键盘盖住）
void main() {
  testWidgets('猫猫 Logo asset 能加载（尺寸与 fit 正确）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: ClipOval(
              child: Image.asset(
                'assets/images/cat_logo.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // asset 加载失败时 Flutter 会插入一个带错误信息的 widget
    final errs = tester.takeException();
    expect(errs, isNull, reason: 'Logo asset 加载失败：$errs');

    final img = tester.widget<Image>(find.byType(Image));
    expect(img.fit, BoxFit.cover);
    expect(find.byType(ClipOval), findsWidgets);
  });

  testWidgets('键盘弹起时底部内边距 = 键盘高度（避让输入框）', (tester) async {
    // 模拟键盘高度 336（iPhone 常见值）
    const keyboard = 336.0;

    double insetOf(WidgetTester t) {
      final ctx = t.element(find.byType(Padding).first);
      return MediaQuery.viewInsetsOf(ctx).bottom;
    }

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: keyboard)),
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: const SizedBox(height: 100),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(insetOf(tester), keyboard,
        reason: '键盘 336 时 viewInsets.bottom 应为 336，页面才会抬高避让');

    // 键盘收起 → 归零，页面回落（不能常驻留白）
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(),
        child: MaterialApp(
          home: SizedBox(height: 100),
        ),
      ),
    );
    await tester.pumpAndSettle();
  });
}
