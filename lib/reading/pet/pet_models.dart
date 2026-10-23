import 'package:flutter/material.dart';

/// 桌宠物种元数据。
///
/// 用户 2026-10-18：
///   · 桌宠改成 **QQ 秀风格**（小Q / 小秀 / 书呆），不再用生肖、龙、麒麟这些；
///   · 十二生肖插画**只保留为登录头像**（`avatarOnly`，不出现在宠物图鉴）。
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
    this.qq = false,
  });

  final String id;
  final String name;
  final String element;
  final String description;

  /// 主色 / 浅色 / 点缀色
  final List<Color> palette;

  /// 用户提供的生肖插画（`assets/avatars_pets/<id>.jpg`）。
  /// **只用于登录头像**；桌宠不再使用这些图片（用户 2026-10-18）。
  final String? imageAsset;
  final bool rare;
  final bool legendary;
  final int unlockLevel;
  final int price;

  /// QQ 秀风格的人形桌宠（矢量绘制，可换装）。
  final bool qq;

  String get rarity {
    if (legendary) return '传说';
    if (rare) return '稀有';
    return '普通';
  }
}

class PetSpecies {
  PetSpecies._();

  // ── QQ 企鹅桌宠（拟人化，用户 2026-10-23）───────────────────
  static const qqBoy = PetSpeciesInfo(
    id: 'qq_boy',
    name: '小Q',
    element: '风',
    description: '围着红围巾的读书企鹅，衣柜里永远少一件卫衣。',
    palette: [Color(0xFF5C8DFF), Color(0xFFF2F6FF), Color(0xFF2C3E66)],
    unlockLevel: 1,
    price: 0,
    qq: true,
  );
  static const qqGirl = PetSpeciesInfo(
    id: 'qq_girl',
    name: '小秀',
    element: '花',
    description: '爱打扮的企鹅小姐，看书也要挑一支好看的书签。',
    palette: [Color(0xFFFF8FB1), Color(0xFFFFF3F7), Color(0xFF7A3B52)],
    unlockLevel: 1,
    price: 0,
    qq: true,
  );
  static const qqScholar = PetSpeciesInfo(
    id: 'qq_scholar',
    name: '书呆',
    element: '墨',
    description: '抱书不撒手的企鹅学霸，围巾都要系得一丝不苟。',
    palette: [Color(0xFF8D9B6A), Color(0xFFF4F6EC), Color(0xFF3E4A32)],
    unlockLevel: 3,
    price: 260,
    qq: true,
  );

  // ── 以下只作为**登录头像**候选（十二生肖插画），不进桌宠图鉴 ──
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

  /// 桌宠图鉴：只有 QQ 秀风格人形宠物（用户 2026-10-18）。
  static const List<PetSpeciesInfo> pets = [qqBoy, qqGirl, qqScholar];

  /// 全部物种（含**只用于登录头像**的生肖插画），byId 用。
  static const List<PetSpeciesInfo> all = [
    qqBoy,
    qqGirl,
    qqScholar,
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
  ];

  static PetSpeciesInfo byId(String id) => id == custom.id
      ? custom
      : all.firstWhere((e) => e.id == id, orElse: () => qqBoy);
}

/// 换装部位（QQ秀式多部位穿搭，用户 2026-10-18）
enum PetOutfitSlot {
  hat('头饰'),
  face('面部'),
  neck('颈部'),
  top('上衣'),
  hand('手持'),
  background('背景');

  const PetOutfitSlot(this.label);
  final String label;
}

class PetOutfitInfo {
  const PetOutfitInfo({
    required this.id,
    required this.name,
    required this.slot,
    required this.price,
    this.unlockLevel = 1,
  });

  final String id;
  final String name;
  final PetOutfitSlot slot;
  final int price;
  final int unlockLevel;
}

class PetOutfits {
  PetOutfits._();

  /// 旧版单件穿搭的「不戴」哨兵（保留用于存档迁移）
  static const none = PetOutfitInfo(
    id: 'none',
    name: '不戴',
    slot: PetOutfitSlot.hat,
    price: 0,
  );

  // ── 头饰 ────────────────────────────────────────────────────
  static const bow = PetOutfitInfo(
    id: 'bow',
    name: '蝴蝶结',
    slot: PetOutfitSlot.hat,
    price: 60,
  );
  static const hat = PetOutfitInfo(
    id: 'hat',
    name: '小礼帽',
    slot: PetOutfitSlot.hat,
    price: 80,
  );
  static const cap = PetOutfitInfo(
    id: 'cap',
    name: '鸭舌帽',
    slot: PetOutfitSlot.hat,
    price: 120,
  );
  static const crown = PetOutfitInfo(
    id: 'crown',
    name: '小皇冠',
    slot: PetOutfitSlot.hat,
    price: 300,
    unlockLevel: 4,
  );

  // ── 面部 ────────────────────────────────────────────────────
  static const glasses = PetOutfitInfo(
    id: 'glasses',
    name: '圆框眼镜',
    slot: PetOutfitSlot.face,
    price: 120,
  );
  static const shades = PetOutfitInfo(
    id: 'shades',
    name: '墨镜',
    slot: PetOutfitSlot.face,
    price: 180,
  );

  // ── 颈部 ────────────────────────────────────────────────────
  static const scarf = PetOutfitInfo(
    id: 'scarf',
    name: '围巾',
    slot: PetOutfitSlot.neck,
    price: 100,
  );
  static const tie = PetOutfitInfo(
    id: 'tie',
    name: '小领结',
    slot: PetOutfitSlot.neck,
    price: 140,
  );

  // ── 上衣 ────────────────────────────────────────────────────
  static const hoodie = PetOutfitInfo(
    id: 'hoodie',
    name: '连帽卫衣',
    slot: PetOutfitSlot.top,
    price: 260,
    unlockLevel: 2,
  );
  static const vest = PetOutfitInfo(
    id: 'vest',
    name: '小马甲',
    slot: PetOutfitSlot.top,
    price: 320,
    unlockLevel: 3,
  );

  // ── 手持 ────────────────────────────────────────────────────
  static const book = PetOutfitInfo(
    id: 'book',
    name: '一本书',
    slot: PetOutfitSlot.hand,
    price: 160,
  );
  static const coffee = PetOutfitInfo(
    id: 'coffee',
    name: '咖啡杯',
    slot: PetOutfitSlot.hand,
    price: 200,
  );
  static const balloon = PetOutfitInfo(
    id: 'balloon',
    name: '小气球',
    slot: PetOutfitSlot.hand,
    price: 220,
  );

  // ── 背景 ────────────────────────────────────────────────────
  static const moon = PetOutfitInfo(
    id: 'moon',
    name: '月光',
    slot: PetOutfitSlot.background,
    price: 240,
    unlockLevel: 2,
  );
  static const stars = PetOutfitInfo(
    id: 'stars',
    name: '星芒',
    slot: PetOutfitSlot.background,
    price: 280,
    unlockLevel: 3,
  );

  static const List<PetOutfitInfo> all = [
    bow,
    hat,
    cap,
    crown,
    glasses,
    shades,
    scarf,
    tie,
    hoodie,
    vest,
    book,
    coffee,
    balloon,
    moon,
    stars,
  ];

  static PetOutfitInfo? byId(String? id) {
    if (id == null || id.isEmpty || id == none.id) return null;
    for (final o in all) {
      if (o.id == id) return o;
    }
    return null;
  }

  static List<PetOutfitInfo> forSlot(PetOutfitSlot slot) =>
      all.where((e) => e.slot == slot).toList();
}
