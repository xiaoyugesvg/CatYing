import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/webhome/webhtv_playback_sync_service.dart';

/// 「观影记录同步」（原 Webhtv → 观影记录同步）。
///
/// 入口现为「设置 → 通用设置 → 观影记录同步」（Webhtv 模块下线后搬过来的，
/// 用户 2026-10-16）。
///
/// 协议来源：WebHomeTV 的《应用完整开发文档》第 13.4 节 **观影记录同步**，
/// 版本固定 `webhtv.playback.v1`（时间戳毫秒、进度毫秒）。
///
/// ── 四条通道（本页覆盖配置部分）──────────────────────────────
///   ① 只读 API   `GET/POST /api/playback/current?siteKey=`      ← 需本机 HTTP 服务
///   ② 本机写入   `POST /api/playback/progress` `/batch` `/delete` ← 需本机 HTTP 服务
///   ③ 远端同步   同一地址 `GET` → `{items, deleted, nextSince}`   ← 纯客户端
///   ④ Webhook    `POST <端点>`（进度 / 完播 / 删除）              ← 纯客户端
///
/// ── 本页做完了什么 ────────────────────────────────────────────
///   · 总开关 / 「允许本机 API 修改」开关
///   · **远端同步源**列表 + 独立弹窗表单（name / url / token / siteKeys /
///     syncOnStartup / intervalMinutes / maxItems≤1000）
///   · **Webhook 端点**列表 + 独立弹窗表单（name / url / token / 字段预设 / 启用）
///   · 全部落盘持久化
///
/// ── 尚未接入（页面上标注，不做假 UI）──────────────────────────
///   · ③ 的实际拉取合并（含 `nextSince` 游标、90 天删除墓碑、超 `maxItems` 不推进游标）
///   · ④ 的实际上报时机（周期进度 / 暂停退出切集前 / 完播 / 历史页删除）
///   · ①② 的本机 HTTP 服务 —— 与「局域网管理页」同一套基础设施，排在第 8 步
///
/// ── 协议摘要（照 WebHomeTV 文档 13.4 抄下来，供接引擎时直接照做）────
///
/// **Webhook 上报**（③④共用同一地址；`POST <端点>`）
///   请求头：`Content-Type: application/json`、`X-WebHTV-Timestamp`(秒)、
///   `X-WebHTV-Token`(可选)、`X-WebHTV-Webhook-Id`(=eventId)、
///   `X-WebHTV-Dedupe-Key`、`X-WebHTV-Config-Key`、`X-WebHTV-Config-Name`、
///   `Idempotency-Key`(=eventId)
///   事件：`playback.progress`（周期进度；**暂停/退出/切集/切线路前补发最终进度**）、
///         `playback.ended`（自然完播）、`playback.deleted`（带 `scope` + `deletedAt`）
///   字段预设：
///     基础 = schema/event/eventId/timestamp/scope/deletedAt/sessionId/dedupeKey/
///            cid/configKey/configName/historyKey/siteKey/siteName/vodId/vodName/
///            vodPic/flag/episodeName/state/positionMs/durationMs/progress/speed/completed
///            （**删除事件不发进度字段**）
///     标准 = 基础 + appVersion/client
///     完整 = 标准 + episodeUrl/episodeIndex/clientKey
///   删除事件示例：
///     {"schema":"webhtv.playback.v1","event":"playback.deleted","eventId":"…",
///      "timestamp":…,"deletedAt":…,"scope":"item","configKey":"sha256(url)",
///      "historyKey":"siteKey@@@vodId@@@1","siteKey":"…","vodId":"…"}
///
/// **远端拉取**（③；同一地址 `GET`）
///   请求头：`X-WebHTV-Token` / `-Config-Key` / `-Config-Name` /
///   `-Since`(上次的 nextSince，可选) / `-Limit`(本次 maxItems)
///   响应：`{items:[{configKey,siteKey,vodId,vodName,vodPic,flag,episodeName,episodeUrl,
///   positionMs,durationMs,speed,completed,updatedAt}],
///   deleted:[{configKey,historyKey,siteKey,vodId,scope,deletedAt}],
///   nextSince, hasMore}`
///   规则：
///     · 带 `configKey` 的先映射本机已配接口，**映射不到就跳过**；不带则按当前接口写入
///     · 删除项也可能混在 `items/changes` 里，用 `action:"delete"` / `deleted:true` /
///       `event:"playback.deleted"` 标识
///     · 删除定位：`historyKey` 或 `siteKey+vodId`（scope=item）／`siteKey`+scope=site／
///       scope=all（当前 configKey 全量）
///     · **`deletedAt` 之前更旧的进度要被跳过**（阻止旧进度复活）；墓碑保留 **90 天**
///     · **响应条数 > maxItems 时不推进游标**，避免未处理变更永久丢失
///     · 游标按 `configKey` 存，下次用 `X-WebHTV-Since` 发回
class WebhtvPlaybackSyncStore extends ChangeNotifier {
  WebhtvPlaybackSyncStore._();
  static final WebhtvPlaybackSyncStore instance = WebhtvPlaybackSyncStore._();

