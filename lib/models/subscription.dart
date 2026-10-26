import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/moontv_converter.dart';

/// 订阅的「导入分类」——用于在订阅管理里按来源分组显示。
///
/// 2026-10-13 用户指定分类（订阅页「新增分类」按这两行三列排）：
///   CatVod / TvBox / CMS / PY源 / T4源 / JS源
///
/// 注意：这是**展示/归类**用的，不影响是否激活、也不影响配置加载。
/// [unknown] 只是**旧数据的兜底**（老版本存的是 videoConfig/live/… 那套名字，
/// 解析不出就落这里），选择器里**不提供**它。
enum SubscriptionKind {
  catvod,
  tvbox,
  cms,
  py,
  t4,
  js,
  unknown;

  /// 可在「新增/编辑订阅」里手选的分类（就是用户点名的那 6 个）
  static const List<SubscriptionKind> selectable = [
    catvod,
    tvbox,
    cms,
    py,
    t4,
    js,
  ];

  /// 旧数据兜底：只做**很保守**的推断，其余一律 [unknown]
  /// —— 猜错的分类比"未分类"更误导人。
  ///
  /// ⚠️ 2026-10-14 修（用户：「为啥将 js 以及 js.md5 这个定位成 js 源？这是猫源呀」）：
  ///   `.js` / `.js.md5` 这种**订阅地址**绝大多数就是 **CatVod 整包订阅**
  ///   （标准形态 `.../catvod/index.js.md5`，线路由脚本的 /config 下发）。
  ///   原来推断成 `js` ⇒ 订阅管理里显示"JS源"，与实际不符 ✗。
  ///   `JS源` 这个分类留给**单脚本站点 js**（drpy2 的站点脚本），
  ///   而订阅地址的后缀判断不出那种，所以不再自动落到 `js`。
  static SubscriptionKind inferKind(String url) {
    final u = url.trim().toLowerCase();
    if (u.isEmpty) return SubscriptionKind.unknown;
    // 转换器写入本地的配置（`local://xxx`）本质是 TVBox JSON
    if (u.startsWith('local://')) return SubscriptionKind.tvbox;
    // TVBox 的 `;md5;<hash>` 语法：分号后是校验和、不属于地址
    final raw = u.split(';').first.trim();
    final path = Uri.tryParse(raw)?.path ?? raw;
    if (path.endsWith('.py') || path.endsWith('.py.md5')) {
      return SubscriptionKind.py;
    }
    // .js / .js.md5 / .jar / .jar.md5 → CatVod 整包订阅（猫源）
    if (path.endsWith('.js') ||
        path.endsWith('.js.md5') ||
        path.endsWith('.jar') ||
        path.endsWith('.jar.md5')) {
      return SubscriptionKind.catvod;
    }
    return SubscriptionKind.unknown;
  }
}

extension SubscriptionKindX on SubscriptionKind {
  /// 中文名（分组标题 / 徽标用）
  String get label {
    switch (this) {
      case SubscriptionKind.catvod:
        return 'CatVod';
      case SubscriptionKind.tvbox:
        return 'TvBox';
      case SubscriptionKind.cms:
        return 'CMS';
      case SubscriptionKind.py:
        return 'PY源';
      case SubscriptionKind.t4:
        return 'T4源';
      case SubscriptionKind.js:
        return 'JS源';
      case SubscriptionKind.unknown:
        return '未分类';
    }
  }

