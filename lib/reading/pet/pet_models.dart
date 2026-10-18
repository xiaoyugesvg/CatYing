import 'package:flutter/material.dart';

/// 桌宠物种元数据（十二生肖 + 猫 / 麒麟 / 凤凰）。
class PetSpeciesInfo {
  const PetSpeciesInfo({
    required this.id,
    required this.name,
    required this.element,
    required this.description,
    required this.palette,
    this.imageAsset,
    this.rare = false,
    this.legendary = false,
    this.unlockLevel = 1,
    this.price = 200,
  });

  final String id;
  final String name;
  final String element;
  final String description;

  /// 主色 / 浅色 / 点缀色
  final List<Color> palette;

  /// 用户提供的生肖插画（`assets/avatars_pets/<id>.jpg`）。
  /// 有图时头像/桌宠优先用图片皮肤；为 null 时回退矢量团子。
  final String? imageAsset;
  final bool rare;
  final bool legendary;
  final int unlockLevel;
  final int price;

  String get rarity {
    if (legendary) return '传说';
    if (rare) return '稀有';
    return '普通';
  }
}

class PetSpecies {
  PetSpecies._();

  static const cat = PetSpeciesInfo(
    id: 'cat',
    name: '喵酱',
    element: '金',
    description: '爱趴在书页上的小猫咪，读完一章就蹭蹭你。',
    palette: [Color(0xFFF2A65A), Color(0xFFFFE0B2), Color(0xFF8D5524)],
    unlockLevel: 1,
    price: 0,
  );
  static const dog = PetSpeciesInfo(
    id: 'dog',
    name: '阿汪',
    element: '土',
    description: '最忠诚的读书搭子，看到你打开书就摇尾巴。',
    palette: [Color(0xFFC98B5B), Color(0xFFF3D6B5), Color(0xFF6D4C41)],
    imageAsset: 'assets/avatars_pets/dog.jpg',
    unlockLevel: 1,
    price: 0,
  );
  static const rat = PetSpeciesInfo(
    id: 'rat',
    name: '小鼠',
    element: '水',
    description: '机灵的藏书鼠，总能在书缝里找到好吃的。',
    palette: [Color(0xFFB0BEC5), Color(0xFFECEFF1), Color(0xFF78909C)],
    imageAsset: 'assets/avatars_pets/rat.jpg',
    unlockLevel: 2,
    price: 200,
  );
  static const ox = PetSpeciesInfo(
    id: 'ox',
    name: '铁牛',
    element: '土',
    description: '踏实稳重，陪你一页一页把厚书啃完。',
    palette: [Color(0xFF8D6E63), Color(0xFFD7CCC8), Color(0xFF5D4037)],
    unlockLevel: 3,
    price: 260,
  );
  static const tiger = PetSpeciesInfo(
    id: 'tiger',
    name: '小虎',
    element: '木',
    description: '看着凶，其实最喜欢被摸头。',
    palette: [Color(0xFFF2A03D), Color(0xFFFFE0B2), Color(0xFF3E2723)],
    imageAsset: 'assets/avatars_pets/tiger.jpg',
    rare: true,
    unlockLevel: 5,
    price: 520,
  );
  static const rabbit = PetSpeciesInfo(
    id: 'rabbit',
    name: '月兔',
    element: '木',
    description: '耳朵会跟着书页翻动的节奏一晃一晃。',
    palette: [Color(0xFFF5F5F5), Color(0xFFFFFFFF), Color(0xFFF8BBD0)],
    imageAsset: 'assets/avatars_pets/rabbit.jpg',
    unlockLevel: 2,
    price: 220,
  );
  static const dragon = PetSpeciesInfo(
    id: 'dragon',
    name: '苍龙',
    element: '金',
    description: '书山有路它为径，传说中的守书神兽。',
    palette: [Color(0xFF66BB6A), Color(0xFFC8E6C9), Color(0xFFFFD54F)],
    imageAsset: 'assets/avatars_pets/dragon.jpg',
    rare: true,
    legendary: true,
    unlockLevel: 8,
    price: 1200,
  );
  static const snake = PetSpeciesInfo(
    id: 'snake',
    name: '青蛇',
    element: '火',
    description: '安静地盘在书角，偶尔吐吐信子。',
    palette: [Color(0xFF4DB6AC), Color(0xFFB2DFDB), Color(0xFF00695C)],
    rare: true,
    unlockLevel: 4,
    price: 420,
  );
  static const horse = PetSpeciesInfo(
    id: 'horse',
    name: '追风',
    element: '火',
    description: '翻页最快的马，鬃毛像风一样。',
    palette: [Color(0xFFA1887F), Color(0xFFE0D5CE), Color(0xFF4E342E)],
    imageAsset: 'assets/avatars_pets/horse.jpg',
    rare: true,
    unlockLevel: 5,
    price: 480,
  );
  static const goat = PetSpeciesInfo(
    id: 'goat',
    name: '云羊',
    element: '土',
    description: '毛茸茸一团云，困了会靠着你打盹。',
    palette: [Color(0xFFECEFF1), Color(0xFFFFFFFF), Color(0xFF90A4AE)],
    imageAsset: 'assets/avatars_pets/goat.jpg',
    unlockLevel: 3,
    price: 260,
  );
  static const monkey = PetSpeciesInfo(
    id: 'monkey',
    name: '小悟',
    element: '金',
    description: '上蹿下跳地帮你找下一本要读的书。',
    palette: [Color(0xFFD7A86E), Color(0xFFFFE0B2), Color(0xFF6D4C41)],
    imageAsset: 'assets/avatars_pets/monkey.jpg',
    rare: true,
    unlockLevel: 4,
    price: 400,
  );
  static const rooster = PetSpeciesInfo(
    id: 'rooster',
    name: '司晨',
    element: '金',
    description: '每天准点叫你起床看书。',
    palette: [Color(0xFFEF9A9A), Color(0xFFFFE0B2), Color(0xFFC62828)],
    imageAsset: 'assets/avatars_pets/rooster.jpg',
    unlockLevel: 2,
    price: 200,
  );
  static const pig = PetSpeciesInfo(
    id: 'pig',
    name: '团团',
    element: '水',
    description: '吃饱了就睡，睡醒了继续陪你读。',
    palette: [Color(0xFFF8BBD0), Color(0xFFFCE4EC), Color(0xFFAD1457)],
    imageAsset: 'assets/avatars_pets/pig.jpg',
    unlockLevel: 2,
    price: 220,
  );
  static const qilin = PetSpeciesInfo(
    id: 'qilin',
    name: '麒麟',
    element: '土',
    description: '踏书而来的祥瑞，传说只在读完一本好书时现身。',
    palette: [Color(0xFFFFD54F), Color(0xFFFFF8E1), Color(0xFF8D6E63)],
    rare: true,
    legendary: true,
    unlockLevel: 9,
    price: 1500,
  );
  static const phoenix = PetSpeciesInfo(
    id: 'phoenix',
    name: '朱雀',
    element: '火',
    description: '浴火重生的书灵，尾羽像一页页燃起的纸。',
    palette: [Color(0xFFFF7043), Color(0xFFFFCCBC), Color(0xFFD84315)],
    rare: true,
    legendary: true,
    unlockLevel: 10,
    price: 1800,
  );
  static const whiteTiger = PetSpeciesInfo(
    id: 'white_tiger',
    name: '白虎',
    element: '金',
    description: '西方守护神兽，看着凶，其实只想趴在你书边打盹。',
    palette: [Color(0xFFF3F1EC), Color(0xFFFFFFFF), Color(0xFF546E7A)],
    rare: true,
    legendary: true,
    unlockLevel: 8,
    price: 1400,
  );
  static const xuanwu = PetSpeciesInfo(
    id: 'xuanwu',
    name: '玄武',
    element: '水',
    description: '背着一整座书库的龟，慢，但从不丢页。',
    palette: [Color(0xFF607D8B), Color(0xFFCFD8DC), Color(0xFF2E3B42)],
    rare: true,
    legendary: true,
    unlockLevel: 9,
    price: 1500,
  );
  static const fenghuang = PetSpeciesInfo(
    id: 'fenghuang',
    name: '凤凰',
    element: '火',
    description: '百鸟之王，尾羽一展就是一片晚霞。',
    palette: [Color(0xFFFFB300), Color(0xFFFFF3E0), Color(0xFFE65100)],
    rare: true,
    legendary: true,
    unlockLevel: 10,
    price: 1800,
  );

