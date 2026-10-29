import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:tvbox/services/app_state.dart';
import 'package:tvbox/widgets/app_loading_view.dart';

void main() {
  setUp(() {
    Get.testMode = true;
    Get.put<AppState>(AppState());
  });

  tearDown(() {
    Get.reset();
  });

  test('源加载失败后仍可进入应用', () {
    final s = Get.find<AppState>();
    s.loadingPhase.value = LoadingPhase.failed;
    s.configLoadError.value = '测试源错误';
    expect(s.isConfigLoaded.value, isFalse);
    s.enterAppWithoutConfig();
    expect(s.isConfigLoaded.value, isTrue);
    // 失败原因保留，方便设置页排查
    expect(s.configLoadError.value, '测试源错误');
  });

  testWidgets('加载失败页必须给出「先进入应用 / 重试 / 更换源」', (tester) async {
    final s = Get.find<AppState>();
    s.loadingPhase.value = LoadingPhase.failed;
    s.configLoadError.value = '测试源错误';

    await tester.pumpWidget(const MaterialApp(home: AppLoadingView()));
    await tester.pump();

    expect(find.text('先进入应用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('更换源'), findsOneWidget);

    await tester.tap(find.text('先进入应用'));
    await tester.pump();
    expect(s.isConfigLoaded.value, isTrue);
  });
}
