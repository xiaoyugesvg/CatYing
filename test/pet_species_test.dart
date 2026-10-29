import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/reading/pet/pet_models.dart';

void main() {
  group('桌宠 / 头像物种', () {
    // ── 2026-10-29 更新（对齐 aaa9588「桌宠只留熊猫/少年/少女」）─────
    // 用户 2026-10-27 决定：桌宠图鉴**只要这三只**（熊猫 / 少年 / 少女），
    // 原来的 QQ 秀三款（qq_boy / qq_girl / qq_scholar）已随该提交移除，
    // 十二生肖插画只保留为**登录头像**（不进 pets 图鉴）。
    // 本用例原来还在断言 qq_* 与"插画 10 款"，属于测试没跟上产品变更。
    test('桌宠图鉴只有三只：熊猫 / 少年 / 少女', () {
      expect(
        PetSpecies.pets.map((e) => e.id).toList(),
        ['chibi_panda', 'chibi_boy', 'chibi_girl'],
      );
      expect(PetSpecies.pets.map((e) => e.name).toList(), ['熊猫', '少年', '少女']);
    });

    test('必须包含十二生肖与猫（登录头像素材）', () {
      final ids = PetSpecies.all.map((e) => e.id).toSet();
      for (final id in [
        // 十二生肖（保留为登录头像素材）
        'rat',
        'ox',
        'tiger',
        'rabbit',
        'dragon',
        'snake',
        'horse',
        'goat',
        'monkey',
        'rooster',
        'dog',
        'pig',
        // 猫（历史默认物种，仍在使用）
        'cat',
      ]) {
        expect(ids.contains(id), isTrue, reason: '缺少物种 $id');
      }
    });

    test('id 唯一，且每个物种三色调色板完整', () {
      final ids = <String>{};
      for (final s in PetSpecies.all) {
        expect(ids.add(s.id), isTrue, reason: '重复 id: ${s.id}');
        expect(s.palette.length, 3);
        expect(s.name.isNotEmpty, isTrue);
      }
    });

    // 2026-10-29 更新：兜底物种 = 图鉴第一只（熊猫 chibi_panda）。
    // 依据 pet_models.dart 的 `byId(...) => pets.first`，以及
    // `pet_service.dart` 里把旧 id 迁到第一只的存档迁移。
    test('byId 未命中时回退到默认桌宠（熊猫）', () {
      expect(PetSpecies.byId('not-exist').id, 'chibi_panda');
      // 存档里可能留着已删除物种的 id（QQ 秀三款 / blob_cat 之类）→ 同样回落
      expect(PetSpecies.byId('qq_boy').id, 'chibi_panda');
      expect(PetSpecies.byId('chibi_girl').name, '少女');
      // 自定义桌宠不走图鉴，单独命中
      expect(PetSpecies.byId('custom').id, 'custom');
    });

    test('内置插画 13 款且素材文件真实存在', () {
      final withImage =
          PetSpecies.all.where((e) => e.imageAsset != null).toList();
      expect(withImage.length, 13,
          reason: '3 张 Q 版桌宠 + 10 张生肖插画（猫 / 牛 / 蛇 无插画）');
      for (final s in withImage) {
        final f = File(s.imageAsset!);
        expect(f.existsSync(), isTrue, reason: '缺少素材 ${s.imageAsset}');
        expect(f.lengthSync(), greaterThan(1024), reason: '素材不应为空');
      }
      expect(PetSpecies.byId('rat').imageAsset, 'assets/avatars_pets/rat.jpg');
      expect(PetSpecies.byId('dragon').imageAsset,
          'assets/avatars_pets/dragon.jpg');
      expect(PetSpecies.byId('chibi_panda').imageAsset,
          'assets/avatars_pets/chibi/panda.png');
    });
  });
}
