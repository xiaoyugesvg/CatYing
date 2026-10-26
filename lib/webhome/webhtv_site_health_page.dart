import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/app_log.dart';

/// 「站点健康排序」（原 Webhtv → 站点健康排序）。
///
/// 入口现为「设置 → 通用设置 → 站点健康排序」（Webhtv 模块下线后搬过来的，
/// 用户 2026-10-16）。
///
/// 对齐 WebHomeTV 的「站点健康排序」：**自动学习站点的搜索 / 详情 / 播放成功率**，
/// 搜索与换源时优先使用更可用的站点；站点弹窗**默认仍按用户配置顺序**，
/// 只有在本页把总开关打开后才按健康度排序。
///
/// ── 记录点（真实接线，不是摆设）────────────────────────────────
///   · `home`   ：首页 / 分类加载的成败 ⇒ `lib/pages/home/controller.dart`
///   · `detail` ：详情加载的成败       ⇒ `lib/pages/detail/controller.dart`
///   · `play`   ：播放地址解析失败的记录 ⇒ 同上（`setPlaybackError`）
///
/// ── 未接入（页面上标注）──────────────────────────────────────
///   · **播放成功率**目前只有"失败"这一半：播放器真正开播的回调还没接，
///     所以播放列会显示 `-`（不编数据）。
class SiteHealthStore extends ChangeNotifier {
  SiteHealthStore._();
  static final SiteHealthStore instance = SiteHealthStore._();

  static const String _kKey = 'webhtv_site_health';
  static const String _kEnabledKey = 'webhtv_site_health_enabled';

  /// 总开关：开启后「搜索 / 换源」按健康度优先；关闭则完全按用户配置顺序。
  bool _enabled = false;
  bool get enabled => _enabled;

  /// key → {homeOk, homeFail, detailOk, detailFail, playOk, playFail}
  Map<String, Map<String, int>> _stats = {};
  bool _loaded = false;

  List<MapEntry<String, Map<String, int>>> get entries {
    final list = _stats.entries.toList();
    list.sort((a, b) => score(b.key).compareTo(score(a.key)));
    return list;
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabledKey) ?? false;
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw);
        if (m is Map) {
          _stats = m.map((k, v) => MapEntry(
                k.toString(),
                (v is Map)
                    ? v.map((a, b) =>
                        MapEntry(a.toString(), (b as num?)?.toInt() ?? 0))
                    : <String, int>{},
              ));
        }
      }
    } catch (e) {
      // 不置 `_loaded`：否则一次偶发读取失败会让本页整个会话都空着、不再重试
      AppLog.instance.log('[SiteHealth] 加载失败（下次进入会重试）: $e');
      return;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(_stats));
      await prefs.setBool(_kEnabledKey, _enabled);
    } catch (_) {}
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    _stats = {};
    notifyListeners();
    await _save();
  }

  /// 记一次成败。[kind] = home / detail / play
  ///
  /// ⚠️ 这个函数在**热路径**上（每次首页/分类/详情加载都会调）：
  ///   · 总开关关着（默认就是关）⇒ **直接返回**，连内存计数都不做
  ///     （原来无条件 `_save()`：即使功能没开，每次首页加载都会
  ///       `jsonEncode` 整表 + 写一次 SharedPreferences）；
  ///   · 开着时也要**节流落盘**（8 秒一次），只在内存累加。
  void record(String key, String kind, bool ok) {
    if (!_enabled) return;
    if (key.trim().isEmpty) return;
    final m = _stats.putIfAbsent(key, () => <String, int>{});
    final k = '$kind${ok ? 'Ok' : 'Fail'}';
    m[k] = (m[k] ?? 0) + 1;
    _saveSoon();
  }

  /// 落盘节流：8 秒合并写一次（页面 dispose 前的 `flush` 由调用方按需触发）
  Timer? _saveTimer;

  void _saveSoon() {
    if (_saveTimer != null) return;
    _saveTimer = Timer(const Duration(seconds: 8), () {
      _saveTimer = null;
      _save();
    });
  }

  /// 某类成功率；没样本返回 null（UI 显示 `-`，不编造 0%）
  double? rate(String key, String kind) {
    final m = _stats[key];
    if (m == null) return null;
    final ok = m['${kind}Ok'] ?? 0;
    final fail = m['${kind}Fail'] ?? 0;
    if (ok + fail == 0) return null;
    return ok / (ok + fail);
  }

  /// 综合分（0~1）：三类成功率等权，只统计有样本的类别；全无样本 = 0.5（中性）
  double score(String key) {
    final rs = <double>[];
    for (final k in const ['home', 'detail', 'play']) {
      final r = rate(key, k);
      if (r != null) rs.add(r);
    }
    if (rs.isEmpty) return 0.5;
    return rs.reduce((a, b) => a + b) / rs.length;
  }

  /// 按健康度排序（稳定：同分保持原顺序）。**仅在 [enabled] 时**调用方才会用。
  List<String> sorted(List<String> keys) {
    if (!_enabled) return keys;
    final idx = {for (var i = 0; i < keys.length; i++) keys[i]: i};
    final out = List<String>.of(keys);
    out.sort((a, b) {
      final c = score(b).compareTo(score(a));
      if (c != 0) return c;
      return (idx[a] ?? 0).compareTo(idx[b] ?? 0);
    });
    return out;
  }

  void log(String msg) => AppLog.instance.log('[SiteHealth] $msg');
}

