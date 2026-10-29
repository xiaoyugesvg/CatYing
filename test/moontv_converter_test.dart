import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/services/moontv_converter.dart';

void main() {
  group('MoonTvConverter', () {
    test('标准 video.json → TVBox sites', () {
      final json = jsonDecode('''
      {
        "cache_time": 7200,
        "api_site": {
          "a.example.com": {
            "name": "影视A",
            "api": "https://a.example.com/api.php/provide/vod",
            "detail": "https://a.example.com"
          },
          "b.example.com": {
            "name": "影视B",
            "api": "https://b.example.com/api.php/provide/vod",
            "detail": "https://b.example.com"
          }
        }
      }
      ''');
      final r = MoonTvConverter.tryConvert(json);
      expect(r, isNotNull);
      expect(r!.sites.length, 2);
      expect(r.warnings, isEmpty);
      final cfg = r.toConfig();
      final sites = cfg['sites'] as List;
      expect(sites.length, 2);
      final first = sites.first as Map;
      expect(first['type'], 1);
      expect(first['searchable'], 1);
      expect(first['quickSearch'], 1);
      expect(first['filterable'], 1);
      expect(first['key'], 'moontv_a_example_com');
      expect(first['api'], 'https://a.example.com/api.php/provide/vod');

      // 转换结果必须能被 AppConfigData 正常吃下（订阅加载走这条）
      final app = AppConfigData.fromJson(cfg);
      expect(app.hasUsableContent, isTrue);
      expect(app.sites!.length, 2);
      expect(app.sites!.first.type!.value, 1);
    });

    test('重复 api 只保留一个', () {
      final r = MoonTvConverter.tryConvert(jsonDecode('''
      {
        "api_site": {
          "a.com": {"name": "A", "api": "https://x.com/api.php/provide/vod"},
          "b.com": {"name": "B", "api": "https://x.com/api.php/provide/vod"}
        }
      }
      '''));
      expect(r, isNotNull);
      expect(r!.sites.length, 1);
      expect(r.warnings.single, contains('重复'));
    });

    test('相对 api 按 detail 解析', () {
      final r = MoonTvConverter.tryConvert(jsonDecode('''
      {
        "api_site": {
          "a.com": {
            "name": "A",
            "api": "/api.php/provide/vod",
            "detail": "https://a.com"
          }
        }
      }
      '''));
      expect(r, isNotNull);
      expect(r!.sites.single.api, 'https://a.com/api.php/provide/vod');
    });

    test('缺 api 的条目跳过并给出原因', () {
      final r = MoonTvConverter.tryConvert(jsonDecode('''
      {
        "api_site": {
          "a.com": {"name": "A"},
          "b.com": {"name": "B", "api": "https://b.com/api.php/provide/vod"}
        }
      }
      '''));
      expect(r, isNotNull);
      expect(r!.sites.length, 1);
      expect(r.warnings.single, contains('缺少 api'));
    });

    test('非 MoonTV / 已是 TVBox 的判定', () {
      expect(MoonTvConverter.tryConvert(jsonDecode('{"sites":[]}')), isNull);
      expect(MoonTvConverter.tryConvert(jsonDecode('{"foo":1}')), isNull);
      expect(MoonTvConverter.isTvBoxConfig(jsonDecode('{"sites":[{"api":"x"}]}')),
          isTrue);
      expect(MoonTvConverter.isTvBoxConfig(jsonDecode('{}')), isFalse);
    });
  });

  group('ConvertedConfigStore', () {
    test('local:// 前缀识别与文件名清洗', () {
      expect(ConvertedConfigStore.isLocal('local://moontv_1'), isTrue);
      expect(ConvertedConfigStore.isLocal('https://a.com/x.json'), isFalse);
      expect(ConvertedConfigStore.nameOf('local://moontv_1'), 'moontv_1');
      expect(ConvertedConfigStore.nameOf('local://../etc/passwd'), 'etcpasswd');
    });
  });
}
