// 音乐内置订阅的存量迁移：旧 github.io 镜像地址 → jsDelivr。
//
// 背景：内置地址换成 jsDelivr 后只有**首启用户**能种到新地址，已安装用户
// prefs 里存的是旧 github.io 地址且 `_seededKey` 已为 true ⇒ 种子逻辑跳过，
// 订阅条目还在但拉清单长期失败。`mirrorToJsDelivr` 负责就地改写存量地址。

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/models/plugin_subscription.dart';

void main() {
  group('PluginSubscriptionStore.mirrorToJsDelivr', () {
    test('旧内置订阅清单地址被改写为 jsDelivr', () {
      expect(
        PluginSubscriptionStore.mirrorToJsDelivr(
          'https://hebijunge.github.io/musicfree-plugins/plugins-gcore.json',
        ),
        'https://gcore.jsdelivr.net/gh/hebijunge/musicfree-plugins@master/plugins-gcore.json',
      );
    });

    test('旧镜像下的插件脚本地址同样改写（路径原样保留）', () {
      expect(
        PluginSubscriptionStore.mirrorToJsDelivr(
          'https://hebijunge.github.io/musicfree-plugins/plugins/five-source-lx.plugin.v1.2.0.js',
        ),
        'https://gcore.jsdelivr.net/gh/hebijunge/musicfree-plugins@master/plugins/five-source-lx.plugin.v1.2.0.js',
      );
    });

    test('已是 jsDelivr 地址 → 返回 null（幂等，不重复写盘）', () {
      expect(
        PluginSubscriptionStore.mirrorToJsDelivr(
          'https://gcore.jsdelivr.net/gh/hebijunge/musicfree-plugins@master/plugins-gcore.json',
        ),
        isNull,
      );
    });

    test('用户自填的其它地址一律不动', () {
      expect(
        PluginSubscriptionStore.mirrorToJsDelivr('https://example.com/my.json'),
        isNull,
      );
      expect(
        PluginSubscriptionStore.mirrorToJsDelivr(
          'https://hebijunge.github.io/other-project/x.json',
        ),
        isNull,
      );
    });

    test('空串 / 只有基址 → 返回 null', () {
      expect(PluginSubscriptionStore.mirrorToJsDelivr(''), isNull);
      expect(PluginSubscriptionStore.mirrorToJsDelivr('   '), isNull);
      expect(
        PluginSubscriptionStore.mirrorToJsDelivr(
          'https://hebijunge.github.io/musicfree-plugins/',
        ),
        isNull,
      );
    });

    test('首尾空白被忽略', () {
      expect(
        PluginSubscriptionStore.mirrorToJsDelivr(
          '  https://hebijunge.github.io/musicfree-plugins/plugins-gcore.json  ',
        ),
        'https://gcore.jsdelivr.net/gh/hebijunge/musicfree-plugins@master/plugins-gcore.json',
      );
    });

    test('内置地址本身指向 jsDelivr（防止以后又把内置改回 github.io）', () {
      expect(
        PluginSubscriptionStore.builtinUrl,
        startsWith(PluginSubscriptionStore.jsDelivrGhBase),
      );
      expect(PluginSubscriptionStore.mirrorToJsDelivr(
        PluginSubscriptionStore.builtinUrl,
      ), isNull);
    });
  });
}