// ============================================================
// 管理页
// ============================================================

class WebhtvSiteHealthPage extends StatefulWidget {
  const WebhtvSiteHealthPage({super.key});

  @override
  State<WebhtvSiteHealthPage> createState() => _WebhtvSiteHealthPageState();
}

class _WebhtvSiteHealthPageState extends State<WebhtvSiteHealthPage> {
  final _store = SiteHealthStore.instance;

  @override
  void initState() {
    super.initState();
    _store.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  static String _fmt(double? r) =>
      r == null ? '-' : '${(r * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : AppTheme.textSecondary;
    final entries = _store.entries;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: fg),
        title: Text('站点健康排序',
            style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              tooltip: '清空统计',
              onPressed: () async {
                await _store.clear();
                if (mounted) setState(() {});
              },
              icon: Icon(Icons.delete_sweep_outlined, color: fg),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // 总开关
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('搜索 / 换源时优先使用可用站点',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              fontWeight: FontWeight.w600,
                              color: fg)),
                      const SizedBox(height: 2),
                      Text('关闭 = 完全按你的配置顺序（默认）',
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption, color: sub)),
                    ],
                  ),
                ),
                Switch(
                  value: _store.enabled,
                  onChanged: (v) async {
                    await _store.setEnabled(v);
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '记录点：首页/分类加载、详情加载、播放地址解析失败。'
            '⚠️ 播放成功率目前只有"失败"这一半（播放器开播回调还没接），'
            '所以播放列显示 `-`，不编数据。',
            style:
                TextStyle(fontSize: AppTheme.fontCaption, color: sub, height: 1.5),
          ),
          const SizedBox(height: 14),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text('还没有统计数据（用一会儿就有了）',
                    style:
                        TextStyle(fontSize: AppTheme.fontSubhead, color: sub)),
              ),
            )
          else ...[
            // 表头
            Row(
              children: [
                Expanded(
                    flex: 3,
                    child: Text('站点',
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: sub))),
                for (final h in const ['首页', '详情', '播放', '综合'])
                  Expanded(
                    child: Text(h,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: sub)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            for (final e in entries) _row(e, fg, sub, isDark),
          ],
        ],
      ),
    );
  }

  Widget _row(MapEntry<String, Map<String, int>> e, Color fg, Color sub,
      bool isDark) {
    final key = e.key;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTheme.fontCaption, color: fg)),
          ),
          for (final k in const ['home', 'detail', 'play'])
            Expanded(
              child: Text(_fmt(_store.rate(key, k)),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption, color: sub)),
            ),
          Expanded(
            child: Text('${(_store.score(key) * 100).round()}',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w600,
                    color: fg)),
          ),
        ],
      ),
    );
  }
}
