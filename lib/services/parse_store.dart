// lib/services/parse_store.dart
//
// 解析线路（TVBox 的 `parses`）的**本地持久化 + 当前选中线路**。
//
// ── 解决什么（用户 2026-10-14）────────────────────────────────
// `ApiConfig.parseBeanList` 原来是「订阅里有什么就是什么」：换一个不带 parses
// 的订阅 → 整表清空，之前拉到的解析线路立刻消失，播放器上的「解析」按钮也就
// 没线路可切了。
// 这里把线路**落盘**（prefs + Documents 下的文件备份，与 api_url / 直播源
// 同一套思路），订阅下发的线路只**并入**、不覆盖、不清空；用户可在
// 设置 → 订阅管理 → 解析线路管理 里选线路 / 删除 / 手动添加。
//
// ── 与「直播源」的区别 ───────────────────────────────────────
// 直播源是「本地有就不让订阅覆盖」；解析线路是**累加**（不同订阅各有各的
// 线路，都留着才有得选），所以这里是 merge 语义。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/services/app_log.dart';

class ParseStore {
  ParseStore._();
  static final ParseStore instance = ParseStore._();

  static const String _kList = 'parse_line_list'; // StringList（每项一条 JSON）
  static const String _kActive = 'parse_active_url'; // 选中的线路 url
  static const String _kSeeded = 'parse_builtin_seeded'; // 内置线路是否已检查过
  static const String _backupName = 'parse_list.bak';

  /// 内置兜底线路。
  ///
  /// 为什么要内置（2026-10-28 用户指定）：`ApiConfig.parseBeanList` 是
  /// 「订阅里有什么就是什么」，用户订阅不带 `parses`、自己也没手动加过时
  /// 整张表是空的 ⇒ `ParseService.hasParsers` 为 false ⇒ 详情页/播放器里
  /// 那一整段解析代码**根本不执行**，用户看到的就是「解析按钮点了没反应」。
  ///
  /// `type: 0` = 嗅探/通用解析站：它返回的可能是直链，也可能是一个带播放器
  /// 的网页（交给嗅探链路兜底），两种都由 `ParseService` 自己判定。
  static const List<ParseBean> kBuiltinParsers = [
    ParseBean(
      name: '内置解析',
      url: 'https://jx.muiu.site/?url=',
      type: 0,
    ),
  ];

  final List<ParseBean> _list = [];
  String _activeUrl = '';
  bool _loaded = false;

  /// 全部线路（顺序即优先顺序）。
  ///
  /// 返回**可变副本**：调用方把它灌进 `ApiConfig.parseBeanList`（RxList），
  /// 而小程序注册/卸载会对那个 RxList 做增删 —— 给不可变视图会直接抛
  /// UnsupportedError。这里给副本，谁也不用担心改到内部状态。
  List<ParseBean> get list => List<ParseBean>.of(_list);

  /// 当前选中的线路 url（空串 = 自动：按顺序依次尝试）
  String get activeUrl => _activeUrl;

  /// 当前选中的线路；未选 / 已被删除 → null（调用方按"自动"处理）
  ParseBean? get activeBean {
    if (_activeUrl.isEmpty) return null;
    for (final b in _list) {
      if (b.url == _activeUrl) return b;
    }
    return null;
  }

  // ============================================================
  // 载入 / 落盘
  // ============================================================

  /// 启动时调用一次（须早于 ApiConfig 首次加载配置）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getStringList(_kList) ?? const <String>[];
      if (raw.isEmpty) raw = await _readBackup();
      _list
        ..clear()
        ..addAll(_decode(raw));
      _activeUrl = (prefs.getString(_kActive) ?? '').trim();

      // ── 内置兜底线路（只塞一次）────────────────────────────────
      //
      // 触发条件：本地一条线路都没有 **且** 这个标记还没写过。
      // 标记写成后永不再塞 —— 用户**明确删掉**内置线路之后，不该每次启动
      // 又给他冒出来一条（2026-10-28）。
      final seeded = prefs.getBool(_kSeeded) ?? false;
      if (!seeded) {
        await prefs.setBool(_kSeeded, true);
        if (_list.isEmpty) {
          _list.addAll(kBuiltinParsers);
          await _save();
          AppLog.instance.log(
              '[ParseStore] 本地没有解析线路 → 已内置 ${kBuiltinParsers.length} 条兜底');
        }
      }