  static const String _kEnabled = 'webhtv_playback_enabled';
  static const String _kAllowWrite = 'webhtv_playback_allow_write';
  static const String _kRemotes = 'webhtv_playback_remotes';
  static const String _kWebhooks = 'webhtv_playback_webhooks';

  bool _enabled = false;
  bool _allowLocalApiWrite = false;
  List<PlaybackRemoteSource> _remotes = [];
  List<PlaybackWebhookEndpoint> _webhooks = [];
  bool _loaded = false;

  bool get enabled => _enabled;

  /// 是否已从磁盘读过配置（引擎会先 ensure 一次）
  bool get loaded => _loaded;

  /// 「允许本机 API 修改」：开着才能用 ①② 的写入/清理（只读不受影响）
  bool get allowLocalApiWrite => _allowLocalApiWrite;
  List<PlaybackRemoteSource> get remotes => List.unmodifiable(_remotes);
  List<PlaybackWebhookEndpoint> get webhooks => List.unmodifiable(_webhooks);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? false;
      _allowLocalApiWrite = prefs.getBool(_kAllowWrite) ?? false;
      _remotes = _decodeList(prefs.getString(_kRemotes), PlaybackRemoteSource.fromJson);
      _webhooks = _decodeList(prefs.getString(_kWebhooks), PlaybackWebhookEndpoint.fromJson);
    } catch (_) {
      // 失败不置位 ⇒ 下次进入本页重试；否则一次偶发失败会让同步源列表
      // 整个会话都是空的（而且用户一保存就会用空表覆盖磁盘）
      return;
    }
    _loaded = true;
    notifyListeners();
  }

  static List<T> _decodeList<T>(
      String? raw, T? Function(Map<String, dynamic>) build) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final l = jsonDecode(raw);
      if (l is! List) return [];
      return l
          .whereType<Map>()
          .map((e) => build(Map<String, dynamic>.from(e)))
          .whereType<T>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, _enabled);
      await prefs.setBool(_kAllowWrite, _allowLocalApiWrite);
      await prefs.setString(
          _kRemotes, jsonEncode(_remotes.map((e) => e.toJson()).toList()));
      await prefs.setString(
          _kWebhooks, jsonEncode(_webhooks.map((e) => e.toJson()).toList()));
    } catch (_) {}
    notifyListeners();
    // 配置变更 → 通知引擎重建「启动/周期自动拉取」调度（引擎在构造时注册）
    onConfigChanged?.call();
  }

  /// 配置变更回调（由 `WebhtvPlaybackSyncService` 注册）。
  /// 本文件与引擎互相引用会造成循环 import，故用回调反向通知。
  void Function()? onConfigChanged;

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    await _save();
  }

  Future<void> setAllowLocalApiWrite(bool v) async {
    _allowLocalApiWrite = v;
    await _save();
  }

  Future<void> upsertRemote(PlaybackRemoteSource s) async {
    final i = _remotes.indexWhere((e) => e.url == s.url);
    if (i >= 0) {
      _remotes[i] = s;
    } else {
      _remotes.add(s);
    }
    await _save();
  }

  Future<void> removeRemote(String url) async {
    _remotes.removeWhere((e) => e.url == url);
    await _save();
  }

  Future<void> upsertWebhook(PlaybackWebhookEndpoint w) async {
    final i = _webhooks.indexWhere((e) => e.url == w.url);
    if (i >= 0) {
      _webhooks[i] = w;
    } else {
      _webhooks.add(w);
    }
    await _save();
  }

  Future<void> removeWebhook(String url) async {
    _webhooks.removeWhere((e) => e.url == url);
    await _save();
  }
}

