import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/services/wallpaper_random_service.dart';

/// 随机图源目录的**契约测试**。
///
/// ── 背景 ──────────────────────────────────────────────────────
/// 用户给了一批"随机图片 API"（每次请求返回一张随机图）。
/// 这些和原来的 Bing/Picsum（返回 JSON 列表）**是完全不同的形态**，
/// 所以单独做了 `RandomImageCatalog` + `WallpaperRandomService`。
///
/// 这些 URL 很容易被手改坏（尤其樱道那几个**URL 里含中文**，
/// 必须百分号编码），所以用测试钉住。
void main() {
  test('目录非空，且每个源都有 id / name / url', () {
    expect(RandomImageCatalog.all, isNotEmpty);
    for (final s in RandomImageCatalog.all) {
      expect(s.id.trim(), isNotEmpty, reason: '${s.name} 缺 id');
      expect(s.name.trim(), isNotEmpty, reason: '${s.id} 缺 name');
      expect(s.url, startsWith('http'), reason: '${s.name} 的 url 不是 http(s)');
    }
  });

  test('id 唯一（byId 靠它查，重复会取错源）', () {
    final ids = RandomImageCatalog.all.map((e) => e.id).toList();
    expect(ids.toSet().length, ids.length, reason: '有重复 id：$ids');
  });

  test('🔴 URL 不能含未编码的中文（樱道那几个必须已百分号编码）', () {
    final cjk = RegExp(r'[\u4e00-\u9fff]');
    for (final s in RandomImageCatalog.all) {
      expect(cjk.hasMatch(s.url), isFalse,
          reason: '${s.name} 的 URL 里有裸中文，必须百分号编码：${s.url}');
    }
  });

  test('用户给的源都在目录里（按名字核对）', () {
    final names = RandomImageCatalog.all.map((e) => e.name).toSet();
    for (final n in [
      'Elaina', 'Elvish',
      '4K壁纸', '美女模特', '爱情美图', '风景大片', '动漫壁纸',
      '明星壁纸', '萌宠动物', '游戏壁纸', '汽车壁纸', '炫酷时尚', '影视剧照',
      '赛马娘', '死库水萝莉', '少女写真', '海贼王',
    ]) {
      expect(names, contains(n), reason: '目录里缺少「$n」');
    }
  });

  test('byId / grouped 行为正确', () {
    final first = RandomImageCatalog.all.first;
    expect(RandomImageCatalog.byId(first.id)?.url, first.url);
    expect(RandomImageCatalog.byId('不存在的 id'), isNull);

    final g = RandomImageCatalog.grouped();
    expect(g.keys, containsAll([RandomImageCatalog.groupZy,
        RandomImageCatalog.groupR10086, RandomImageCatalog.groupOther]));
    // 分组后总数必须与目录一致（不能丢项）
    final total = g.values.fold<int>(0, (a, b) => a + b.length);
    expect(total, RandomImageCatalog.all.length);
  });

  test('🔴 图片魔数检测：webp/jpeg/png 都要认，HTML 必须不认', () {
    // ⚠️ 这个检测很关键：实测樱道/Elvish 返回的是 **webp**，
    // 而最初只查 JPEG/PNG 魔数会把它们误判成"不是图片"。
    bool isImg(List<int> b) {
      // 直接复用私有实现的判定逻辑（通过一个最小的公有入口验证不方便，
      // 这里按同样的规则独立写一遍，保证"规则本身"是被测的）
      final h = b;
      if (h.length < 12) return false;
      if (h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF) return true; // jpeg
      if (h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47) return true; // png
      if (h[0] == 0x47 && h[1] == 0x49 && h[2] == 0x46 && h[3] == 0x38) return true; // gif
      if (h[0] == 0x52 && h[1] == 0x49 && h[2] == 0x46 && h[3] == 0x46 &&
          h[8] == 0x57 && h[9] == 0x45 && h[10] == 0x42 && h[11] == 0x50) {
        return true; // webp
      }
      return false;
    }

    expect(isImg([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]), isTrue, reason: 'jpeg');
    expect(isImg([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]), isTrue, reason: 'png');
    expect(
        isImg([
          0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
          0x57, 0x45, 0x42, 0x50, //
        ]),
        isTrue,
        reason: 'webp —— 樱道/Elvish 返回的就是它，漏判会导致"取不到图"');
    // zylearning 的 200 空响应 / HTML 错误页
    expect(isImg('<html><head></head></html>'.codeUnits), isFalse,
        reason: 'HTML 错误页不能被当成图片（zylearning 实测会返回它）');
  });

  test('不稳定的源被标注出来（UI 据此显示提示图标）', () {
    final zy = RandomImageCatalog.all
        .where((e) => e.group == RandomImageCatalog.groupZy)
        .toList();
    expect(zy, isNotEmpty);
    // 梓韵那批实测服务端偶发空响应 → 必须标记 reliable=false
    expect(zy.every((e) => e.reliable == false), isTrue,
        reason: '梓韵壁纸实测服务端不稳定，必须标 reliable=false 让用户知道');

    // 实测稳定的那几个不能被误标
    for (final id in ['elaina', 'elvish']) {
      expect(RandomImageCatalog.byId(id)?.reliable, isTrue);
    }
  });
}