      // 选中的线路已经不在列表里（被删了 / 备份较旧）→ 回到"自动"
      if (_activeUrl.isNotEmpty && !_list.any((b) => b.url == _activeUrl)) {
        _activeUrl = '';
      }
      AppLog.instance.log('[ParseStore] 就绪：${_list.length} 条线路，'
          '选中=${_activeUrl.isEmpty ? "自动" : _activeUrl}');
    } catch (e) {
      AppLog.instance.log('[ParseStore] 读取失败: $e');
    }
  }

  Future<void> _save() async {
    final raw = _list.map(_encode).toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kList, raw);
      await prefs.setString(_kActive, _activeUrl);
    } catch (e) {
      AppLog.instance.log('[ParseStore] 写 prefs 失败: $e');
    }
    try {
      final f = await _backupFile();
      await f.writeAsString(jsonEncode(raw), flush: true);
    } catch (e) {
      AppLog.instance.log('[ParseStore] 写备份失败: $e');
    }
  }

  static Future<File> _backupFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/$_backupName');
  }

  Future<List<String>> _readBackup() async {
    try {
      final f = await _backupFile();
      if (!await f.exists()) return const [];
      final text = await f.readAsString();
      if (text.trim().isEmpty) return const [];
      final decoded = jsonDecode(text);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (e) {
      AppLog.instance.log('[ParseStore] 读备份失败: $e');
    }
    return const [];
  }

  static String _encode(ParseBean b) => jsonEncode({
        'name': b.name,
        'url': b.url,
        'type': b.type,
        if (b.ext != null) 'ext': b.ext,
        'enabled': b.enabled,
      });

  static List<ParseBean> _decode(List<String> raw) {
    final out = <ParseBean>[];
    for (final s in raw) {
      try {
        final j = jsonDecode(s);
        if (j is Map<String, dynamic>) {
          final b = ParseBean.fromJson(j);
          if (b.url.trim().isNotEmpty) out.add(b);
        }
      } catch (_) {
        // 坏记录跳过，别拖垮整份列表
      }
    }
    return out;
  }

  // ============================================================
  // 增删改 + 选线路
  // ============================================================

  /// 把订阅下发的线路**并入**本地：同 url 覆盖 name/type，不删本地已有的。
  /// 返回是否有变化（上层据此决定要不要刷新列表）。
  ///
  /// ⚠️ 订阅下发的线路常常**不带 ext**（header）；此时保留本地已填的 ext，
  /// 否则用户手填的请求头会被订阅一次次清掉（2026-10-15）。
  /// ⚠️ 同理，`enabled` 是**用户设置**（启用/禁用），订阅下发不覆盖 ——
  /// 同 url 时保留本地 enabled（2026-10-28，对齐 huoyi enabled 语义）。
  Future<bool> absorb(Iterable<ParseBean> incoming) async {
    if (!_loaded) await load();
    var changed = false;
    for (final b in incoming) {
      final url = b.url.trim();
      if (url.isEmpty) continue;
      final i = _list.indexWhere((x) => x.url == url);
      if (i < 0) {
        _list.add(ParseBean(
            name: b.name, url: url, type: b.type, ext: b.ext, enabled: true));
        changed = true;
      } else {
        final local = _list[i];
        final mergedExt = b.ext ?? local.ext;
        if (local.name != b.name ||
            local.type != b.type ||
            !_sameExt(local.ext, mergedExt)) {
          _list[i] = ParseBean(
              name: b.name,
              url: url,
              type: b.type,
              ext: mergedExt,
              enabled: local.enabled);
          changed = true;
        }
      }
    }
    if (changed) await _save();
    return changed;
  }

  /// 手动新增 / 编辑一条线路（**整体替换**语义）。
  ///
  /// 与 [absorb]（订阅合并、会保留本地 ext）不同：这里用户清空请求头就要真的
  /// 清掉。[originalUrl] 用于"改了地址"的场景 —— 先把旧 url 那条摘掉。
  Future<void> addOrUpdate(ParseBean bean, {String? originalUrl}) async {
    if (!_loaded) await load();
    final url = bean.url.trim();
    if (url.isEmpty) return;

    final oldUrl = (originalUrl ?? '').trim();
    if (oldUrl.isNotEmpty && oldUrl != url) {
      _list.removeWhere((x) => x.url == oldUrl);
      if (_activeUrl == oldUrl) _activeUrl = url; // 选中项跟着地址走
    }

    final fresh = ParseBean(
        name: bean.name,
        url: url,
        type: bean.type,
        ext: bean.ext,
        enabled: bean.enabled);
    final i = _list.indexWhere((x) => x.url == url);
    if (i < 0) {
      _list.add(fresh);
    } else {
      _list[i] = fresh;
    }
    await _save();
  }

  /// 启用 / 禁用一条线路；禁用当前选中项时选中回到"自动"（huoyi 同款语义）。
  Future<void> setEnabled(String url, bool enabled) async {
    final i = _list.indexWhere((x) => x.url == url);
    if (i < 0) return;
    _list[i] = ParseBean(
      name: _list[i].name,
      url: _list[i].url,
      type: _list[i].type,
      ext: _list[i].ext,
      enabled: enabled,
    );
    if (!enabled && _activeUrl == url) _activeUrl = '';
    await _save();
  }

  /// 上移 / 下移一条线路（改变"优先顺序"；huoyi 同款能力）。
  ///
  /// [delta] -1 = 上移（更优先），+1 = 下移。越界时不动。
  Future<void> move(String url, int delta) async {
    final i = _list.indexWhere((x) => x.url == url);
    if (i < 0) return;
    final target = i + delta;
    if (target < 0 || target >= _list.length) return;
    final item = _list.removeAt(i);
    _list.insert(target, item);
    await _save();
  }

  /// 两个 ext（请求头）Map 是否等价
  static bool _sameExt(Map<String, String>? a, Map<String, String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  /// 删除一条线路；若删的正是选中项，选中态回到"自动"。
  Future<void> remove(String url) async {
    final i = _list.indexWhere((x) => x.url == url);
    if (i < 0) return;
    _list.removeAt(i);
    if (_activeUrl == url) _activeUrl = '';
    await _save();
  }

  /// 选中某条线路；传空串 = 自动（按顺序试全部）。
  Future<void> setActive(String url) async {
    final u = url.trim();
    _activeUrl = u.isEmpty ? '' : u;
    await _save();
  }
}
