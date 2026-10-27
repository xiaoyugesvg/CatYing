import 'package:flutter/material.dart';

/// 桌宠物种元数据。
///
/// 2026-10-27 用户：「我只要这 3 个，其余全部去掉，也不要服装系统了」。
///   · 桌宠图鉴只留**熊猫 / 少年 / 少女**三只，形象用用户自己给的插画
///     （`assets/avatars_pets/chibi/*.png`，已离线抠好透明背景）；
///   · 之前的六只「圆团」动物 + 三只 QQ 秀企鹅 + 一整套换装系统全部删除；
///   · 十二生肖插画仍然保留，但**只作为登录头像**（不在图鉴里）。
class PetSpeciesInfo {
  const PetSpeciesInfo({
    required this.id,
    required this.name,
    required this.element,
    required this.description,
    required this.palette,
    this.imageAsset,
    this.avatarAlign = Alignment.bottomCenter,
    this.rare = false,
    this.legendary = false,
    this.unlockLevel = 1,
    this.price = 200,
  });

  final String id;
  final String name;
  final String element;
  final String description;

  /// 主色 / 浅色 / 点缀色（卡片底色、气泡色用）
  final List<Color> palette;

  /// 形象图。桌宠用的是**透明背景 PNG**；生肖插画是白底 JPG（只做头像）。
  final String? imageAsset;

  /// 圆形头像裁切时的对齐方式：全身立绘取「头」（topCenter），
  /// 生肖那种方图取「本体」（bottomCenter）。
  final Alignment avatarAlign;
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

/// 动作表情（用户 2026-10-27：「扩展 开心 / 生气 / 疑惑 / 打招呼 / 谢谢 / 晚安
/// 这一类动作表情」）。
///
/// 形象是一张静态插画，脸上改不了表情，所以用「**动作 + 气泡**」表达：
/// 每种心情给一套专属的位移/旋转节奏（`motionOf`），再飘一个 emoji 气泡。
/// 这样三只形象共用同一套动画，加新表情只要加一个枚举值 + 一行参数。
enum PetMood {
  happy('开心', '😄'),
  angry('生气', '😤'),
  puzzled('疑惑', '🤔'),
  greet('打招呼', '👋'),
  thanks('谢谢', '🙏'),
  night('晚安', '🌙');

  const PetMood(this.label, this.emoji);

  /// 中文名（动作面板上的按钮文字）
  final String label;

  /// 气泡里的 emoji
  final String emoji;

  /// 动作参数：上下浮 / 左右晃 / 摆动幅度 / 节奏（次/秒）/ 缩放脉冲
  ({double dy, double dx, double rot, double hz, double pulse}) get motion {
    switch (this) {
      case PetMood.happy:
        // 蹦蹦跳跳：只往上弹，频率快，带一点挤压回弹
        return (dy: -5.0, dx: 0, rot: 0, hz: 1.7, pulse: 0.035);
      case PetMood.angry:
        // 气鼓鼓：高频小幅左右抖，横向挤压
        return (dy: 0.6, dx: 2.4, rot: 0, hz: 7.5, pulse: -0.02);
      case PetMood.puzzled:
        // 疑惑：慢慢歪头
        return (dy: 0, dx: 0, rot: 0.10, hz: 0.45, pulse: 0);
      case PetMood.greet:
        // 打招呼：左右摆手
        return (dy: -1.2, dx: 0, rot: 0.14, hz: 1.9, pulse: 0.012);
      case PetMood.thanks:
        // 道谢：低头点一下（往下沉 + 微微前倾）
        return (dy: 3.2, dx: 0, rot: -0.07, hz: 0.9, pulse: -0.015);
      case PetMood.night:
        // 晚安：慢慢飘，幅度小
        return (dy: -2.2, dx: 0, rot: 0.03, hz: 0.35, pulse: 0.008);
    }
  }
}

class PetSpecies {
  PetSpecies._();

  // ── 桌宠图鉴（用户 2026-10-27：只要这三只）──────────────────
  //
  // 形象来自用户给的扁平矢量 Q 版插画，二头身、头占整体 2/3。
  // 素材已离线抠好：背景全透明，只留角色本体（连"门框"那类装饰都不要），
  // App 里直接 `Image.asset` 画，不再做运行时去背景。

  static const chibiPanda = PetSpeciesInfo(
    id: 'chibi_panda',
    name: '熊猫',
    element: '墨',
    description: '米白脑袋配两个大黑眼圈，看你翻页的时候腮红会变深。',
    palette: [Color(0xFFF8F8F8), Color(0xFFFFFFFF), Color(0xFF2B2B2B)],
    imageAsset: 'assets/avatars_pets/chibi/panda.png',
    avatarAlign: Alignment.topCenter,
    unlockLevel: 1,
    price: 0,
  );
  static const chibiBoy = PetSpeciesInfo(
    id: 'chibi_boy',
    name: '少年',
    element: '青',
    description: '利落短发配蓝灰卫衣，安安静静站在旁边陪你读。',
    palette: [Color(0xFFFDE8DA), Color(0xFFFFF6F0), Color(0xFFA9B7C4)],
    imageAsset: 'assets/avatars_pets/chibi/boy.png',
    avatarAlign: Alignment.topCenter,
    unlockLevel: 1,
    price: 0,
  );
  static const chibiGirl = PetSpeciesInfo(
    id: 'chibi_girl',
    name: '少女',
    element: '樱',
    description: '柔和中短发、浅色开衫，眼睛圆圆的，笑起来很软。',
    palette: [Color(0xFFFDE8DA), Color(0xFFFFF6F0), Color(0xFFEFDCD6)],
    imageAsset: 'assets/avatars_pets/chibi/girl.png',
    avatarAlign: Alignment.topCenter,
    unlockLevel: 1,
    price: 0,
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
  /// 图片路径存在 `PetService.customPetPath`。
  static const custom = PetSpeciesInfo(
    id: 'custom',
    name: '自定义',
    element: '我的',
    description: '你自己上传的 PNG / GIF 桌宠。',
    palette: [Color(0xFF8D6E63), Color(0xFFF5F0E6), Color(0xFF5D4037)],
    price: 0,
  );

  /// 桌宠图鉴 = **只有这三只**（用户 2026-10-27）。
  static const List<PetSpeciesInfo> pets = [chibiPanda, chibiBoy, chibiGirl];

  /// 全部物种（含**只用于登录头像**的生肖插画），byId 用。
  static const List<PetSpeciesInfo> all = [
    chibiPanda,
    chibiBoy,
    chibiGirl,
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

  /// 存档里可能还留着已删除物种的 id（`blob_cat` / `qq_boy` 之类），
  /// 找不到就回落到第一只 —— 不然用户会看到一只空白宠物。
  static PetSpeciesInfo byId(String id) {
    if (id == custom.id) return custom;
    for (final e in all) {
      if (e.id == id) return e;
    }
    return pets.first;
  }
}
