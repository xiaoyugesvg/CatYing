// 三族本地源（本地PY / 本地JS / XBPQ）的开关必须**各管各的**。
//
// ── 用户 2026-10-31 ────────────────────────────────────────────
// 「还有本地JS也缺少一个开关吧」+「之前日志里面那个本地JS切换还是串」。
//
// 背景：当天早些时候按「不留了」把本地 JS 的开关删成了常量 true，
// 于是这一族**关不掉**；而短剧那几处又用 `localSourcesEnabled`（本地 PY 的
// 开关）代表三族 ⇒ 打开 PY 就等于打开 JS / XBPQ。
// 「串」就是这种：关掉的那一族还在，切了等于没切。
//
// 本文件守两件事：
//   ① 每族的 key 只看自己那一族的开关；
//   ② 代码里不许再出现「用一个开关代表全部本地源」的写法。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/api_config.dart';

ApiConfig get _api => ApiConfig.instance;

String _read(String relative) => File(relative).readAsStringSync();

/// 造一个只带 key 的 SourceBean（判定只看 key 前缀）
SourceBean _bean(String key) => SourceBean(
      key: key,
      name: key,
      api: '',
      type: 0,
    );

void main() {
  setUpAll(() {
    // ApiConfig.instance 走 Get.find，单测里要先注册
    Get.put(ApiConfig());
  });


  group('每族只看自己的开关', () {
    tearDown(() {
      // 复原，避免影响其它用例
      _api.localSourcesEnabled.value = false;
      _api.localJsEnabled.value = true;
      _api.localXbpqEnabled.value = false;
    });

    test('本地 PY 只看 localSourcesEnabled', () {
      _api.localSourcesEnabled.value = true;
      _api.localJsEnabled.value = false;
      expect(_api.isLocalSourceEnabled(_bean('localpy_a')), isTrue);

      _api.localSourcesEnabled.value = false;
      _api.localJsEnabled.value = true; // JS 开着也不该影响 PY
      expect(_api.isLocalSourceEnabled(_bean('localpy_a')), isFalse);
    });

    test('本地 JS 只看 localJsEnabled', () {
      _api.localJsEnabled.value = true;
      _api.localSourcesEnabled.value = false;
      expect(_api.isLocalSourceEnabled(_bean('${SourceBean.localJsKeyPrefix}a')),
          isTrue);

      _api.localJsEnabled.value = false;
      _api.localSourcesEnabled.value = true; // PY 开着也不该把 JS 带起来
      expect(_api.isLocalSourceEnabled(_bean('${SourceBean.localJsKeyPrefix}a')),
          isFalse);
    });

    test('XBPQ 只看 localXbpqEnabled', () {
      _api.localXbpqEnabled.value = true;
      _api.localJsEnabled.value = false;
      _api.localSourcesEnabled.value = false;
      expect(
        _api.isLocalSourceEnabled(_bean('${SourceBean.xbpqKeyPrefix}a')),
        isTrue,
      );

      _api.localXbpqEnabled.value = false;
      _api.localJsEnabled.value = true;
      expect(
        _api.isLocalSourceEnabled(_bean('${SourceBean.xbpqKeyPrefix}a')),
        isFalse,
      );
    });

    test('订阅线路不受任何本地开关影响', () {
      _api.localSourcesEnabled.value = false;
      _api.localJsEnabled.value = false;
      _api.localXbpqEnabled.value = false;
      expect(_api.isLocalSourceEnabled(_bean('sub_abc')), isTrue);
    });
  });

  group('代码里不许「一个开关代表三族」', () {
    const files = [
      'lib/pages/drama/view.dart',
      'lib/pages/drama/drama_settings.dart',
      'lib/pages/drama/drama_manage_page.dart',
    ];

    for (final f in files) {
      test('$f 用 isLocalSourceEnabled 过滤，不用 localSourcesEnabled', () {
        final src = _read(f);
        expect(
          src.contains('localVideoSources.where(api.isLocalSourceEnabled)'),
          isTrue,
          reason: '$f 又退回「用一个开关代表三族」了 —— '
              '打开本地PY 会把关掉的 本地JS / XBPQ 一起带出来（用户说的「串」）',
        );
        expect(
          RegExp(r'if \(api\.localSourcesEnabled\.value\)\s*\.\.\.api\.localVideoSources')
              .hasMatch(src),
          isFalse,
          reason: '$f 还在用 localSourcesEnabled 展开全部本地源',
        );
      });
    }
  });

  group('本地JS 开关本身', () {
    test('有独立的 prefs 键与 setter', () {
      final src = _read('lib/services/api_config.dart');
      expect(src.contains('localJsEnabled'), isTrue);
      expect(src.contains("'local_js_enabled_v1'"), isTrue,
          reason: 'prefs 键要和历史版本一致，否则老用户的选择会丢');
      expect(src.contains('setLocalJsEnabled'), isTrue);
      // 删掉的那个常量不该回来（回来就意味着又没开关了）
      expect(src.contains('localJsAlwaysEnabled'), isFalse,
          reason: 'localJsAlwaysEnabled 回来了 ⇒ 本地JS 又变成「导入即启用」、关不掉');
    });

    test('设置页有开关行（trailingSwitch + 回调）', () {
      final src = _read('lib/pages/settings/sub/data_source_settings_page.dart');
      final i = src.indexOf("title: '本地JS'");
      expect(i, greaterThan(-1));
      final block = src.substring(i, i + 600);
      expect(block.contains('trailingSwitch: true'), isTrue,
          reason: '本地JS 那行没有开关 —— 用户要的就是这个');
      expect(block.contains('setLocalJsEnabled'), isTrue);
    });
  });
}