  /// 图标（与现有 Material 图标风格一致）
  IconData get icon {
    switch (this) {
      case SubscriptionKind.catvod:
        return Icons.movie_filter_outlined;
      case SubscriptionKind.tvbox:
        return Icons.tv_outlined;
      case SubscriptionKind.cms:
        return Icons.dns_outlined;
      case SubscriptionKind.py:
        return Icons.terminal_outlined;
      case SubscriptionKind.t4:
        return Icons.settings_input_antenna_outlined;
      case SubscriptionKind.js:
        return Icons.code_outlined;
      case SubscriptionKind.unknown:
        return Icons.rss_feed;
    }
  }
}

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

  /// 导入分类（旧数据缺失时由 [inferKind] 推断）
  SubscriptionKind kind;

  Subscription({
    required this.id,
    required this.url,
    required this.name,
    this.autoUpdate = true,
    this.locked = false,
    this.lastUpdatedMs = 0,
    this.fingerprint = '',
    this.kind = SubscriptionKind.unknown,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'autoUpdate': autoUpdate,
        'locked': locked,
        'lastUpdatedMs': lastUpdatedMs,
        'fingerprint': fingerprint,
        'kind': kind.name,
      };

  static Subscription fromJson(Map<String, Object?> j) {
    final url = (j['url'] ?? '') as String;
    final rawKind = j['kind'];
    // 向后兼容：旧数据没有 kind 字段时按 url 推断；
    // 有 kind 字段则直接解析（解析不出归 unknown，不再猜）。
    final kind = rawKind is String
        ? _kindFromName(rawKind)
        : Subscription.inferKind(url);
    return Subscription(
      id: (j['id'] ?? '') as String,
      url: url,
      name: (j['name'] ?? '') as String,
      autoUpdate: (j['autoUpdate'] ?? true) as bool,
      locked: (j['locked'] ?? false) as bool,
      lastUpdatedMs: (j['lastUpdatedMs'] as num?)?.toInt() ?? 0,
      fingerprint: (j['fingerprint'] ?? '') as String,
      kind: kind,
    );
  }

  static SubscriptionKind _kindFromName(String name) {
    for (final k in SubscriptionKind.values) {
      if (k.name == name) return k;
    }
    return SubscriptionKind.unknown;
  }

  /// 按地址推断导入分类（猜不出返回 [unknown]，不擅自猜成影视配置）
  /// 按地址推断导入分类（复用 [SubscriptionKind.inferKind]）
  static SubscriptionKind inferKind(String url) =>
      SubscriptionKind.inferKind(url);

  /// 分类中文名（供列表徽标 / 分组标题复用）
  String get kindLabel => kind.label;

  /// 分类图标
  IconData get kindIcon => kind.icon;

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

  static const String _listKey = 'subscriptions_v1';
  static const String _activeKey = 'active_subscription_id';
  static const String _pinKey = 'subscription_pin';

  /// 文件级备份名（放 Documents，与 prefs plist 互相独立）。
  ///
  /// 为什么要它：**进程被硬打断（崩溃 / CPython fatal exit）时，整个 prefs plist
  /// 可能没落盘或被写坏** ⇒ 所有键一起丢。用户 2026-10-13 报的「用了 py 源后退出
  /// 再进，订阅管理里的订阅 + 小程序订阅全没了」正是这种整域丢失（两个键同时空）。
  /// `api_config` 的 `api_url.bak` 用的是同一套兜底，这里补齐订阅这一份。
  static const String _backupName = 'subscriptions.bak';

  Future<File> _backupFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/$_backupName');
  }

  /// 删掉文件备份（清理订阅列表 / 重置时必须一起删）。
  ///
  /// 2026-10-14 修：`data_cleanup_page` 的「订阅列表」只删了 prefs 两个键，
  /// **没删这份 .bak** ⇒ 重启时 `load()` 发现 prefs 空 → 从备份恢复 →
  /// **订阅全回来了，清理等于没清**。
  /// `api_url.bak` 那边早就有 `clearApiUrlBackup()`，这里补齐同款。
  static Future<void> clearBackup() async {
    try {
      // 这里不能用 `_backupFile()` —— 它是实例方法，静态方法里访问不了；
      // 路径规则与它保持一致（Documents/<名字>）即可，不重复抽象。
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}/$_backupName');
      if (await f.exists()) await f.delete();
    } catch (e) {
      AppLog.instance.log('[Subscription] 删备份失败: $e');
    }
  }

  /// 解析一段 JSON 文本为订阅列表（失败返回空，不抛）
  List<Subscription> _tryDecode(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final out = <Subscription>[];
        for (final e in decoded) {
          if (e is Map) {
            final s = Subscription.fromJson(e.cast<String, Object?>());
            if (s.url.isNotEmpty) out.add(s);
          }
        }
        return out;
      }
    } catch (e) {
      AppLog.instance.log('[Subscription] 解析失败: $e');
    }
    return const [];
  }

  /// 读文件备份（返回 items + 激活 id；没有/损坏返回 null）
  Future<({List<Subscription> items, String activeId})?> _readBackup() async {
    try {
      final f = await _backupFile();
      if (!await f.exists()) return null;
      final txt = await f.readAsString();
      if (txt.trim().isEmpty) return null;
      final m = jsonDecode(txt);
      if (m is! Map) return null;
      final items = _tryDecode(jsonEncode(m['items'] ?? const []));
      return (items: items, activeId: (m['activeId'] ?? '').toString());
    } catch (e) {
      AppLog.instance.log('[Subscription] 读文件备份失败: $e');
      return null;
    }
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
    var items = _tryDecode(prefs.getString(_listKey) ?? '');
    var savedActive = prefs.getString(_activeKey) ?? '';

    // prefs 空/损坏 → 用文件备份兜底（整域丢失后的自救）
    if (items.isEmpty) {
      final bak = await _readBackup();
      if (bak != null && bak.items.isNotEmpty) {
        items = bak.items;
        if (savedActive.isEmpty) savedActive = bak.activeId;
        // 回填 prefs，后续读写恢复正常
        try {
          await prefs.setString(
              _listKey, jsonEncode(items.map((s) => s.toJson()).toList()));
          if (savedActive.isNotEmpty) {
            await prefs.setString(_activeKey, savedActive);
          }
        } catch (e) {
          AppLog.instance.log('[Subscription] 回填 prefs 失败: $e');
        }
        AppLog.instance.log(
            '[Subscription] prefs 丢失/损坏，已从文件备份恢复 ${items.length} 条');
      }
    }

    subscriptions.assignAll(items);
    activeId.value = savedActive;
    pinSet.value = (prefs.getString(_pinKey) ?? '').isNotEmpty;
    // 激活 id 失效时回落到第一条
    if (savedActive.isNotEmpty &&
        !subscriptions.any((s) => s.id == savedActive)) {
      activeId.value = subscriptions.isEmpty ? '' : subscriptions.first.id;
    }
    AppLog.instance.log('[Subscription] 已加载 ${subscriptions.length} 条, '
        '激活=${active?.name ?? "无"}');
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final items = subscriptions.map((s) => s.toJson()).toList();
    await prefs.setString(_listKey, jsonEncode(items));
    await prefs.setString(_activeKey, activeId.value);
    // 文件备份（独立于 plist，进程被硬打断也能救回来）
    try {
      final f = await _backupFile();
      await f.writeAsString(
          jsonEncode({'items': items, 'activeId': activeId.value}),
          flush: true);
    } catch (e) {
      AppLog.instance.log('[Subscription] 写文件备份失败: $e');
    }
  }

  // ============================================================
  // 增删改
  // ============================================================

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  /// 新增订阅；若当前没有任何订阅，设为激活
  ///
  /// [kind] 为空时按 url 推断（见 [Subscription.inferKind]）。
  Future<Subscription> add({
    required String url,
    String? name,
    SubscriptionKind? kind,
  }) async {
    final trimmed = url.trim();
    final s = Subscription(
      id: _newId(),
      url: trimmed,
      name: (name == null || name.trim().isEmpty)
          ? _deriveName(url)
          : name.trim(),
      kind: kind ?? Subscription.inferKind(trimmed),
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
    final removed = subscriptions.firstWhereOrNull((s) => s.id == id);
    subscriptions.removeWhere((s) => s.id == id);
    if (removed != null && ConvertedConfigStore.isLocal(removed.url)) {
      await ConvertedConfigStore.delete(removed.url);
    }
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
    // 本地转换配置：没有远程地址可拉，直接算"已同步"
    if (ConvertedConfigStore.isLocal(s.url)) {
      await markSynced(id, s.url);
      return SyncResult.unchanged;
    }
    if (syncingId.value.isNotEmpty) return SyncResult.busy;

    syncingId.value = id;
    Dio? client; // 见 finally：局部 Dio 必须显式释放
    try {
      final dio = client = Dio(BaseOptions(
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
      client?.close(force: true); // 局部新建的 Dio 必须显式释放，否则遗留 HttpClient 连接池
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