/// 远端同步源（字段与文档 13.4.4 的表一致）
class PlaybackRemoteSource {
  const PlaybackRemoteSource({
    required this.url,
    this.name = '',
    this.token = '',
    this.siteKeys = const [],
    this.syncOnStartup = false,
    this.intervalMinutes = 0,
    this.maxItems = 500,
  });

  final String name;
  final String url;
  final String token;
  final List<String> siteKeys;
  final bool syncOnStartup;

  /// 0 = 不周期同步
  final int intervalMinutes;

  /// 单次最多处理条数（上限 1000）
  final int maxItems;

  String get displayName => name.trim().isNotEmpty
      ? name.trim()
      : (Uri.tryParse(url)?.host ?? url);

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'token': token,
        'siteKeys': siteKeys,
        'syncOnStartup': syncOnStartup,
        'intervalMinutes': intervalMinutes,
        'maxItems': maxItems,
      };

  static PlaybackRemoteSource? fromJson(Map<String, dynamic> j) {
    final url = (j['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    return PlaybackRemoteSource(
      name: (j['name'] ?? '').toString(),
      url: url,
      token: (j['token'] ?? '').toString(),
      siteKeys: (j['siteKeys'] is List)
          ? (j['siteKeys'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
          : const [],
      syncOnStartup: j['syncOnStartup'] == true,
      intervalMinutes: (j['intervalMinutes'] as num?)?.toInt() ?? 0,
      maxItems: ((j['maxItems'] as num?)?.toInt() ?? 500).clamp(1, 1000),
    );
  }
}

/// Webhook 端点
class PlaybackWebhookEndpoint {
  const PlaybackWebhookEndpoint({
    required this.url,
    this.name = '',
    this.token = '',
    this.preset = WebhookPreset.standard,
    this.enabled = true,
  });

  final String name;
  final String url;
  final String token;

  /// 字段预设：基础 / 标准 / 完整（文档要求"匿名预设不能形成完整同步记录"）
  final WebhookPreset preset;
  final bool enabled;

  String get displayName => name.trim().isNotEmpty
      ? name.trim()
      : (Uri.tryParse(url)?.host ?? url);

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'token': token,
        'preset': preset.name,
        'enabled': enabled,
      };

  static PlaybackWebhookEndpoint? fromJson(Map<String, dynamic> j) {
    final url = (j['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    var p = WebhookPreset.standard;
    for (final v in WebhookPreset.values) {
      if (v.name == '${j['preset']}') p = v;
    }
    return PlaybackWebhookEndpoint(
      name: (j['name'] ?? '').toString(),
      url: url,
      token: (j['token'] ?? '').toString(),
      preset: p,
      enabled: j['enabled'] != false,
    );
  }
}

enum WebhookPreset {
  basic('基础'),
  standard('标准'),
  full('完整');

  const WebhookPreset(this.label);
  final String label;
}

// ============================================================
// 顶层页：只显示两个开关 + 两个摘要（对齐文档 13.4 的入口形态）
// ============================================================

class WebhtvPlaybackSyncPage extends StatefulWidget {
  const WebhtvPlaybackSyncPage({super.key});

  @override
  State<WebhtvPlaybackSyncPage> createState() => _WebhtvPlaybackSyncPageState();
}

class _WebhtvPlaybackSyncPageState extends State<WebhtvPlaybackSyncPage> {
  final _store = WebhtvPlaybackSyncStore.instance;

  @override
  void initState() {
    super.initState();
    _store.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : AppTheme.textSecondary;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: fg),
        title: Text('观影记录同步',
            style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _switchCard(
            title: '总开关',
            subtitle: '关闭后不拉取、不上报（本机只读 API 也不可用）',
            value: _store.enabled,
            fg: fg,
            sub: sub,
            isDark: isDark,
            onChanged: (v) async {
              await _store.setEnabled(v);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 10),
          _switchCard(
            title: '允许本机 API 修改',
            subtitle: '开启后才允许通过本机 API 写入 / 清理观影进度（只读不受影响）',
            value: _store.allowLocalApiWrite,
            fg: fg,
            sub: sub,
            isDark: isDark,
            onChanged: (v) async {
              await _store.setAllowLocalApiWrite(v);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 16),
          _navCard(
            title: '远端同步源',
            value: '${_store.remotes.length} 个',
            subtitle: '从远端 API 拉取观影记录合并到本地（按 configKey 分空间）',
            icon: Icons.cloud_download_outlined,
            fg: fg,
            sub: sub,
            isDark: isDark,
            onTap: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const _RemoteSourcesPage()));
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 10),
          _navCard(
            title: 'Webhook 上报',
            value: '${_store.webhooks.length} 个',
            subtitle: '播放进度 / 完播 / 删除事件 POST 到你的服务器',
            icon: Icons.webhook_outlined,
            fg: fg,
            sub: sub,
            isDark: isDark,
            onTap: () async {
              await Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const _WebhooksPage()));
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.construction_rounded,
                        size: 16, color: AppTheme.textTertiary),
                    const SizedBox(width: 6),
                    Text('尚未接入',
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            fontWeight: FontWeight.w600,
                            color: fg)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '· 远端**实际拉取合并**（nextSince 游标 / 90 天删除墓碑 / 超 maxItems 不推进游标）\n'
                  '· Webhook **实际上报时机**（周期进度 / 暂停退出切集前 / 完播 / 历史页删除）\n'
                  '· 本机只读与写入 API（`/api/playback/*`）—— 需要 App 内 HTTP 服务，'
                  '与「局域网管理页」同一套基础设施，排在第 8 步\n'
                  '协议已按 WebHomeTV 文档 13.4 对齐，本页只完成配置与持久化。',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption, color: sub, height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchCard({
    required String title,
    required String subtitle,
    required bool value,
    required Color fg,
    required Color sub,
    required bool isDark,
    required ValueChanged<bool> onChanged,
  }) =>
      Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
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
                  Text(title,
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w600,
                          color: fg)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption, color: sub)),
                ],
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      );

  Widget _navCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color fg,
    required Color sub,
    required bool isDark,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : const Color(0xFFF4F5F7),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: sub),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(title,
                            style: TextStyle(
                                fontSize: AppTheme.fontSubhead,
                                fontWeight: FontWeight.w600,
                                color: fg)),
                        const SizedBox(width: 8),
                        Text(value,
                            style: TextStyle(
                                fontSize: AppTheme.fontCaption, color: sub)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: sub)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: sub),
            ],
          ),
        ),
      );
}

