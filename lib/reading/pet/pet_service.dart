import 'dart:convert';
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

  String speciesId = PetSpecies.cat.id;
  int level = 1;
  int exp = 0;
  int coins = 0;
  double mood = 80;
  double hunger = 80;

  final Set<String> unlockedSpecies = {PetSpecies.cat.id, PetSpecies.dog.id};
  final Set<String> ownedOutfits = {PetOutfits.none.id};
  String equippedOutfit = PetOutfits.none.id;

  bool enabled = true;
  double posX = 0.86;
  double posY = 0.55;

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
              ..addAll([PetSpecies.cat.id, PetSpecies.dog.id]);
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
        }
      }
      isLoaded = true;
      _decay();
      await syncReading();
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
