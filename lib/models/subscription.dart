import 'dart:convert';

import 'package:dio/dio.dart';
import 'dart:io';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_log.dart';

/// 一条订阅（= 一个点播接口地址的条目）
class Subscription {
  /// 稳定 id（创建后不变，用于持久化与选中判断）
  final String id;

  /// 接口地址（如 https://omnibox:xxx@...）
  String url;

  /// 显示名（用户可改）
  String name;

  /// 随启动自动同步最新内容
  bool autoUpdate;

  /// 是否上锁（上锁后需 PIN 才能看到地址与内容）
  bool locked;

  /// 上次更新时间（时间戳毫秒，0 = 从未）
  int lastUpdatedMs;

  /// 内容指纹：配置内容的 CRC/hash 前 8 位，用于判断"内容是否真的变了"
  String fingerprint;

  Subscription({
    required this.id,
    required this.url,
    required this.name,
    this.autoUpdate = true,
    this.locked = false,
    this.lastUpdatedMs = 0,
    this.fingerprint = '',
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'autoUpdate': autoUpdate,
        'locked': locked,
        'lastUpdatedMs': lastUpdatedMs,
        'fingerprint': fingerprint,
      };

  static Subscription fromJson(Map<String, Object?> j) => Subscription(
        id: (j['id'] ?? '') as String,
        url: (j['url'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        autoUpdate: (j['autoUpdate'] ?? true) as bool,
        locked: (j['locked'] ?? false) as bool,
        lastUpdatedMs: (j['lastUpdatedMs'] as num?)?.toInt() ?? 0,
        fingerprint: (j['fingerprint'] ?? '') as String,
      );

  /// 上次更新的展示文案（yyyy.M.d）
  String get lastUpdatedText {
    if (lastUpdatedMs <= 0) return '从未更新';
    final d = DateTime.fromMillisecondsSinceEpoch(lastUpdatedMs);
    return '${d.year}.${d.month}.${d.day}';
  }

  /// 脱敏后的地址（上锁时只显示到主机名）
  String get maskedUrl {
    if (!locked) return url;
    final m = RegExp(r'^https?://([^/]+)').firstMatch(url);
    if (m == null) return '••••••';
    return '${m.group(0)}/••••••';
  }
}

/// 多订阅管理：列表 / 激活切换 / 增删改 / 上锁 / 内容指纹
///
/// 与 ApiConfig 的关系：
///   订阅是"地址簿"，ApiConfig 是"当前已加载的那一份配置"。
///   [activate] 会把该订阅的 url 交给 SettingsController → ApiConfig.loadConfigs，
///   也就是"切换哪个生效"。
class SubscriptionService extends GetxService {
  static SubscriptionService get instance {
    if (!Get.isRegistered<SubscriptionService>()) {
      Get.put<SubscriptionService>(SubscriptionService(), permanent: true);
    }
    return Get.find<SubscriptionService>();
  }

  static const String _listKey = 'subscriptions_v1';
  static const String _activeKey = 'active_subscription_id';
  static const String _pinKey = 'subscription_pin';

  final subscriptions = <Subscription>[].obs;

  /// 当前激活的订阅 id
  final activeId = ''.obs;

  /// PIN 是否已设置
  final pinSet = false.obs;

  /// 本次会话中已解锁（输过 PIN）。退出 App 后失效。
  final unlocked = false.obs;

  Subscription? get active {
    if (subscriptions.isEmpty) return null;
    return subscriptions.firstWhereOrNull((s) => s.id == activeId.value) ??
        subscriptions.first;
  }

  @override
  void onInit() {
    super.onInit();
    load();
  }

  // ============================================================
  // 持久化
  // ============================================================

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_listKey);
    subscriptions.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              final s = Subscription.fromJson(e.cast<String, Object?>());
              if (s.url.isNotEmpty) subscriptions.add(s);
            }
          }
        }
      } catch (e) {
        AppLog.instance.log('[Subscription] 解析失败: $e');
      }
    }
    activeId.value = prefs.getString(_activeKey) ?? '';
    pinSet.value = (prefs.getString(_pinKey) ?? '').isNotEmpty;
    // 激活 id 失效时回落到第一条
    if (active != null && activeId.value != active!.id) {
      activeId.value = active!.id;
    }
    AppLog.instance.log('[Subscription] 已加载 ${subscriptions.length} 条, '
        '激活=${active?.name ?? "无"}');
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _listKey, jsonEncode(subscriptions.map((s) => s.toJson()).toList()));
    await prefs.setString(_activeKey, activeId.value);
  }

  // ============================================================
  // 增删改
  // ============================================================

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  /// 新增订阅；若当前没有任何订阅，设为激活
  Future<Subscription> add({
    required String url,
    String? name,
  }) async {
    final s = Subscription(
      id: _newId(),
      url: url.trim(),
      name: (name == null || name.trim().isEmpty)
          ? _deriveName(url)
          : name.trim(),
    );
    subscriptions.add(s);
    if (activeId.value.isEmpty) activeId.value = s.id;
    await _persist();
    return s;
  }

  /// 从地址里猜一个名字（主机名，取不到就用序号）
  static String _deriveName(String url) {
    final m = RegExp(r'^https?://([^/:@]+)').firstMatch(url.trim());
    if (m != null && m.group(1)!.isNotEmpty) return m.group(1)!;
    return '订阅${DateTime.now().millisecond}';
  }

  Future<void> update(Subscription s) async {
    final i = subscriptions.indexWhere((e) => e.id == s.id);
    if (i < 0) return;
    subscriptions[i] = s;
    subscriptions.refresh();
    await _persist();
  }

  Future<void> remove(String id) async {
    subscriptions.removeWhere((s) => s.id == id);
    if (activeId.value == id) {
      activeId.value = subscriptions.isEmpty ? '' : subscriptions.first.id;
    }
    await _persist();
  }

  /// 切换生效的订阅（返回被激活的那条，交给调用方去真正加载配置）
  Future<Subscription?> setActive(String id) async {
    final s = subscriptions.firstWhereOrNull((e) => e.id == id);
    if (s == null) return null;
    activeId.value = id;
    await _persist();
    return s;
  }

  /// 记录一次成功同步：更新时间 + 内容指纹
  Future<void> markSynced(String id, String content) async {
    final i = subscriptions.indexWhere((e) => e.id == id);
    if (i < 0) return;
    subscriptions[i]
      ..lastUpdatedMs = DateTime.now().millisecondsSinceEpoch
      ..fingerprint = fingerprintOf(content);
    subscriptions.refresh();
    await _persist();
  }

  /// 内容指纹：取内容的 hash 前 8 位（十六进制）
  static String fingerprintOf(String content) {
    var h = 0x811c9dc5; // FNV-1a 32bit
    final bytes = utf8.encode(content);
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  // ============================================================
  // 上锁（6 位 PIN，纯 Dart 实现）
  // ============================================================

  /// 设置 / 修改 PIN
  Future<void> setPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pinKey, pin);
    pinSet.value = true;
    unlocked.value = true;
  }

  Future<void> clearPin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pinKey);
    pinSet.value = false;
    unlocked.value = true;
    // 同时把所有订阅解锁，避免上锁状态失去 PIN 后永远看不到
    for (final s in subscriptions) {
      s.locked = false;
    }
    subscriptions.refresh();
    await _persist();
  }

  Future<bool> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_pinKey) ?? '';
    final ok = saved.isNotEmpty && saved == pin;
    if (ok) unlocked.value = true;
    return ok;
  }

  /// 锁住本次会话（下次看内容要重新输 PIN）
  void lockSession() => unlocked.value = false;

  // ============================================================
  // 随启动自动同步
  // ============================================================

  /// 自动同步的节流：同一条订阅在这个间隔内不重复拉取（默认 6 小时）
  static const Duration _autoSyncMinGap = Duration(hours: 6);

  /// 本次启动是否已跑过（避免热重载/多次调用重复同步）
  bool _autoSyncedThisLaunch = false;

  /// 正在同步的订阅 id（UI 可用来显示转圈）
  final syncingId = ''.obs;

  /// 上次同步结果摘要（失败原因等，便于在设置页提示）
  final lastSyncMessage = ''.obs;

  /// App 启动后调用一次：把所有勾了「自动更新」的订阅拉一遍。
  ///
  /// 设计取舍：
  ///   - **不阻塞启动**：内部不 await 网络，调用方 `unawaited` 即可
  ///   - **只在内容变化时算一次同步**：用指纹比对，避免每次都刷新「上次更新」
  ///   - **失败不影响使用**：拉不到就保留旧数据，只记日志与提示
  Future<void> autoSyncOnLaunch() async {
    if (_autoSyncedThisLaunch) return;
    _autoSyncedThisLaunch = true;

    final targets = subscriptions.where((s) => s.autoUpdate).toList();
    if (targets.isEmpty) return;

    AppLog.instance.log('[Subscription] 启动自动同步 ${targets.length} 条');
    var okCount = 0;
    var skipCount = 0;
    final failed = <String>[];

    for (final s in targets) {
      // 距上次同步太近就跳过，省流量
      final last = s.lastUpdatedMs;
      if (last > 0 &&
          DateTime.now().millisecondsSinceEpoch - last <
              _autoSyncMinGap.inMilliseconds) {
        skipCount++;
        continue;
      }
      final r = await syncOne(s.id);
      if (r == SyncResult.updated || r == SyncResult.unchanged) {
        okCount++;
      } else if (r == SyncResult.failed) {
        failed.add(s.name);
      }
    }

    lastSyncMessage.value = failed.isEmpty
        ? '自动同步完成：成功 $okCount 条'
            '${skipCount > 0 ? "，跳过 $skipCount 条（未到间隔）" : ""}'
        : '自动同步：成功 $okCount 条，失败 ${failed.length} 条（${failed.join("、")}）';
    AppLog.instance.log('[Subscription] ${lastSyncMessage.value}');
  }

  /// 手动触发一次全量同步（忽略时间间隔）
  Future<void> syncAllNow() async {
    for (final s in subscriptions.where((e) => e.autoUpdate)) {
      await syncOne(s.id, force: true);
    }
  }

  /// 拉取单条订阅并更新指纹/时间。
  Future<SyncResult> syncOne(String id, {bool force = false}) async {
    final i = subscriptions.indexWhere((e) => e.id == id);
    if (i < 0) return SyncResult.notFound;
    final s = subscriptions[i];
    if (s.url.trim().isEmpty) return SyncResult.failed;
    if (syncingId.value.isNotEmpty) return SyncResult.busy;

    syncingId.value = id;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
      ));
      // 订阅地址里若带 user:pass@，转成 Authorization 头
      final headers = <String, String>{};
      final m = RegExp(r'^https?://([^/@:]+):([^/@]+)@').firstMatch(s.url);
      if (m != null) {
        final cred = base64Encode(utf8.encode('${m.group(1)}:${m.group(2)}'));
        headers['Authorization'] = 'Basic $cred';
      }
      final res = await dio.get<String>(
        s.url,
        options: Options(responseType: ResponseType.plain, headers: headers),
      );
      final body = res.data ?? '';
      if (body.trim().isEmpty) {
        lastSyncMessage.value = '${s.name}：内容为空';
        return SyncResult.failed;
      }

      final fp = fingerprintOf(body);
      if (!force && fp == s.fingerprint && s.fingerprint.isNotEmpty) {
        // 内容没变：只把时间往前推，避免每次启动都重复拉
        await markSynced(id, body);
        return SyncResult.unchanged;
      }
      await markSynced(id, body);
      return SyncResult.updated;
    } catch (e) {
      lastSyncMessage.value = '${s.name}：${_humanize(e)}';
      AppLog.instance.log('[Subscription] 同步 ${s.name} 失败: $e');
      return SyncResult.failed;
    } finally {
      syncingId.value = '';
    }
  }

  /// 把网络异常翻译成能看懂的中文
  static String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('timeout')) return '连接超时';
    if (s.contains('SocketException')) return '网络不可达';
    if (s.contains('certificate')) return '证书错误';
    if (s.contains('404')) return '地址不存在（404）';
    if (s.contains('403')) return '被拒绝访问（403）';
    return '拉取失败';
  }
}

/// 单条订阅的同步结果
enum SyncResult {
  /// 内容有变化，已刷新指纹
  updated,

  /// 内容与上次一致
  unchanged,

  /// 拉取失败（网络 / 空内容 / 地址错误）
  failed,

  /// 已经有别的订阅在同步
  busy,

  /// 找不到该订阅
  notFound,
}