// ============================================================
// 二级页：远端同步源
// ============================================================

class _RemoteSourcesPage extends StatefulWidget {
  const _RemoteSourcesPage();

  @override
  State<_RemoteSourcesPage> createState() => _RemoteSourcesPageState();
}

class _RemoteSourcesPageState extends State<_RemoteSourcesPage> {
  final _store = WebhtvPlaybackSyncStore.instance;

  Future<void> _edit([PlaybackRemoteSource? src]) async {
    final nameC = TextEditingController(text: src?.name ?? '');
    final urlC = TextEditingController(text: src?.url ?? '');
    final tokenC = TextEditingController(text: src?.token ?? '');
    final keysC = TextEditingController(text: (src?.siteKeys ?? []).join(','));
    final intervalC =
        TextEditingController(text: '${src?.intervalMinutes ?? 0}');
    final maxC = TextEditingController(text: '${src?.maxItems ?? 500}');
    var onStart = src?.syncOnStartup ?? false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final fg = Theme.of(ctx).brightness == Brightness.dark
              ? Colors.white
              : AppTheme.textPrimary;
          Widget f(String label, TextEditingController c, String hint,
                  {int maxLines = 1}) =>
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: fg)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: c,
                      maxLines: maxLines,
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote, color: fg),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: hint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              );
          return AlertDialog(
            backgroundColor: AppTheme.backgroundSecondary,
            title: Text(src == null ? '新增远端同步源' : '编辑远端同步源',
                style: TextStyle(color: AppTheme.textPrimary)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    f('名称（可空，空则用 host）', nameC, '如 我的服务器'),
                    f('API 地址（必填，http 开头）', urlC,
                        'https://xxx/api/playback/sync'),
                    f('Token（可空，走 X-WebHTV-Token）', tokenC, ''),
                    f('只合并这些站点 key（可空，逗号分隔）', keysC, 'siteA,siteB'),
                    f('周期同步间隔（分钟，0=不周期）', intervalC, '0'),
                    f('单次最多条数（≤1000）', maxC, '500'),
                    Row(
                      children: [
                        Expanded(
                          child: Text('启动后自动同步',
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption, color: fg)),
                        ),
                        Switch(
                            value: onStart,
                            onChanged: (v) => setLocal(() => onStart = v)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('取消',
                    style: TextStyle(color: AppTheme.textTertiary)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('保存',
                    style: TextStyle(color: AppTheme.accentOnSurface)),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    final url = urlC.text.trim();
    if (!url.startsWith('http')) {
      AppToast.message('API 地址必须以 http 开头');
      return;
    }
    await _store.upsertRemote(PlaybackRemoteSource(
      url: url,
      name: nameC.text.trim(),
      token: tokenC.text.trim(),
      siteKeys: keysC.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      syncOnStartup: onStart,
      intervalMinutes: int.tryParse(intervalC.text.trim()) ?? 0,
      maxItems: (int.tryParse(maxC.text.trim()) ?? 500).clamp(1, 1000),
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : AppTheme.textSecondary;
    final list = _store.remotes;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: fg),
        title: Text('远端同步源',
            style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '新增',
            onPressed: () => _edit(),
            icon: Icon(Icons.add_rounded, color: fg),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('还没有远端同步源，点右上角「+」新增',
                    style:
                        TextStyle(fontSize: AppTheme.fontSubhead, color: sub)),
              ),
            )
          else
            for (final s in list)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : const Color(0xFFF4F5F7),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            fontWeight: FontWeight.w600,
                            color: fg)),
                    Text(s.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: sub)),
                    const SizedBox(height: 2),
                    Text(
                      '${s.syncOnStartup ? "启动同步" : "手动"} · '
                      '${s.intervalMinutes > 0 ? "每 ${s.intervalMinutes} 分钟" : "不周期"} · '
                      '最多 ${s.maxItems} 条'
                      '${s.token.isNotEmpty ? " · 带 token" : ""}'
                      '${s.siteKeys.isNotEmpty ? " · 限 ${s.siteKeys.length} 个站点" : ""}',
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption, color: sub),
                    ),
                    Row(
                      children: [
                        const Spacer(),
                        IconButton(
                          tooltip: '立即同步',
                          onPressed: () async {
                            AppToast.message('正在同步…');
                            try {
                              final r = await WebhtvPlaybackSyncService
                                  .instance
                                  .pull(s);
                              AppToast.message(
                                  '同步完成：合并 ${r.$1} 条，删除 ${r.$2} 条');
                            } catch (e) {
                              AppToast.error('同步失败：$e');
                            }
                          },
                          icon: Icon(Icons.sync_rounded, size: 18, color: sub),
                        ),
                        IconButton(
                          tooltip: '编辑',
                          onPressed: () => _edit(s),
                          icon:
                              Icon(Icons.edit_outlined, size: 18, color: sub),
                        ),
                        IconButton(
                          tooltip: '删除',
                          onPressed: () async {
                            await _store.removeRemote(s.url);
                            if (mounted) setState(() {});
                          },
                          icon: Icon(Icons.delete_outline,
                              size: 18, color: sub),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

// ============================================================
// 二级页：Webhook 端点
// ============================================================

class _WebhooksPage extends StatefulWidget {
  const _WebhooksPage();

  @override
  State<_WebhooksPage> createState() => _WebhooksPageState();
}

class _WebhooksPageState extends State<_WebhooksPage> {
  final _store = WebhtvPlaybackSyncStore.instance;

  Future<void> _edit([PlaybackWebhookEndpoint? src]) async {
    final nameC = TextEditingController(text: src?.name ?? '');
    final urlC = TextEditingController(text: src?.url ?? '');
    final tokenC = TextEditingController(text: src?.token ?? '');
    var preset = src?.preset ?? WebhookPreset.standard;
    var enabled = src?.enabled ?? true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final fg = Theme.of(ctx).brightness == Brightness.dark
              ? Colors.white
              : AppTheme.textPrimary;
          Widget f(String label, TextEditingController c, String hint) =>
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: fg)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: c,
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote, color: fg),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: hint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              );
          return AlertDialog(
            backgroundColor: AppTheme.backgroundSecondary,
            title: Text(src == null ? '新增 Webhook' : '编辑 Webhook',
                style: TextStyle(color: AppTheme.textPrimary)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    f('名称（可空）', nameC, '如 我的服务器'),
                    f('Webhook 地址（http 开头）', urlC, 'https://xxx/api/playback/sync'),
                    f('Token（可空）', tokenC, ''),
                    Text('字段预设',
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: fg)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final p in WebhookPreset.values)
                          GestureDetector(
                            onTap: () => setLocal(() => preset = p),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: p == preset
                                    ? AppTheme.accentSurface
                                    : AppTheme.backgroundTertiary,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: p == preset
                                      ? AppTheme.accentOnSurface
                                          .withValues(alpha: 0.5)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Text(p.label,
                                  style: TextStyle(
                                      fontSize: AppTheme.fontFootnote,
                                      color: p == preset
                                          ? AppTheme.accentOnSurface
                                          : fg)),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('（匿名/缺核心字段的预设形成不了完整同步记录）',
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: AppTheme.textTertiary)),
                    Row(
                      children: [
                        Expanded(
                          child: Text('启用',
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption, color: fg)),
                        ),
                        Switch(
                            value: enabled,
                            onChanged: (v) => setLocal(() => enabled = v)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('取消',
                    style: TextStyle(color: AppTheme.textTertiary)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('保存',
                    style: TextStyle(color: AppTheme.accentOnSurface)),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    final url = urlC.text.trim();
    if (!url.startsWith('http')) {
      AppToast.message('Webhook 地址必须以 http 开头');
      return;
    }
    await _store.upsertWebhook(PlaybackWebhookEndpoint(
      url: url,
      name: nameC.text.trim(),
      token: tokenC.text.trim(),
      preset: preset,
      enabled: enabled,
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : AppTheme.textSecondary;
    final list = _store.webhooks;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: fg),
        title: Text('Webhook 上报',
            style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '新增',
            onPressed: () => _edit(),
            icon: Icon(Icons.add_rounded, color: fg),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('还没有 Webhook 端点，点右上角「+」新增',
                    style:
                        TextStyle(fontSize: AppTheme.fontSubhead, color: sub)),
              ),
            )
          else
            for (final w in list)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : const Color(0xFFF4F5F7),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: w.enabled
                        ? AppTheme.accentOnSurface.withValues(alpha: 0.35)
                        : (isDark ? Colors.white12 : Colors.black12),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(w.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            fontWeight: FontWeight.w600,
                            color: fg)),
                    Text(w.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: sub)),
                    const SizedBox(height: 2),
                    Text(
                      '预设 ${w.preset.label}'
                      '${w.token.isNotEmpty ? " · 带 token" : ""}',
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption, color: sub),
                    ),
                    Row(
                      children: [
                        const Spacer(),
                        Switch(
                          value: w.enabled,
                          onChanged: (v) async {
                            await _store.upsertWebhook(PlaybackWebhookEndpoint(
                              url: w.url,
                              name: w.name,
                              token: w.token,
                              preset: w.preset,
                              enabled: v,
                            ));
                            if (mounted) setState(() {});
                          },
                        ),
                        IconButton(
                          tooltip: '编辑',
                          onPressed: () => _edit(w),
                          icon:
                              Icon(Icons.edit_outlined, size: 18, color: sub),
                        ),
                        IconButton(
                          tooltip: '删除',
                          onPressed: () async {
                            await _store.removeWebhook(w.url);
                            if (mounted) setState(() {});
                          },
                          icon: Icon(Icons.delete_outline,
                              size: 18, color: sub),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
