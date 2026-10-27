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
    this.animal,
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

  /// 「纯圆团」桌宠的动物形态（用户 2026-10-27）。
  ///
  /// 非空即表示这只走 `BlobPetPainter` 的圆团画笔，取值决定装饰：
  ///   `penguin` / `cat` / `dog` / `rabbit` / `bear` / `fox`
  /// 六个物种共用同一套版型（一颗圆团当身子兼脸），只换耳朵/口鼻/尾巴，
  /// 所以加新动物只要加一个取值 + 一段装饰绘制。
  final String? animal;

  /// 是否走圆团画笔（老的三只企鹅用 [qq] 标记，圆团新物种用 [animal]）
  bool get isBlob => qq || animal != null;

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

  // ── 二头身 Q 版（用户 2026-10-27）──────────────────────────
  //
  // 与上面六只「一颗圆团当身子兼脸」不同，这三只是**大脑袋 + 小身子**：
  // 头占整体 2/3、脑袋比身子大一圈、四肢短圆，画法见 `blob_pet_chibi.dart`。
  // 用户给的配色/造型规格：熊猫 米白 #F8F8F8 + 纯黑 #000000 + 腮红 #FFC8D0，
  // 半圆黑耳、大圆角黑眼圈（不是正圆）、短粗黑爪子；少年少女是低饱和穿搭，
  // 全部**无描边、纯色块、无渐变**。

  static const blobPanda = PetSpeciesInfo(
    id: 'blob_panda',
    name: '熊猫团',
    element: '墨',
    description: '米白脑袋配两个大黑眼圈，扒着门框偷偷看你翻到第几页。',
    palette: [Color(0xFFF8F8F8), Color(0xFFFFFFFF), Color(0xFF2B2B2B)],
    animal: 'panda',
    unlockLevel: 1,
    price: 0,
  );
  static const blobBoy = PetSpeciesInfo(
    id: 'blob_boy',
    name: '少年团',
    element: '青',
    description: '利落短发配蓝灰上衣，安安静静站在旁边陪你读。',
    palette: [Color(0xFFFDE8DA), Color(0xFFFFF6F0), Color(0xFFA9B7C4)],
    animal: 'boy',
    unlockLevel: 1,
    price: 0,
  );
  static const blobGirl = PetSpeciesInfo(
    id: 'blob_girl',
    name: '少女团',
    element: '樱',
    description: '柔和中短发、浅色穿搭，眼睛圆圆的，笑起来很软。',
    palette: [Color(0xFFFDE8DA), Color(0xFFFFF6F0), Color(0xFFEFDCD6)],
    animal: 'girl',
    unlockLevel: 1,
    price: 0,
  );

  // ── 纯圆团桌宠（用户 2026-10-27：「6 个形象走纯圆团风格，换不同动物」）──
  //
  // 六只共用同一套版型：**一颗圆团当身子兼脸** + 小短手 + 短脚，
  // 物种差异只在耳朵 / 口鼻 / 尾巴（见 `BlobPetPainter` 里按 `animal` 分支）。
  // 这样版型统一、辨识度靠装饰拉开，小尺寸下也不会糊成一团。

  static const blobPenguin = PetSpeciesInfo(
    id: 'blob_penguin',
    name: '团团',
    element: '风',
    description: '圆滚滚的读书企鹅，围巾一年四季都系着。',
    palette: [Color(0xFF5C8DFF), Color(0xFFF2F6FF), Color(0xFF2C3E66)],
    animal: 'penguin',
    unlockLevel: 1,
    price: 0,
  );
  static const blobCat = PetSpeciesInfo(
    id: 'blob_cat',
    name: '喵团',
    element: '金',
    description: '橘色圆团，最爱把尾巴搭在你的书页边上。',
    palette: [Color(0xFFF2A65A), Color(0xFFFFE8D2), Color(0xFFC97B3C)],
    animal: 'cat',
    unlockLevel: 1,
    price: 200,
  );
  static const blobDog = PetSpeciesInfo(
    id: 'blob_dog',
    name: '汪团',
    element: '土',
    description: '垂耳圆团，你一翻页它就摇尾巴。',
    palette: [Color(0xFFD9A05B), Color(0xFFF7E7CE), Color(0xFFB07A3F)],
    animal: 'dog',
    unlockLevel: 2,
    price: 220,
  );
  static const blobRabbit = PetSpeciesInfo(
    id: 'blob_rabbit',
    name: '兔团',
    element: '月',
    description: '长耳朵圆团，安静地陪你读到很晚。',
    palette: [Color(0xFFE8E2EC), Color(0xFFFBF7FF), Color(0xFFB9AEC4)],
    animal: 'rabbit',
    unlockLevel: 2,
    price: 240,
  );
  static const blobBear = PetSpeciesInfo(
    id: 'blob_bear',
    name: '熊团',
    element: '木',
    description: '小圆耳的大团子，抱着书就睡着。',
    palette: [Color(0xFFB08050), Color(0xFFF0DCC2), Color(0xFF8A5F33)],
    animal: 'bear',
    rare: true,
    unlockLevel: 3,
    price: 280,
  );
  static const blobFox = PetSpeciesInfo(
    id: 'blob_fox',
    name: '狐团',
    element: '火',
    description: '大尾巴圆团，白颊上总挂着一点小得意。',
    palette: [Color(0xFFE8763C), Color(0xFFFFE9D6), Color(0xFFC8552A)],
    animal: 'fox',
    rare: true,
    unlockLevel: 4,
    price: 320,
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

  /// 桌宠图鉴（用户 2026-10-27）。
  ///
  /// 前 3 只是**二头身 Q 版**（熊猫 / 少年 / 少女，用户 2026-10-27 追加，
  /// 要求「放在前面」），后 6 只是纯圆团动物。
  /// 老的三只 QQ 秀企鹅（[qqBoy]/[qqGirl]/[qqScholar]）**仍留在 [all] 里**，
  /// 只是为了「用户已选中的 id 还能解析出来」——不再进图鉴。
  /// 它们现在也会被圆团画笔按 `penguin` 形态绘制，视觉与新版一致。
  static const List<PetSpeciesInfo> pets = [
    blobPanda,
    blobBoy,
    blobGirl,
    blobPenguin,
    blobCat,
    blobDog,
    blobRabbit,
    blobBear,
    blobFox,
  ];

  /// 全部物种（含**只用于登录头像**的生肖插画），byId 用。
  static const List<PetSpeciesInfo> all = [
    blobPanda,
    blobBoy,
    blobGirl,
    blobPenguin,
    blobCat,
    blobDog,
    blobRabbit,
    blobBear,
    blobFox,
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

/// 换装部位（2026-10-27 收敛成三类）。
///
/// 用户：「不要什么服装系统了，就弄各种节日头饰、眼镜和衣服吧，这个要贴合呀」。
///
/// 旧的六部位（头饰 / 面部 / 颈饰 / 上衣 / 手持 / 背景）里，「手持」和
/// 「背景」是**飘在身体外面**的独立物件，圆团宠物穿上就是"贴纸糊上去"，
/// 跟「贴合」完全相反，全部砍掉；剩下的按圆团的三段几何归成三类：
///   头饰 → 团子上沿；眼镜 → 眼睛那条线；衣服 → 团子下半身。
///
/// ⚠️ 枚举 `name` 会写进存档（`equippedSlots`），改名等于清空玩家的穿搭。
enum PetOutfitSlot {
  hat('节日头饰'),
  glasses('眼镜'),
  clothes('衣服');

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

  // ── 节日头饰（贴着团子上沿）────────────────────────────────
  static const lionHat = PetOutfitInfo(
    id: 'lion_hat',
    name: '狮头帽',
    slot: PetOutfitSlot.hat,
    price: 120,
  );
  static const moonCrown = PetOutfitInfo(
    id: 'moon_crown',
    name: '月桂冠',
    slot: PetOutfitSlot.hat,
    price: 160,
    unlockLevel: 2,
  );
  static const pumpkinHat = PetOutfitInfo(
    id: 'pumpkin_hat',
    name: '南瓜帽',
    slot: PetOutfitSlot.hat,
    price: 180,
  );
  static const santaHat = PetOutfitInfo(
    id: 'santa_hat',
    name: '圣诞帽',
    slot: PetOutfitSlot.hat,
    price: 200,
    unlockLevel: 2,
  );
  static const leafHat = PetOutfitInfo(
    id: 'leaf_hat',
    name: '粽叶斗笠',
    slot: PetOutfitSlot.hat,
    price: 240,
    unlockLevel: 3,
  );

  // ── 眼镜（镜片对齐眼睛坐标）────────────────────────────────
  static const roundGlasses = PetOutfitInfo(
    id: 'round_glasses',
    name: '圆框眼镜',
    slot: PetOutfitSlot.glasses,
    price: 80,
  );
  static const shades = PetOutfitInfo(
    id: 'shades',
    name: '墨镜',
    slot: PetOutfitSlot.glasses,
    price: 140,
  );
  static const starGlasses = PetOutfitInfo(
    id: 'star_glasses',
    name: '星星镜',
    slot: PetOutfitSlot.glasses,
    price: 200,
    unlockLevel: 2,
  );
  static const heartGlasses = PetOutfitInfo(
    id: 'heart_glasses',
    name: '爱心镜',
    slot: PetOutfitSlot.glasses,
    price: 260,
    unlockLevel: 3,
  );

  // ── 衣服（贴着团子下半身）──────────────────────────────────
  static const tangSuit = PetOutfitInfo(
    id: 'tang_suit',
    name: '唐装马甲',
    slot: PetOutfitSlot.clothes,
    price: 120,
  );
  static const sweater = PetOutfitInfo(
    id: 'sweater',
    name: '圣诞毛衣',
    slot: PetOutfitSlot.clothes,
    price: 180,
    unlockLevel: 2,
  );
  static const poncho = PetOutfitInfo(
    id: 'poncho',
    name: '南瓜斗篷',
    slot: PetOutfitSlot.clothes,
    price: 220,
  );
  static const hanfu = PetOutfitInfo(
    id: 'hanfu',
    name: '汉服襦裙',
    slot: PetOutfitSlot.clothes,
    price: 280,
    unlockLevel: 3,
  );
  static const overalls = PetOutfitInfo(
    id: 'overalls',
    name: '背带裤',
    slot: PetOutfitSlot.clothes,
    price: 320,
    unlockLevel: 4,
  );

  static const List<PetOutfitInfo> all = [
    lionHat,
    moonCrown,
    pumpkinHat,
    santaHat,
    leafHat,
    roundGlasses,
    shades,
    starGlasses,
    heartGlasses,
    tangSuit,
    sweater,
    poncho,
    hanfu,
    overalls,
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