  /// 自定义桌宠（用户 2026-10-18）：PNG / GIF 由用户自己上传。
  ///
  /// 不属于图鉴（不在 [all] 里），只作为「当前皮肤」使用；
  /// 图片路径存在 [PetService.customPetPath]。
  static const custom = PetSpeciesInfo(
    id: 'custom',
    name: '自定义',
    element: '我的',
    description: '你自己上传的 PNG / GIF 桌宠。',
    palette: [Color(0xFF8D6E63), Color(0xFFF5F0E6), Color(0xFF5D4037)],
    price: 0,
  );

  static const List<PetSpeciesInfo> all = [
    cat,
    dog,
    rat,
    ox,
    tiger,
    rabbit,
    dragon,
    snake,
    horse,
    goat,
    monkey,
    rooster,
    pig,
    qilin,
    phoenix,
    whiteTiger,
    xuanwu,
    fenghuang,
  ];

  static PetSpeciesInfo byId(String id) => id == custom.id
      ? custom
      : all.firstWhere((e) => e.id == id, orElse: () => cat);
}

class PetOutfitInfo {
  const PetOutfitInfo({
    required this.id,
    required this.name,
    required this.price,
    this.unlockLevel = 1,
  });

  final String id;
  final String name;
  final int price;
  final int unlockLevel;
}

class PetOutfits {
  PetOutfits._();

  static const none = PetOutfitInfo(id: 'none', name: '不戴', price: 0);
  static const hat = PetOutfitInfo(id: 'hat', name: '小礼帽', price: 80);
  static const scarf = PetOutfitInfo(id: 'scarf', name: '围巾', price: 100);
  static const glasses = PetOutfitInfo(id: 'glasses', name: '圆框眼镜', price: 120);
  static const crown = PetOutfitInfo(
    id: 'crown',
    name: '小皇冠',
    price: 300,
    unlockLevel: 4,
  );
  static const bow = PetOutfitInfo(id: 'bow', name: '蝴蝶结', price: 60);

  static const List<PetOutfitInfo> all = [none, bow, hat, scarf, glasses, crown];
}
