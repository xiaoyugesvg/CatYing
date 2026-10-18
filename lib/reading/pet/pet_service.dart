import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/reading_checkin_service.dart';
import '../services/reading_time_service.dart';
import 'pet_models.dart';

/// 桌宠状态与成长系统。
///
/// 数值规则：
///   · 阅读 1 分钟 = 2 经验；每 10 分钟额外 1 书币
///   · 每日打卡 = 20 书币（每天只发一次）
///   · 喂食 = 10 书币 → 饱食度 +30、经验 +20、心情 +8
///   · 摸摸 = 心情 +12、经验 +4（30 秒冷却）
///   · 饱食度/心情随时间缓慢下降（按真实小时）
class PetService extends ChangeNotifier {
  PetService._();
  static final PetService instance = PetService._();

  static const _key = 'reading_pet_v1';

  /// 默认桌宠：**阿汪**（有用户提供的插画）。
  ///
  /// ⚠️ 之前默认是「喵酱」(cat)：它是**唯一没有插画**的初始物种，
  /// 悬浮桌宠只能用矢量团子绘制，用户 2026-10-18 明确嫌丑
  /// （「这个宠物太他么丑了」）⇒ 默认改为有插画的阿汪。
  String speciesId = PetSpecies.dog.id;
  int level = 1;
  int exp = 0;
  int coins = 0;
  double mood = 80;
  double hunger = 80;

  final Set<String> unlockedSpecies = {PetSpecies.dog.id};
  final Set<String> ownedOutfits = {PetOutfits.none.id};
  String equippedOutfit = PetOutfits.none.id;

  bool enabled = true;
  /// 悬浮桌宠位置（0~1 相对坐标）。
  ///
  /// 用户 2026-10-18：「宠物能不能贴边？」⇒ 默认直接贴右边，
  /// 拖到靠近左右边缘时也会吸附成 0 / 1（见 [ReadingPetOverlay] 的拖拽结束处理）。
  double posX = 1.0;
  double posY = 0.55;

  /// 悬浮桌宠尺寸（px）。用户 2026-10-18：可在「显示设置」里滑动或输入调整。
  static const double minSize = 72;
  static const double maxSize = 160;
  double size = 112;

  /// 自定义桌宠图片（PNG / GIF）的本机绝对路径；空 = 没用自定义皮肤。
  ///
  /// 用户 2026-10-18：「能自定义增加 PNG 或 GIF 图片」。
  String customPetPath = '';

  /// 当前是否使用自定义图片皮肤。
  bool get isCustomPet => speciesId == PetSpecies.custom.id;

  int lastTickMs = 0;
  String lastReadingDate = '';
  int lastReadingMinutes = 0;
  String lastCheckinDate = '';
  int lastPlayMs = 0;

  bool isLoaded = false;

  PetSpeciesInfo get species => PetSpecies.byId(speciesId);

  int get expToNext => 100 + (level - 1) * 60;

  double get expRatio => (exp / expToNext).clamp(0.0, 1.0);

