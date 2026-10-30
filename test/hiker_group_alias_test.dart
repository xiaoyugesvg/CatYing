import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/hiker/services/hiker_prefs.dart';

/// 海阔「切换源」弹窗的分类胶囊改名（2026-10-30）。
///
/// 用户：「下面那个名称分组要可以修改呢」。
/// 约束：**只改显示，不改数据** —— 过滤 / 计数 / 重新导入都仍按原名走，
/// 所以改名不会把源筛丢。留空或填回原名 = 恢复默认。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('分类别名：改名只影响显示，留空 / 原名都能恢复默认', () async {
    final p = HikerPrefs.instance;

    // 没改过 → 原名原样返回
    expect(p.groupLabel('18+'), '18+');
    expect(p.hasGroupAlias('18+'), isFalse);

    await p.setGroupAlias('18+', '成人');
    expect(p.groupLabel('18+'), '成人');
    expect(p.hasGroupAlias('18+'), isTrue);
    // 别名表里存的是「原名 → 显示名」
    expect(p.groupAliases['18+'], '成人');

    // 留空 = 恢复默认
    await p.setGroupAlias('18+', '');
    expect(p.groupLabel('18+'), '18+');
    expect(p.hasGroupAlias('18+'), isFalse);

    // 填回原名也等于没改（不往表里塞无意义映射）
    await p.setGroupAlias('10内网10', '10内网10');
    expect(p.hasGroupAlias('10内网10'), isFalse);
  });

  test('分类别名：空原名不写入（避免污染别名表）', () async {
    final p = HikerPrefs.instance;
    await p.setGroupAlias('   ', '随便');
    expect(p.groupAliases, isEmpty);
  });
}
