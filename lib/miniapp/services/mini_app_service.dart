import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show rootBundle;
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/live_service.dart';
import 'package:tvbox/services/network_manager.dart';
import 'package:tvbox/miniapp/models/mini_app.dart';
import 'package:tvbox/miniapp/services/builtin_mini_apps.dart';

/// 「程序」模块服务：管理导入的 TVBox 生态小程序配置。
///
/// - 持久化：SharedPreferences（`miniapp_list_v1`）
/// - 导入：网络 URL / 本地文件 / 手动粘贴 JSON
/// - 影视源：解析出的站点即时注册进 `ApiConfig.sourceBeanList`
///   - CMS 站点（type 0/1）key `app_<appId>[_<i>]` → 详情/播放走现有影视链路；
///   - Spider 站点（spider 为 JS URL）key `app_<appId>_s<i>`、type 3 →
///     由 Node 引擎加载，SpiderService 五接口承载；
/// - 频道：lives 数组保留在 rawJson，播放时交给 `LiveService`。
class MiniAppService extends GetxService {
  static MiniAppService get instance {
    if (!Get.isRegistered<MiniAppService>()) {
      Get.put<MiniAppService>(MiniAppService(), permanent: true);
    }
    return Get.find<MiniAppService>();
  }

  static const String _key = 'miniapp_list_v1';
  /// 程序分组名列表（允许空分组；顺序即 tab 顺序）
  static const String _kGroups = 'miniapp_groups_v1';

  /// 下载包大小上限（128MB，参考 huoyi market.dart）：防超大/恶意响应撑爆内存
  static const int _kMaxPackageBytes = 128 * 1024 * 1024;

  /// 市场条目带 md5 时的校验（防损坏/篡改；crypto 包 md5）
  static String _md5Hex(List<int> bytes) =>
      crypto.md5.convert(bytes).toString();

  /// 文件级备份（Documents，独立于 prefs plist）。
  /// 与订阅同理：进程被硬打断时整个 plist 可能丢失 ⇒ 小程序列表也一起没。
  static const String _backupName = 'miniapp_list.bak';

