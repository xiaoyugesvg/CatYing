import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/reading/services/zlibrary_service.dart';
import 'package:tvbox/reading/utils/constants.dart';

/// z-library 图书功能的**可用性**契约测试。
///
/// ── 背景（修的真实 bug）────────────────────────────────────────
/// `ZlibraryService().init()` 原先**全项目没有任何调用点**，
/// 于是 `_domain` 与 `_candidates` 永远是初始值（空串 / 空表）。
/// 而所有请求走 `_send()` → `_candidateOrder()`：
///   候选为空 → 内层 for 一次都不进 → `_setUnavailable(true)`
///   → 返回 `{success:false, unavailable:true}`
///   → UI 显示"所有 z-library 节点不可用，图书功能暂不可用"
///
/// **图书搜索 / 登录 / 下载全走这条路 —— 整个图书功能都是死的。**
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 不在测试里跑周期健康检查（会留 pending timer）
    ZlibraryService.healthTimerEnabled = false;
  });

  test('🔴 本地默认候选列表非空（否则探测无米下锅）', () {
    expect(CmbokConstants.zLibraryDefaultDomains, isNotEmpty);
    // 实测能返回真数据的节点必须在列表里
    expect(CmbokConstants.zLibraryDefaultDomains,
        containsAll(<String>['z-library.website', 'zh.z-lib.gd']));
    print('  默认候选 %d 个: ${CmbokConstants.zLibraryDefaultDomains}'
        .replaceAll('CmbokConstants.zLibraryDefaultDomains', ''));
  });

  test('🔴 真的去发请求前，候选列表与域名必须已经有值', () async {
    // 只构造，不 await init（模拟 MePage / BookSearchPage 第一次拿到单例）
    final z = ZlibraryService();

    // ⚠️ 这两条就是原 bug 的核心：它们原来都是空的
    expect(z.candidates, isNotEmpty,
        reason: '候选列表为空 → _candidateOrder() 为空 → '
            '内层 for 一次都不进 → 直接判不可用');
    expect(z.domain, isNotEmpty,
        reason: '域名为空 → 请求 URL 会是 https:///eapi/... → 必然失败');

    print('  构造后立即: domain=${z.domain}');
    print('  candidates(${z.candidates.length})=${z.candidates}');
  });

  test('🔴 域名必须不含 scheme / 路径（_send 会自己拼 https://）', () async {
    final z = ZlibraryService();
    expect(z.domain.startsWith('http'), isFalse,
        reason: '域名不能带 scheme，否则拼出来是 https://https://...');
    expect(z.domain.contains('/'), isFalse, reason: '域名不能带路径');
    for (final c in z.candidates) {
      expect(c.contains('/'), isFalse, reason: '候选 $c 带了路径');
    }
  });
}
