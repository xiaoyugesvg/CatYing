import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/rss/models/rss_source.dart';

/// 临时探针：拿用户给的真实 txt（Legado 订阅源数组）跑一遍解析，
/// 看能不能吃下、吃下几条、每条有没有可用的抓取规则。
void main() {
  const path =
      r'c:\Users\24647\.trae-cn\attachments\0920c1fe-287d-4663-b9db-e69ed7737997_be28483f-8410-407e-b111-60975aabf85f_[__ {__....txt';

  test('解析用户给的 txt', () async {
    final raw = await File(path).readAsString();
    // ignore: avoid_print
    print('RAW_LEN=${raw.length}');
    final list = parseRssSources(raw);
    // ignore: avoid_print
    print('PARSED=${list.length}');
    for (final s in list) {
      // ignore: avoid_print
      print('  name=[${s.name}] group=[${s.group}] '
          'url=[${s.url}] singleUrl=${s.singleUrl} hasRules=${s.hasRules} '
          'articles=[${(s.ruleArticles ?? '').replaceAll('\n', ' ').substring(0, (s.ruleArticles ?? '').length.clamp(0, 30))}] '
          'title=[${s.ruleTitle}] link=[${s.ruleLink}] '
          'channels=${s.channels.length}');
    }
  });
}
