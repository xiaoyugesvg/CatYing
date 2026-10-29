import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThemeBackground 序列化', () {
    test('不透明度/模糊可往返', () {
      const bg = ThemeBackground(
        type: ThemeBackgroundType.image,
        imagePath: '/tmp/a.jpg',
        opacity: 0.6,
        blur: 8,
      );
      final back = ThemeBackground.fromMap(bg.toMap());
      expect(back.type, ThemeBackgroundType.image);
      expect(back.imagePath, '/tmp/a.jpg');
      expect(back.opacity, closeTo(0.6, 1e-9));
      expect(back.blur, closeTo(8, 1e-9));
      expect(back, bg);
    });

    test('旧配置缺字段时回退默认值', () {
      final back = ThemeBackground.fromMap({
        'type': 'animation',
        'animationId': 'green',
      });
      expect(back.type, ThemeBackgroundType.animation);
      expect(back.opacity, 1.0);
      expect(back.blur, 0.0);
      // 默认值不写进 map，保持旧格式体积
      expect(back.toMap().containsKey('opacity'), isFalse);
      expect(back.toMap().containsKey('blur'), isFalse);
    });

    test('越界值被钳制', () {
      final back = ThemeBackground.fromMap({
        'type': 'image',
        'imagePath': '/tmp/b.jpg',
        'opacity': 0.01,
        'blur': 999,
      });
      expect(back.opacity, 0.2);
      expect(back.blur, 40.0);
    });

    test('copyWith 保留未指定字段', () {
      const bg = ThemeBackground.image('/tmp/c.jpg', opacity: 0.5, blur: 4);
      final changed = bg.copyWith(imagePath: '/tmp/d.jpg');
      expect(changed.imagePath, '/tmp/d.jpg');
      expect(changed.opacity, 0.5);
      expect(changed.blur, 4);
    });
  });

  group('主题导入/导出', () {
    test('导出后可原样导入', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = SettingsService();
      final theme = ThemePresetInfo(
        'x',
        '导出测试',
        const JellyPalette.pink(),
        background: const ThemeBackground.animation('ocean', opacity: 0.8),
      );
      final json = const JsonEncoder().convert({
        'kind': 'reading_themes',
        'version': 1,
        'themes': [
          {
            'name': theme.name,
            'colors': theme.palette.toMap(),
            'background': theme.background.toMap(),
          },
        ],
      });
      final count = await svc.importCustomThemes(json);
      expect(count, 1);
      final imported = svc.customThemes.last;
      expect(imported.name, '导出测试');
      expect(imported.palette.primary, theme.palette.primary);
      expect(imported.background.type, ThemeBackgroundType.animation);
      expect(imported.background.animationId, 'ocean');
      expect(imported.background.opacity, closeTo(0.8, 1e-9));

      // 导出的 JSON 能被再次解析（导出只含当前 1 套）
      final exported = svc.exportCustomThemes();
      final again = await svc.importCustomThemes(exported);
      expect(again, 1);
    });

    test('无效 JSON 返回 0，且不清空已有主题', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = SettingsService();
      final before = svc.customThemes.length;
      expect(await svc.importCustomThemes('not json'), 0);
      expect(await svc.importCustomThemes('{"themes":[]}'), 0);
      expect(svc.customThemes.length, before);
    });

    test('支持单主题对象与主题数组两种入参', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = SettingsService();
      final single = await svc.importCustomThemes(
        '{"name":"单个","colors":{"primary":"#FF112233"}}',
      );
      expect(single, 1);
      expect(svc.customThemes.last.name, '单个');
      final array = await svc.importCustomThemes(
        '[{"name":"A","colors":{}},{"name":"B","colors":{}}]',
      );
      expect(array, 2);
    });
  });
}