  Future<void> load() async {
    if (isLoaded) return;
    var needPersist = false;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map) {
          speciesId = '${j['species'] ?? speciesId}';
          level = (j['level'] as num?)?.toInt() ?? level;
          exp = (j['exp'] as num?)?.toInt() ?? exp;
          coins = (j['coins'] as num?)?.toInt() ?? coins;
          mood = (j['mood'] as num?)?.toDouble() ?? mood;
          hunger = (j['hunger'] as num?)?.toDouble() ?? hunger;
          enabled = j['enabled'] != false;
          posX = (j['posX'] as num?)?.toDouble() ?? posX;
          posY = (j['posY'] as num?)?.toDouble() ?? posY;
          size = ((j['size'] as num?)?.toDouble() ?? size)
              .clamp(minSize, maxSize)
              .toDouble();
          customPetPath = '${j['customPet'] ?? ''}';
          lastTickMs = (j['lastTickMs'] as num?)?.toInt() ?? 0;
          lastReadingDate = '${j['lastReadingDate'] ?? ''}';
          lastReadingMinutes = (j['lastReadingMinutes'] as num?)?.toInt() ?? 0;
          lastCheckinDate = '${j['lastCheckinDate'] ?? ''}';
          lastPlayMs = (j['lastPlayMs'] as num?)?.toInt() ?? 0;
          final us = j['unlocked'];
          if (us is List) {
            unlockedSpecies
              ..clear()
              ..addAll(us.map((e) => '$e'))
              ..add(PetSpecies.dog.id);
          }
          final of = j['outfits'];
          if (of is List) {
            ownedOutfits
              ..clear()
              ..addAll(of.map((e) => '$e'))
              ..add(PetOutfits.none.id);
          }
          equippedOutfit = '${j['equipped'] ?? PetOutfits.none.id}';
          if (!ownedOutfits.contains(equippedOutfit)) {
            equippedOutfit = PetOutfits.none.id;
          }
          // 自定义皮肤文件丢了（换机 / 清理缓存）→ 回退到阿汪，避免空白桌宠
          if (speciesId == PetSpecies.custom.id) {
            final ok = customPetPath.isNotEmpty &&
                File(customPetPath).existsSync();
            if (!ok) {
              speciesId = PetSpecies.dog.id;
              customPetPath = '';
              needPersist = true;
            }
          }
          // 用户 2026-10-18：「宠物贴边」—— 老存档里靠近左右边缘的位置
          // 直接吸附到真正的屏幕边缘（0 / 1），不再留一条缝。
          if (posX >= 0.75) {
            posX = 1.0;
            needPersist = true;
          } else if (posX <= 0.25) {
            posX = 0.0;
            needPersist = true;
          }
          // 2026-10-18：老用户沿用的默认「喵酱」(cat) 没有插画，
          // 悬浮桌宠会退化成矢量团子（用户嫌丑）⇒ 一次性迁到有插画的阿汪。
          if (speciesId == PetSpecies.cat.id) {
            speciesId = PetSpecies.dog.id;
            unlockedSpecies
              ..remove(PetSpecies.cat.id)
              ..add(PetSpecies.dog.id);
            needPersist = true;
          }
        }
      }
      isLoaded = true;
      _decay();
      await syncReading();
      if (needPersist) await _persist();
    } catch (e) {
      isLoaded = true;
      debugPrint('[Pet] 加载失败: $e');
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _key,
        jsonEncode({
          'species': speciesId,
          'level': level,
          'exp': exp,
          'coins': coins,
          'mood': mood,
          'hunger': hunger,
          'enabled': enabled,
          'posX': posX,
          'posY': posY,
          'size': size,
          'customPet': customPetPath,
          'lastTickMs': lastTickMs,
          'lastReadingDate': lastReadingDate,
          'lastReadingMinutes': lastReadingMinutes,
          'lastCheckinDate': lastCheckinDate,
          'lastPlayMs': lastPlayMs,
          'unlocked': unlockedSpecies.toList(),
          'outfits': ownedOutfits.toList(),
          'equipped': equippedOutfit,
        }),
      );
    } catch (e) {
      debugPrint('[Pet] 保存失败: $e');
    }
  }

  DateTime get _today => DateTime.now();

  String get _todayKey =>
      '${_today.year}-${_today.month.toString().padLeft(2, '0')}-${_today.day.toString().padLeft(2, '0')}';

  /// 按真实时间衰减饱食度/心情（每小时 -3 / -2，保底 10）。
  void _decay() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lastTickMs <= 0) {
      lastTickMs = now;
      return;
    }
    final hours = (now - lastTickMs) / 3600000.0;
    if (hours <= 0) return;
    hunger = (hunger - hours * 3).clamp(10.0, 100.0);
    mood = (mood - hours * 2).clamp(10.0, 100.0);
    lastTickMs = now;
  }

  /// 把「阅读时长 / 打卡」同步成经验与书币（幂等：按当日分钟增量）。
  Future<void> syncReading() async {
    try {
      final minutes = await ReadingTimeService.instance.todayMinutes();
      final today = _todayKey;
      if (lastReadingDate != today) {
        lastReadingDate = today;
        lastReadingMinutes = 0;
      }
      if (minutes > lastReadingMinutes) {
        final diff = minutes - lastReadingMinutes;
        lastReadingMinutes = minutes;
        grantExp(diff * 2);
        coins += diff ~/ 10;
      }

      final checkin = ReadingCheckinService.instance;
      if (!checkin.isLoaded) await checkin.load();
      if (checkin.checkedToday && lastCheckinDate != today) {
        lastCheckinDate = today;
        coins += 20;
        grantExp(10);
      }
      _decay();
      await _persist();
      notifyListeners();
    } catch (e) {
      debugPrint('[Pet] 同步阅读数据失败: $e');
    }
  }

  /// 加经验并处理升级。
  void grantExp(int amount) {
    if (amount <= 0) return;
    exp += amount;
    while (exp >= expToNext) {
      exp -= expToNext;
      level++;
      coins += 30;
      mood = min(100, mood + 10);
    }
  }

  void setEnabled(bool value) {
    enabled = value;
    _persist();
    notifyListeners();
  }

  void setPosition(double x, double y) {
    posX = x.clamp(0.0, 1.0);
    posY = y.clamp(0.0, 1.0);
    notifyListeners();
  }

  Future<void> persistPosition() => _persist();

  /// 调整桌宠尺寸（72~160px），立即生效并落盘。
  Future<void> setSize(double v) async {
    final next = v.clamp(minSize, maxSize).toDouble();
    if (next == size) return;
    size = next;
    notifyListeners();
    await _persist();
  }

  /// 切到自定义图片皮肤（PNG / GIF）。
  Future<void> setCustomPet(String path) async {
    customPetPath = path;
    speciesId = PetSpecies.custom.id;
    notifyListeners();
    await _persist();
  }

  /// 移除自定义皮肤：删文件 + 回到阿汪。
  Future<void> clearCustomPet() async {
    final old = customPetPath;
    customPetPath = '';
    if (speciesId == PetSpecies.custom.id) speciesId = PetSpecies.dog.id;
    notifyListeners();
    await _persist();
    if (old.isNotEmpty) {
      try {
        final f = File(old);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  Future<bool> feed() async {
    if (coins < 10) return false;
    coins -= 10;
    hunger = min(100, hunger + 30);
    mood = min(100, mood + 8);
    grantExp(20);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<bool> play() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - lastPlayMs < 30000) return false;
    lastPlayMs = now;
    mood = min(100, mood + 12);
    grantExp(4);
    await _persist();
    notifyListeners();
    return true;
  }

  bool canUnlock(PetSpeciesInfo s) =>
      !unlockedSpecies.contains(s.id) &&
      level >= s.unlockLevel &&
      coins >= s.price;

  Future<bool> unlockSpecies(PetSpeciesInfo s) async {
    if (!canUnlock(s)) return false;
    coins -= s.price;
    unlockedSpecies.add(s.id);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> setSpecies(PetSpeciesInfo s) async {
    if (!unlockedSpecies.contains(s.id)) return;
    speciesId = s.id;
    await _persist();
    notifyListeners();
  }

  bool ownsOutfit(PetOutfitInfo o) => ownedOutfits.contains(o.id);

  Future<bool> buyOutfit(PetOutfitInfo o) async {
    if (o.id == PetOutfits.none.id) {
      equippedOutfit = o.id;
      await _persist();
      notifyListeners();
      return true;
    }
    if (ownedOutfits.contains(o.id)) {
      equippedOutfit = o.id;
      await _persist();
      notifyListeners();
      return true;
    }
    if (level < o.unlockLevel || coins < o.price) return false;
    coins -= o.price;
    ownedOutfits.add(o.id);
    equippedOutfit = o.id;
    await _persist();
    notifyListeners();
    return true;
  }

  String get statusLine {
    if (hunger < 25) return '肚子咕咕叫…';
    if (mood < 30) return '有点无聊，摸摸我吧';
    if (hunger > 80 && mood > 80) return '今天也要好好读书呀';
    return '陪着你一起读';
  }
}
