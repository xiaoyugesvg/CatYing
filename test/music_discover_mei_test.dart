import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/music/pages/discover_playlists_page.dart';
import 'package:tvbox/music/widgets/mei_cards.dart';

/// 音乐发现页按 `ljyh223/Mei` 重构后的**规格回归**。
///
/// 用户 2026-10-30：「推荐、网易这些分页整个要重构，严格按照刚才这个仓库的
/// 界面来」。重构里最容易悄悄退化的三件事：
///   ① 分类表被换回"接口返回的分组名"（→ 点分类永远空）
///   ② 排序枚举的 wire 值和接口约定不一致（→ 排序按钮点了没反应）
///   ③ 播放量格式化和 Mei 不一致（→ 角标显示 `123456` 而不是 `12.3万`）
void main() {
  group('网易云分类表', () {
    test('🔴 必须含「全部」且排第一', () {
      final cats = neteaseDiscoverCats();
      expect(cats, isNotEmpty);
      expect(cats.first.key, '全部');
      expect(cats.first.label, '全部');
    });

    test('🔴 分类必须是**子分类名**，不能是「语种/风格」这类分组名', () {
      final cats = neteaseDiscoverCats();
      final keys = cats.map((c) => c.key).toSet();
      // 分组名出现在分类里 ⇒ 说明有人把 catalogue 接口的 categories 当分类用了
      for (final group in ['语种', '风格', '场景', '情感', '主题']) {
        expect(keys.contains(group), isFalse,
            reason: '「$group」是分组名，不是能拿去查歌单的分类');
      }
      // 真正能查的分类
      for (final name in ['华语', '欧美', '流行', '摇滚', '夜晚', '怀旧']) {
        expect(keys.contains(name), isTrue, reason: '缺少分类「$name」');
      }
    });

    test('🔴 每个分类都带分组（分类弹层要靠它分节）', () {
      final cats = neteaseDiscoverCats();
      final grouped = cats.where((c) => c.group.isNotEmpty).toList();
      expect(grouped.length, greaterThan(40));
      // 「全部」不属于任何分组
      expect(cats.first.group, isEmpty);
    });

    test('🔴 横滑条上的热门分类必须都在总表里', () {
      final keys = neteaseDiscoverCats().map((c) => c.key).toSet();
      expect(neteaseHotCats, isNotEmpty);
      for (final k in neteaseHotCats) {
        expect(keys.contains(k), isTrue, reason: '热门分类「$k」不在总表里，点了会查空');
      }
    });
  });

  group('排序枚举', () {
    test('wire 值与接口约定一致', () {
      expect(DiscoverOrder.recommended.wire, 'default');
      expect(DiscoverOrder.latest.wire, 'new');
      expect(DiscoverOrder.hottest.wire, 'hot');
    });

    test('默认排最热（和 Mei 的 DiscoverOrder 默认一致）', () {
      expect(DiscoverOrder.values.first, DiscoverOrder.recommended);
      expect(DiscoverOrder.values.length, 3);
    });
  });

  group('播放量格式化（对齐 Mei 的 formatDiscoverPlayCount）', () {
    test('≥1 亿 → x.x亿', () {
      expect(formatPlayCount(123456789), '1.2亿');
      expect(formatPlayCount(100000000), '1.0亿');
    });

    test('≥1 万 → x.x万', () {
      expect(formatPlayCount(123456), '12.3万');
      expect(formatPlayCount(10000), '1.0万');
    });

    test('小于 1 万原样；0 / 负数不出现负号', () {
      expect(formatPlayCount(9999), '9999');
      expect(formatPlayCount(0), '0');
      expect(formatPlayCount(-5), '0');
    });
  });

  group('分类选项模型', () {
    test('DiscoverCat 默认无分组', () {
      const c = DiscoverCat('全部', '全部');
      expect(c.group, isEmpty);
      expect(c.key, '全部');
      expect(c.label, '全部');
    });
  });
}