  Future<File> _backupFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/$_backupName');
  }

  Future<String?> _readBackup() async {
    try {
      final f = await _backupFile();
      if (!await f.exists()) return null;
      final txt = await f.readAsString();
      return txt.trim().isEmpty ? null : txt;
    } catch (e) {
      AppLog.instance.w('[MiniApp] 读文件备份失败: $e');
      return null;
    }
  }

  /// 上次用的「市场地址」——程序页 → 市场 Tab 的输入框会记住它（参考图里的
  /// 「市场地址（JSON）」那一栏，重进页面自动填回并加载）
  static const String _kMarketUrl = 'miniapp_market_url';

  /// 已安装程序列表
  final apps = <MiniApp>[].obs;

  /// 程序分组（tab 栏用；「全部」不在这里）
  final groups = <String>[].obs;

  bool _loaded = false;

  String _marketUrl = '';
  String get marketUrl => _marketUrl;

  Future<void> setMarketUrl(String url) async {
    final u = url.trim();
    if (u == _marketUrl) return;
    _marketUrl = u;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kMarketUrl, u);
    } catch (e) {
      AppLog.instance.w('[MiniApp] 保存市场地址失败: $e');
    }
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    _marketUrl = prefs.getString(_kMarketUrl) ?? '';
    groups.assignAll(
      (prefs.getStringList(_kGroups) ?? const <String>[])
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty),
    );
    var raw = prefs.getString(_key) ?? '';
    // prefs 空/损坏 → 用文件备份兜底（整域丢失后的自救）
    if (raw.trim().isEmpty) {
      final bak = await _readBackup();
      if (bak != null) {
        raw = bak;
        try {
          await prefs.setString(_key, raw);
        } catch (_) {}
        AppLog.instance.log('[MiniApp] prefs 为空，已从文件备份恢复列表');
      }
    }
    if (raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          apps.assignAll(
            list
                .whereType<Map>()
                .map((e) => MiniApp.fromJson(Map<String, dynamic>.from(e)))
                .toList(),
          );
          // 重启后把已装程序的影视源重新注册进视频源列表
          for (final app in apps) {
            // 老数据里可能只有 app.group、没有分组清单：补进 tab 列表
            if (app.group.isNotEmpty && !groups.contains(app.group)) {
              groups.add(app.group);
            }
            _registerVideoSources(app);
          }
        }
      } catch (e) {
        AppLog.instance.w('[MiniApp] 读取列表失败: $e');
      }
    }
    // 内置小程序：首次启动自动装进列表。
    // ⚠️ 必须**不阻塞**：包体有几 MB，解包要几百毫秒，而这里是 main() 的
    //    启动链路（ensureLoaded 被 await），卡在这里会拉长黑屏时间。
    unawaited(seedBuiltins());
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final body = jsonEncode(apps.map((a) => a.toJson()).toList());
    await prefs.setString(_key, body);
    try {
      await prefs.setStringList(_kGroups, groups.toList());
    } catch (_) {}
    // 文件备份（独立于 plist，进程被硬打断也能救回来）
    try {
      final f = await _backupFile();
      await f.writeAsString(body, flush: true);
    } catch (e) {
      AppLog.instance.w('[MiniApp] 写文件备份失败: $e');
    }
  }

  // ── 导入 ──────────────────────────────────────────────────────

  /// 从网络 URL 导入（下载 JSON 后走 [importRaw]）
  Future<({bool ok, String? error})> importFromUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return (ok: false, error: '地址不能为空');
    try {
      // 🔴 2026-10-27 修（复核遗留）：这里原来直连 `NetworkManager.getString`，
      //   而「智能导入 / 市场」都走 `_downloadWithMirrors`。后果是**手动粘贴
      //   raw.githubusercontent.com 的配置地址基本必失败**（国内直连不通），
      //   用户只能自己去加 ghproxy 前缀。统一走镜像回退，非 github 地址
      //   候选列表只有原地址一个，行为不变。
      final body =
          await _downloadWithMirrors(trimmed, asBytes: false) as String;
      if (body.trim().isEmpty) return (ok: false, error: '下载内容为空');
      return await importRaw(body, source: trimmed);
    } catch (e) {
      return (ok: false, error: '下载失败: $e');
    }
  }

  /// 从本地文件导入
  Future<({bool ok, String? error})> importFromFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return (ok: false, error: '文件不存在');
      final body = await file.readAsString();
      return await importRaw(body, source: path);
    } catch (e) {
      return (ok: false, error: '读取失败: $e');
    }
  }

  /// 从粘贴的 JSON 文本导入
  Future<({bool ok, String? error})> importFromText(String text) =>
      importRaw(text, source: '手动粘贴');

  // ── 小程序市场（顶层 `{"apps":[…]}`，ant-video 市场格式）────────

  /// 拉取市场清单。返回 null = 「这不是市场清单」（交给普通配置导入）；
  /// 网络异常照常抛出，由调用方兜。
  Future<List<MiniAppMarketEntry>?> fetchMarket(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    // 带镜像回退：市场清单也可能挂在 GitHub 上
    final body = await _downloadWithMirrors(trimmed, asBytes: false) as String;
    if (!looksLikeMiniAppMarket(body)) return null;
    final list = parseMiniAppMarket(body);
    return list.isEmpty ? null : list;
  }

  /// 智能导入（一次下载搞定）：
  /// - 内容是市场清单 `{"apps":[…]}` → 返回 [market]，由 UI 打开市场页（列出 + 安装）
  /// - 否则按普通 TVBox 配置导入
  Future<({bool ok, String? error, List<MiniAppMarketEntry>? market})>
  importUrlSmart(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return (ok: false, error: '地址不能为空', market: null);
    try {
      final body =
          await _downloadWithMirrors(trimmed, asBytes: false) as String;
      if (body.trim().isEmpty) {
        return (ok: false, error: '下载内容为空', market: null);
      }
      if (looksLikeMiniAppMarket(body)) {
        final list = parseMiniAppMarket(body);
        if (list.isNotEmpty) return (ok: true, error: null, market: list);
      }
      final r = await importRaw(body, source: trimmed);
      return (ok: r.ok, error: r.error, market: null);
    } catch (e) {
      return (ok: false, error: '下载失败: $e', market: null);
    }
  }

  /// 把 zip 解到 `<Documents>/miniapps/<appId>/`，返回其中的 manifest 文本
  Future<String> _unpackZipToDir(List<int> bytes, String appId) async {
    final dir = await _appDir(appId);
    await dir.create(recursive: true);
    // 覆盖安装：先清空旧文件，避免残留旧版本资源
    for (final f in dir.listSync()) {
      try {
        f.deleteSync(recursive: true);
      } catch (_) {}
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    // 解包目录的规范化前缀（末尾带分隔符，避免 `/a/bc` 误判成 `/a/b` 的子路径）
    final basePath = dir.path.endsWith('/') ? dir.path : '${dir.path}/';
    for (final f in archive) {
      if (!f.isFile) continue;
      // 🔴 2026-10-14 修（zip slip 路径穿越）：
      //   `f.name` 是**压缩包条目里的字符串**，可以写成 `../../x` 甚至多级穿越；
      //   而下面那句 `out.parent.create(recursive: true)` 会照样把目录建到解包目录
      //   之外 —— 于是恶意 zip 能覆盖 Documents 下的关键文件，包括
      //   `sources.json`、`api_config` 的 `api_url.bak`、`prefs_mirror.json`。
      //   这里把目标路径规范化（吃掉 `..` / `.`）后强制校验仍在解包目录内，
      //   越界条目直接丢弃。（不用引 package:path：Uri.normalizePath 就够。）
      final outPath = Uri.file(
        '$basePath${f.name}',
      ).normalizePath().toFilePath();
      if (!_withinDir(outPath, basePath)) {
        continue; // 越界条目：静默丢弃（这是攻击/坏包场景，不是用户操作）
      }
      final out = File(outPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>);
    }
    final mf = File('${dir.path}/manifest.json');
    if (mf.existsSync()) {
      final body = await mf.readAsString();
      return body.trim().isEmpty ? '{}' : body;
    }
    // ── 兼容性（参考 huoyi installer）：市场 zip 常把 manifest.json 放在
    //   子目录（外层包一层作者名/版本号目录），或带 `__MACOSX` / 隐藏目录。
    //   根目录没有时递归找（最多 3 层），找到后把该子目录内容**提升到包根**，
    //   这样 `localRoot` 仍是解包根、`entry` 相对路径不用改。
    final found = _findManifestDir(dir, depth: 0);
    if (found == null) return '{}';
    try {
      _promoteDir(found, dir);
    } catch (e) {
      AppLog.instance.w('[MiniApp] 提升 manifest 子目录失败: $e');
      return '{}';
    }
    final lifted = File('${dir.path}/manifest.json');
    if (lifted.existsSync()) {
      final body = await lifted.readAsString();
      return body.trim().isEmpty ? '{}' : body;
    }
    return '{}';
  }

  /// 递归找含 manifest.json 的目录（≤3 层，跳过 `__MACOSX` / `.` 开头目录）。
  static Directory? _findManifestDir(
    Directory dir, {
    required int depth,
  }) {
    if (depth > 3) return null;
    try {
      if (File('${dir.path}/manifest.json').existsSync()) return dir;
      if (depth >= 3) return null;
      for (final e in dir.listSync()) {
        if (e is! Directory) continue;
        final name = e.uri.pathSegments.isEmpty ? '' : e.uri.pathSegments.last;
        if (name == '__MACOSX' || name.startsWith('.')) continue;
        final hit = _findManifestDir(e, depth: depth + 1);
        if (hit != null) return hit;
      }
    } catch (_) {}
    return null;
  }

  /// 把 [from]（manifest 所在子目录）里的所有内容移动到 [to]（包根），
  /// 再删除空的 [from]。移动而非复制：避免与根目录已有内容冲突。
  static void _promoteDir(Directory from, Directory to) {
    for (final e in from.listSync()) {
      final dest = '${to.path}/${e.uri.pathSegments.last}';
      if (e is Directory) {
        // 递归移动目录内容
        _promoteDir(e, Directory(dest));
        try {
          if (e.existsSync()) e.deleteSync(recursive: true);
        } catch (_) {}
      } else if (e is File) {
        File(dest).parent.createSync(recursive: true);
        e.copySync(dest);
      }
    }
  }

  /// 判断 [path] 是否落在 [dirPath] 目录内（分隔符归一化后再比）。
  ///
  /// 🔴 2026-10-27 修：原来直接 `outPath.startsWith(basePath)`，而
  ///   `Uri.file(...).normalizePath().toFilePath()` 在 **Windows 上返回反斜杠**
  ///   （`C:\a\b\manifest.json`），和 `basePath` 末尾那个 `/` 对不上 ⇒
  ///   **每一条都被判成越界、整个 zip 解出来是空目录**（静默失败）。
  ///   iOS/Android 路径本来就用 `/`，所以真机一直没暴露；桌面端 zip 安装
  ///   （以及内置小程序安装）因此完全失效。归一化后两边都成立。
  ///
  /// ⚠️ 不要改成"只比字符串前缀"而省掉 normalizePath：`..` 必须在**比较之前**
  ///   被吃掉，否则 `a/../../evil` 这种会绕过校验。
  static bool _withinDir(String path, String dirPath) {
    final p = path.replaceAll('\\', '/');
    var d = dirPath.replaceAll('\\', '/');
    if (!d.endsWith('/')) d = '$d/';
    return p.startsWith(d);
  }

  // ── 下载（带 GitHub 镜像回退）────────────────────────────────
  //
  // 市场里的包/清单基本都挂在 raw.githubusercontent.com 上（xsc.json 的条目就是
  // `ghfast.top` 包一层）。国内直连基本不通，而单个镜像经常抽风/限速/返回 404 页
  // ⇒ 「加载市场」和「安装」会卡死在一个镜像上直到超时。
  // 这里统一成：**原地址 → 逐个镜像包一层**，谁先成功用谁（失败的要靠内容校验剔除，
  // 因为镜像返回的 HTML 错误页也是"非空"）。
  static const _ghMirrors = <String>[
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://ghproxy.net/',
    'https://gh.llkk.cc/',
    'https://ghproxy.cc/',
  ];

  /// 抹掉已有的镜像前缀，还原成 GitHub 原始地址
  static String _stripGhMirror(String url) {
    for (final m in _ghMirrors) {
      if (url.startsWith(m)) return url.substring(m.length);
    }
    return url;
  }

  /// 下载 zip（bytes）或 manifest（String），带 GitHub 镜像回退
  Future<Object> _downloadWithMirrors(
    String url, {
    required bool asBytes,
  }) async {
    final original = url.trim();
    final raw = _stripGhMirror(original);
    final candidates = <String>[original];
    if (raw != original) candidates.add(raw);
    if (raw.contains('githubusercontent.com') || raw.contains('github.com')) {
      for (final m in _ghMirrors) {
        final c = '$m$raw';
        if (!candidates.contains(c)) candidates.add(c);
      }
    }

    Object? lastErr;
    for (final c in candidates) {
      try {
        if (asBytes) {
          final b = await NetworkManager.instance.getData(c);
          // ZIP 魔数 PK\x03\x04：镜像返回的 404/HTML 页也是"非空"，必须校验
          if (b.length > 4 && b[0] == 0x50 && b[1] == 0x4B) {
            // 上限防护（参考 huoyi market.dart）：超大包/恶意响应会撑爆内存
            if (b.length > _kMaxPackageBytes) {
              throw Exception(
                '包超过 ${(_kMaxPackageBytes / (1024 * 1024)).round()}MB 上限');
            }
            return b;
          }
        } else {
          final s = await NetworkManager.instance.getString(c);
          // manifest / 市场清单都是 JSON，必须是对象/数组开头
          final t = s.trimLeft();
          if (t.startsWith('{') || t.startsWith('[')) return s;
        }
      } catch (e) {
        lastErr = e;
      }
      AppLog.instance.w('[MiniApp] 该源不可用，换下一个: $c');
    }
    if (lastErr != null) throw lastErr;
    throw Exception('所有下载源都不可用');
  }

  /// 本地 zip 小程序包安装（「本地文件」选 .zip）
  Future<({bool ok, String? error})> installFromZipFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return (ok: false, error: '文件不存在');
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return (ok: false, error: '文件为空');
      // appId 先用文件名占位，读到 manifest 再纠正为真实 appId
      final fallbackId = path
          .split(RegExp(r'[/\\]'))
          .last
          .replaceAll('.zip', '');
      var manifestBody = await _unpackZipToDir(bytes, fallbackId);
      final realId = _manifestAppId(manifestBody) ?? fallbackId;
      if (realId != fallbackId) {
        manifestBody = await _unpackZipToDir(bytes, realId);
        try {
          final stale = await _appDir(fallbackId);
          if (await stale.exists()) await stale.delete(recursive: true);
        } catch (_) {}
      }
      // 完整性校验（manifest 必须有 + entry 必须在包内且存在）
      final checkErr = await _validatePackage(manifestBody, realId);
      if (checkErr != null) {
        try {
          final d = await _appDir(realId);
          if (await d.exists()) await d.delete(recursive: true);
        } catch (_) {}
        return (ok: false, error: checkErr);
      }
      final name = _manifestName(manifestBody) ?? fallbackId;
      final app = MiniApp(
        id: realId,
        name: name,
        type: 'webapp',
        source: (await _appDir(realId)).path,
        rawJson: manifestBody.isEmpty ? '{}' : manifestBody,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      final idx = apps.indexWhere((a) => a.id == app.id);
      if (idx >= 0) {
        // 重复安装 = 升级，保留原分组
        apps[idx] = MiniApp(
          id: app.id,
          name: app.name,
          type: app.type,
          source: app.source,
          rawJson: app.rawJson,
          createdAt: app.createdAt,
          group: apps[idx].group,
        );
      } else {
        apps.add(app);
      }
      await _persist();
      AppLog.instance.log('[MiniApp] 已安装本地 zip ${app.id}');
      return (ok: true, error: null);
    } catch (e) {
      return (ok: false, error: '安装失败: $e');
    }
  }

  /// 该 appId 是否已安装
  bool isInstalled(String appId) => apps.any((a) => a.id == appId);

  // ── 内置小程序（随 App 打包）──────────────────────────────────
  //
  // 装法与「本地文件」完全一致，只是包体来自 assets：
  //   assets/miniapps/xxx.zip → 解包到 <Documents>/miniapps/<appId>/
  //
  // 三个状态位：
  //   · `_kBuiltinVer`     appId → 已装的内置包版本（决定要不要覆盖更新）
  //   · `_kBuiltinRemoved` 用户主动删掉的内置 appId（删了别再自动装回来）

  static const String _kBuiltinVer = 'miniapp_builtin_ver_v1';
  static const String _kBuiltinRemoved = 'miniapp_builtin_removed_v1';

  /// 覆盖更新时要**保留**的数据文件（相对小程序目录）。
  /// 小程序自己的数据（如收藏/设置）就写在这些文件里，
  /// 整目录覆盖会把它们冲掉，所以先读出来、解包后再写回。
  static const List<String> _builtinKeepFiles = <String>[
    'default.db.json',
    'db.json',
    'config.json',
    'data.json',
  ];

  Map<String, int> _builtinVersions(SharedPreferences p) {
    try {
      final raw = p.getString(_kBuiltinVer) ?? '';
      if (raw.trim().isEmpty) return <String, int>{};
      final m = jsonDecode(raw);
      if (m is! Map) return <String, int>{};
      return m.map((k, v) => MapEntry(k.toString(), int.tryParse('$v') ?? 0));
    } catch (_) {
      return <String, int>{};
    }
  }

  Set<String> _builtinRemoved(SharedPreferences p) =>
      (p.getStringList(_kBuiltinRemoved) ?? const <String>[]).toSet();

  /// 还没装上的内置小程序（「内置程序」弹层用来显示「安装」按钮）
  List<BuiltinMiniApp> get uninstalledBuiltins =>
      kBuiltinMiniApps.where((b) => !isInstalled(b.appId)).toList();

  /// 启动时调用：把没装过的内置小程序装进列表。
  ///
  /// 幂等、可重复调用（版本没变就直接返回，不做任何 IO）。
  Future<void> seedBuiltins() async {
    for (final b in kBuiltinMiniApps) {
      try {
        await _seedOneBuiltin(b);
      } catch (e) {
        AppLog.instance.w('[MiniApp] 内置程序 ${b.appId} 安装失败: $e');
      }
    }
  }

  /// 安装/更新一个内置小程序。
  ///
  /// [force] = true：用户点「重新安装」/「安装」，无视"删过"标记，强制覆盖。
  Future<({bool ok, String? error})> installBuiltin(
    String appId, {
    bool force = false,
  }) async {
    final b = builtinById(appId);
    if (b == null) return (ok: false, error: '没有这个内置程序');
    try {
      return await _seedOneBuiltin(b, force: force);
    } catch (e) {
      return (ok: false, error: '安装失败: $e');
    }
  }

  Future<({bool ok, String? error})> _seedOneBuiltin(
    BuiltinMiniApp b, {
    bool force = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final removed = _builtinRemoved(prefs);
    final versions = _builtinVersions(prefs);
    final idx = apps.indexWhere((a) => a.id == b.appId);
    final seededVer = versions[b.appId] ?? 0;

    // 用户删过 → 不再自动装（除非他自己点了「安装」）
    if (!force && idx < 0 && removed.contains(b.appId)) {
      return (ok: false, error: '已被删除');
    }
    // 已是最新内置版本 → 什么都不用做
    if (!force && idx >= 0 && seededVer >= b.version) {
      return (ok: true, error: null);
    }
    // 已经装着同 appId 的程序、但**不是**我们装的（seededVer==0，
    // 比如用户自己从「本地文件」装了同一个包）→ 不覆盖人家的东西，只记版本
    if (!force && idx >= 0 && seededVer == 0) {
      versions[b.appId] = b.version;
      try {
        await prefs.setString(_kBuiltinVer, jsonEncode(versions));
      } catch (_) {}
      return (ok: true, error: null);
    }

    // ── 读 assets 里的 zip ──────────────────────────────────
    final data = await rootBundle.load(b.assetZip);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (bytes.length <= 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      return (ok: false, error: '内置包损坏（不是 zip）');
    }

    // ── 覆盖前先把它自己的数据文件捞出来 ────────────────────
    final dir = await _appDir(b.appId);
    final kept = <String, List<int>>{};
    if (idx >= 0) {
      for (final name in _builtinKeepFiles) {
        try {
          final f = File('${dir.path}/$name');
          if (await f.exists()) kept[name] = await f.readAsBytes();
        } catch (_) {}
      }
    }

    // ── 解包（内部会先清空目录）────────────────────────────
    var manifestBody = await _unpackZipToDir(bytes, b.appId);
    final realId = _manifestAppId(manifestBody) ?? b.appId;
    if (realId != b.appId) {
      // 包里 appId 与注册表不一致：按包里的 appId 重解一次，避免目录错位
      AppLog.instance.w(
        '[MiniApp] 内置包 appId 不一致（注册表 ${b.appId} / 包内 $realId），按包内 id 安装',
      );
      manifestBody = await _unpackZipToDir(bytes, realId);
    }
    // 内置包完整性校验（manifest + entry，缺一不可）
    final checkErr = await _validatePackage(manifestBody, realId);
    if (checkErr != null) {
      return (ok: false, error: checkErr);
    }
    final finalDir = await _appDir(realId);

    // ── 数据文件写回 ───────────────────────────────────────
    for (final e in kept.entries) {
      try {
        await File('${finalDir.path}/${e.key}').writeAsBytes(e.value);
      } catch (err) {
        AppLog.instance.w('[MiniApp] 恢复数据文件 ${e.key} 失败: $err');
      }
    }

    final name = _manifestName(manifestBody) ?? b.name;
    final app = MiniApp(
      id: realId,
      name: name,
      type: 'webapp',
      source: finalDir.path,
      rawJson: manifestBody.isEmpty ? '{}' : manifestBody,
      createdAt: idx >= 0
          ? apps[idx].createdAt
          : DateTime.now().millisecondsSinceEpoch,
      // 已装过就保留用户自己分的组
      group: idx >= 0 ? apps[idx].group : b.group,
    );
    if (idx >= 0) {
      apps[idx] = app;
    } else {
      apps.add(app);
    }

    versions[realId] = b.version;
    removed.remove(realId); // 又装上了，撤销"用户删过"的标记
    try {
      await prefs.setString(_kBuiltinVer, jsonEncode(versions));
      await prefs.setStringList(_kBuiltinRemoved, removed.toList());
    } catch (_) {}
    await _persist();
    AppLog.instance.log(
      '[MiniApp] 内置程序 ${b.appId} 已就绪（v${b.version}）→ ${finalDir.path}',
    );
    return (ok: true, error: null);
  }

  /// 安装市场项 → `type=webapp` 的网页型小程序
  /// - `url` 指向 **manifest.json**（在线站点型）：按 manifest 打开**远端页面**；
  /// - `url` 指向 **zip**：下载解包到 `<Documents>/miniapps/<appId>/`，
  ///   按目录内的 manifest 打开本地页面。
  Future<({bool ok, String? error})> installMarketEntry(
    MiniAppMarketEntry e,
  ) async {
    try {
      var name = e.name;
      late String source;
      var manifestBody = '{}';
      // zip 包：解包目录以**包内 manifest 的 appId** 为准（与 id 一致，避免错位）
      var realId = e.appId;

      if (e.isZip) {
        final bytes =
            await _downloadWithMirrors(e.url, asBytes: true) as List<int>;
        if (bytes.isEmpty) return (ok: false, error: '下载内容为空');
        // 市场条目带 md5 时校验（防损坏/篡改；不带则跳过）
        if (e.md5.isNotEmpty) {
          final actual = _md5Hex(bytes);
          if (actual != e.md5) {
            return (ok: false, error: '包校验失败（md5 不符），可能下载被拦截或文件损坏');
          }
        }
        manifestBody = await _unpackZipToDir(bytes, e.appId);
        realId = _manifestAppId(manifestBody) ?? e.appId;
        if (realId != e.appId) {
          manifestBody = await _unpackZipToDir(bytes, realId);
        }
        // 完整性校验（manifest + entry）
        final checkErr = await _validatePackage(manifestBody, realId);
        if (checkErr != null) {
          return (ok: false, error: checkErr);
        }
        name = _manifestName(manifestBody) ?? e.name;
        source = (await _appDir(realId)).path;
      } else {
        manifestBody =
            await _downloadWithMirrors(e.url, asBytes: false) as String;
        name = _manifestName(manifestBody) ?? e.name;
        final base = e.url.substring(0, e.url.lastIndexOf('/') + 1);
        source = '$base${_manifestEntry(manifestBody)}';
      }

      final app = MiniApp(
        id: realId, // 与解包目录一致：重复安装 = 升级，卸载/升级不会错位
        name: name,
        type: 'webapp',
        source: source,
        rawJson: manifestBody.isEmpty ? '{}' : manifestBody,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      final idx = apps.indexWhere((a) => a.id == app.id);
      if (idx >= 0) {
        // 重复安装 = 升级，保留原分组
        apps[idx] = MiniApp(
          id: app.id,
          name: app.name,
          type: app.type,
          source: app.source,
          rawJson: app.rawJson,
          createdAt: app.createdAt,
          group: apps[idx].group,
        );
      } else {
        apps.add(app);
      }
      await _persist();
      AppLog.instance.log('[MiniApp] 已安装 ${e.appId} → $source');
      return (ok: true, error: null);
    } catch (e) {
      return (ok: false, error: '安装失败: $e');
    }
  }

  /// 安装目录：`<Documents>/miniapps/<appId>`
  Future<Directory> _appDir(String appId) async {
    final docs = await getApplicationDocumentsDirectory();
    final safe = appId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return Directory('${docs.path}/miniapps/$safe');
  }

  String? _manifestName(String body) {
    try {
      final m = jsonDecode(body) as Map;
      final n = (m['name'] ?? '').toString().trim();
      return n.isEmpty ? null : n;
    } catch (_) {
      return null;
    }
  }

  String? _manifestAppId(String body) {
    try {
      final m = jsonDecode(body) as Map;
      // 兼容三形态（huoyi manifest 同款）：官方 `appId`，市场常见 `id`，老包 `app_id`
      for (final key in const ['appId', 'id', 'app_id']) {
        final v = (m[key] ?? '').toString().trim();
        if (v.isNotEmpty) return v;
      }
    } catch (_) {}
    return null;
  }

  String _manifestEntry(String body) {
    try {
      final m = jsonDecode(body) as Map;
      final en = (m['entry'] ?? 'index.html').toString().trim();
      return en.isEmpty ? 'index.html' : en;
    } catch (_) {
      return 'index.html';
    }
  }

  /// 解包后完整性校验：manifest 必须有效 + entry 必须在包目录内且存在。
  /// 返回错误文案；通过返回 null。（node:// 入口由后端提供，跳过本地文件校验）
  Future<String?> _validatePackage(String manifestBody, String appId) async {
    final probe = manifestBody.trim();
    if (probe.isEmpty || probe == '{}') {
      return '这个包里没有 manifest.json，不是小程序包。\n'
          '（海阔视界规则请到「设置 → 海阔源管理」导入，不要在这里装）';
    }
    final entry = _manifestEntry(manifestBody);
    if (entry.startsWith('node://')) return null;
    final dir = await _appDir(appId);
    final base = dir.path.endsWith('/') ? dir.path : '${dir.path}/';
    final target = Uri.file('$base${entry.replaceAll('\\', '/')}')
        .normalizePath()
        .toFilePath();
    if (!_withinDir(target, base)) {
      return '这个包的入口页越界（$entry），不是合法的小程序包。';
    }
    if (!File(target).existsSync()) {
      return '这个包缺少入口页（$entry），不是完整的小程序包。';
    }
    return null;
  }

  /// 导入麦优直播订阅（单独的应用类型，不走 TVBox 配置解析）。
  ///
  /// [url] 为麦优分类接口地址（如 http://api.maiyoux.com:81/mf/json.txt），
  /// 保存为 `type=maiyou` 应用：rawJson 存 `{"type":"maiyou","url":...}`，
  /// 打开时按麦优协议拉取分类与频道。
  Future<({bool ok, String? error})> importMaiyou(
    String url, {
    String? nameOverride,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return (ok: false, error: '订阅地址不能为空');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      return (ok: false, error: '订阅地址格式不正确（需 http/https 链接）');
    }
    final name = (nameOverride?.trim().isNotEmpty ?? false)
        ? nameOverride!.trim()
        : '麦优直播';
    final app = MiniApp(
      id: 'app_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      type: 'maiyou',
      source: trimmed,
      rawJson: jsonEncode({'type': 'maiyou', 'url': trimmed}),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    apps.add(app);
    await _persist();
    return (ok: true, error: null);
  }

  /// 更新麦优订阅地址（独立管理页用）
  Future<({bool ok, String? error})> updateMaiyouUrl(
    MiniApp app,
    String url,
  ) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return (ok: false, error: '订阅地址不能为空');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      return (ok: false, error: '订阅地址格式不正确（需 http/https 链接）');
    }
    final idx = apps.indexWhere((a) => a.id == app.id);
    if (idx < 0) return (ok: false, error: '应用不存在');
    apps[idx] = MiniApp(
      id: app.id,
      name: app.name,
      type: 'maiyou',
      source: trimmed,
      rawJson: jsonEncode({'type': 'maiyou', 'url': trimmed}),
      createdAt: app.createdAt,
      group: app.group,
    );
    await _persist();
    return (ok: true, error: null);
  }

  /// 校验并保存一份配置（TVBox 配置）
  ///
  /// ⚠️ RSS / 资讯订阅源**不在这里**处理：App 已有独立的 RSS 模块
  /// （底栏「RSS」分类 + 设置里的「RSS 管理」），订阅源走那边导入；
  /// 这里只收 TVBox 配置，避免把订阅源错映射成"网页型小程序"。
  Future<({bool ok, String? error})> importRaw(
    String raw, {
    String source = '',
    String? nameOverride,
  }) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return (ok: false, error: '内容为空');

    // 预解析校验：必须是 JSON 且能提取名称
    final parsed = MiniAppParsed.parse(trimmed);
    if (parsed.cmsSites.isEmpty &&
        parsed.spiderSites.isEmpty &&
        parsed.liveGroups.isEmpty) {
      return (ok: false, error: '无法识别影视源或直播频道（需 TVBox 格式配置）');
    }

    final name = (nameOverride?.trim().isNotEmpty ?? false)
        ? nameOverride!.trim()
        : parsed.name;
    if (name.isEmpty) return (ok: false, error: '配置缺少名称');

    final app = MiniApp(
      id: 'app_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      type: 'tvbox',
      source: source,
      rawJson: trimmed,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    apps.add(app);
    _registerVideoSources(app);
    await _persist();
    return (ok: true, error: null);
  }

  /// 把程序的影视源注册进视频源列表（可重复调用，先清理旧的）
  void _registerVideoSources(MiniApp app) {
    final parsed = app.parsed;

    // 麦优订阅 / 网页型小程序都不注册影视源（都不是 TVBox 影视配置）
    if (app.isWebApp || parsed.maiyouUrl.isNotEmpty) return;

    // 清理该程序旧的注册（避免重复导入叠加）
    ApiConfig.instance.sourceBeanList.removeWhere(
      (s) => s.key.startsWith('${app.id}_'),
    );

    // ── CMS 站点（type 0/1，key `app_<id>_<i>`）────────────
    if (parsed.cmsSites.isNotEmpty) {
      for (var i = 0; i < parsed.cmsSites.length; i++) {
        final site = parsed.cmsSites[i];
        final key = parsed.cmsSites.length == 1
            ? '${app.id}_0'
            : '${app.id}_$i';
        ApiConfig.instance.sourceBeanList.removeWhere((s) => s.key == key);
        ApiConfig.instance.sourceBeanList.add(
          SourceBean(
            key: key,
            name: site.name,
            api: site.api,
            searchable: 1,
            filterable: 1,
            type: 1, // JSON CMS
          ),
        );
      }
    }

    // ── Spider 站点（type 3，key `app_<id>_s<i>`）───────────
    // 脚本源：api 为 .js/.py 脚本 URL 或 drpy2 运行时 URL；
    // ext 为 drpy2 模式下的站点脚本（普通脚本源为空）。
    // 由 Node/Python 引擎加载（引擎单源架构：同一时间只会加载第一个 type 3 源，
    // 程序 spider 源只有在主影视源不是 spider 时才会被加载）。
    if (parsed.spiderSites.isNotEmpty) {
      for (var i = 0; i < parsed.spiderSites.length; i++) {
        final site = parsed.spiderSites[i];
        final key = '${app.id}_s$i';
        ApiConfig.instance.sourceBeanList.removeWhere((s) => s.key == key);
        ApiConfig.instance.sourceBeanList.add(
          SourceBean(
            key: key,
            name: site.name,
            api: site.api.isNotEmpty ? site.api : site.ext,
            ext: site.ext,
            searchable: 1,
            filterable: 1,
            type: 3, // Spider（JS/Python 脚本）
          ),
        );
      }
    }
  }

  /// 新建分组（允许空分组，tab 始终可见）
  Future<bool> createGroup(String name) async {
    final n = name.trim();
    if (n.isEmpty) return false;
    if (groups.contains(n)) return false;
    groups.add(n);
    await _persist();
    return true;
  }

  /// 把某个程序移到指定分组（空字符串 = 未分组）
  Future<void> setGroup(MiniApp app, String group) async {
    final idx = apps.indexWhere((a) => a.id == app.id);
    if (idx < 0) return;
    final g = group.trim();
    apps[idx] = apps[idx].withGroup(g);
    if (g.isNotEmpty && !groups.contains(g)) {
      groups.add(g);
    }
    await _persist();
  }

  /// 拖动排序后落盘（列表顺序即自定义顺序）
  ///
  /// [alreadyAdjusted] 为 true 时表示调用方给的是**已经归一化过**的目标下标
  /// （`ReorderableListView.onReorderItem` 就是这种情况：框架已经替我们把
  /// "向下拖要减一"这一步做完了）。此时不能再减一次，否则会差一位。
  /// 旧的 `onReorder` 回调则必须保持 false。
  Future<void> reorder(
    int oldIndex,
    int newIndex, {
    bool alreadyAdjusted = false,
  }) async {
    if (oldIndex < 0 || oldIndex >= apps.length) return;
    if (!alreadyAdjusted && newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= apps.length) newIndex = apps.length - 1;
    final item = apps.removeAt(oldIndex);
    apps.insert(newIndex, item);
    await _persist();
  }

  /// 删除程序（同时从视频源列表移除其注册的源）
  Future<void> remove(MiniApp app) async {
    apps.removeWhere((a) => a.id == app.id);
    // 内置小程序：记一笔"用户删过"，否则下次启动 seedBuiltins() 又装回来了
    if (isBuiltinAppId(app.id)) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final removed = _builtinRemoved(prefs);
        if (removed.add(app.id)) {
          await prefs.setStringList(_kBuiltinRemoved, removed.toList());
        }
      } catch (e) {
        AppLog.instance.w('[MiniApp] 记录内置程序删除失败: $e');
      }
    }
    ApiConfig.instance.sourceBeanList.removeWhere(
      (s) => s.key.startsWith('${app.id}_'),
    );
    // 网页型小程序（zip 装到本地的）：把解包目录也删掉，别留垃圾
    if (app.isWebApp && !app.source.startsWith('http')) {
      try {
        final dir = Directory(app.source);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (e) {
        AppLog.instance.log('[MiniApp] 删除程序目录失败: $e');
      }
    }
    await _persist();
  }

  /// 把程序 lives 交给直播服务（直播页展示/播放）
  Future<void> playLives(MiniApp app) async {
    if (app.parsed.liveGroups.isEmpty) return;
    try {
      final decoded = jsonDecode(app.rawJson);
      if (decoded is Map) {
        final lives = decoded['lives'];
        if (lives is List) {
          await LiveService.instance.loadFromLivesJson(lives);
        }
      }
    } catch (e) {
      AppLog.instance.w('[MiniApp] 频道加载失败: $e');
    }
  }
}
