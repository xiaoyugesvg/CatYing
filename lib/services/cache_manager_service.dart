import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../hiker/services/hiker_builtin.dart';
import '../../hiker/services/hiker_files.dart';
import '../../reading/services/book_content_cache_service.dart';
import '../../reading/services/book_page_cache_service.dart';
import '../../reading/services/book_toc_cache.dart';
import '../../reading/services/chapter_text_cache.dart';
import '../../music/services/music_api.dart';
import '../../rss/services/rss_reader.dart';
import '../models/cache_store.dart';
import 'nodejs_manager.dart';

/// 缓存分类：模块（影视/直播/音乐/阅读/TMDB/海阔/观影同步/RSS）在前，
/// 「软件本身」收纳图片/数据/JS/临时文件等跨模块分类。
enum CacheModule {
  video('影视'),
  live('直播'),
  music('音乐'),
  reading('阅读'),
  tmdb('TMDB 缓存'),
  // ── 后加的模块（用户 2026-10-15 要求"把新模块也纳入缓存管理"）──────
  hiker('海阔'),
  // 原「网页(Webhtv)」：该模块已下线（用户 2026-10-16），
  // 它名下只剩「观影记录同步」的游标这一项 → 直接以那个功能命名。
  playbackSync('观影同步'),
  rss('RSS'),
  app('软件本身');

  const CacheModule(this.label);
  final String label;
}

/// 一个可管理的缓存项
class CacheEntryInfo {
  const CacheEntryInfo({
    required this.id,
    required this.label,
    required this.hint,
    required this.module,
    required this.size,
    required this.clear,
    this.skipOnClearAll = false,
  });

  final String id;
  final String label;

  /// 一句话说明"清了会怎样"（让用户敢点）
  final String hint;
  final CacheModule module;
  final int size;
  final Future<void> Function() clear;

  /// 「全部清除」时**跳过**这一项。
  ///
  /// 有些入口虽然挂在缓存管理里（方便单独查看/单独清），但内容其实是**用户数据**
  /// 或**清不掉就会坏功能**的东西：
  ///   · `js_source`  —— 已下载的 Spider 源脚本（清了要重新下载；且弹窗承诺不清）
  ///   · `hiker_files` —— 海阔文件区，可能含用户导入的规则包（如 Apollo）
  /// 批量"全部清除"不该顺手删掉它们。
  final bool skipOnClearAll;
}

/// **全 App 缓存管理**（统一入口）。
///
/// ── 为什么要有它 ──────────────────────────────────────────────
/// 之前的缓存清理散在三处：`SettingsController.clearCache()`、
/// `CacheSettingsPage`、`DataCleanupPage`，而且**只统计了一个总数**，
/// 用户没法知道"到底是影视占的，还是阅读占的"。
///
/// 现在按 [CacheModule] 分类：
///   · **软件本身**（图片缓存 / 临时文件）—— 最上面几排
///   · **影视 · 直播**（业务缓存）
///   · **音乐**（接口响应缓存，纯内存）
///   · **阅读**（正文缓存 / 分页缓存）
///
/// 每项都能**单独算大小、单独清**，并附一句"清了会怎样"。
///
/// ── 为什么单独一个服务而不是塞进 Controller ──────────────────
/// 它要同时 import 阅读的缓存服务、音乐的 API、影视的 CacheStore ——
/// 塞进 `SettingsController` 会把"设置页"变成三个模块的耦合点。
/// 独立的服务类把这份耦合收在一处，页面只管展示。
class CacheManagerService {
  CacheManagerService._();
  static final CacheManagerService instance = CacheManagerService._();

  /// 列出所有缓存项（含各自当前大小）。
  ///
  /// [onSize] 每算完一项回调一次 —— 页面据此逐条刷新，
  /// 不必等全部算完（临时目录大时 `_dirSize` 可能要几百毫秒）。
  Future<List<CacheEntryInfo>> list({void Function()? onSize}) async {
    final out = <CacheEntryInfo>[];

    // ── 影视（业务缓存：首页列表 / 详情 / 刮削 / 清晰度）──────────
    var bizBytes = 0;
    try {
      bizBytes = CacheStore.instance.cacheItemsByteSize();
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'video_biz',
        label: '业务缓存',
        hint: '首页列表 / 详情 / 刮削结果，清了会重新拉取',
        module: CacheModule.video,
        size: bizBytes,
        clear: () async {
          try {
            await CacheStore.instance.clearItemsCache();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── 直播（频道列表本地缓存，SP 键 live_channel_cache_v1|*）──────
    var liveBytes = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      liveBytes = prefs
          .getKeys()
          .where((k) => k.startsWith('live_channel_cache_v1'))
          .fold<int>(0, (a, k) => a + (prefs.getString(k)?.length ?? 0));
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'live_channel',
        label: '频道列表缓存',
        hint: '直播频道列表，清了下次打开重新拉取',
        module: CacheModule.live,
        size: liveBytes,
        clear: () async {
          try {
            final prefs = await SharedPreferences.getInstance();
            for (final k in prefs
                .getKeys()
                .where((x) => x.startsWith('live_channel_cache_v1'))
                .toList()) {
              await prefs.remove(k);
            }
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── 音乐 ──────────────────────────────────────────────────
    out.add(
      CacheEntryInfo(
        id: 'music_api',
        label: '接口响应缓存',
        hint: '歌单/搜索结果的短期缓存（纯内存，上限 60 条）',
        module: CacheModule.music,
        size: -1, // 内存态拿不到精确字节数，UI 显示"内存"
        clear: () async {
          try {
            MusicApi.instance.clearCache();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── 阅读 ──────────────────────────────────────────────────
    var contentBytes = 0;
    try {
      contentBytes = await BookContentCacheService.instance.sizeBytes();
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'reading_content',
        label: '正文缓存',
        hint: '已解析的书籍正文，清了下次打开会重新解析',
        module: CacheModule.reading,
        size: contentBytes,
        clear: () async {
          try {
            await BookContentCacheService.instance.clear();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    var pageBytes = 0;
    try {
      pageBytes = await BookPageCacheService.instance.sizeBytes();
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'reading_pagination',
        label: '分页缓存',
        hint: '分页度量结果，清了下次打开要重新排版（稍慢）',
        module: CacheModule.reading,
        size: pageBytes,
        clear: () async {
          try {
            await BookPageCacheService.instance.clear();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // 目录缓存（书架的“秒开”靠它）
    var tocBytes = 0;
    try {
      tocBytes = await BookTocCache.instance.sizeBytes();
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'reading_toc',
        label: '目录缓存',
        hint: '书架点书秒开用的章节列表；清了下次点开会重新联网取目录',
        module: CacheModule.reading,
        size: tocBytes,
        clear: () async {
          try {
            await BookTocCache.instance.clear();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // 章节正文缓存（纯文字章，10 分钟内有效）
    var textBytes = 0;
    try {
      textBytes = await ChapterTextCache.instance.sizeBytes();
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'reading_chapter_text',
        label: '章节正文缓存',
        hint: '最近读过的纯文字章节（10 分钟内有效），清了下次要重新联网取正文',
        module: CacheModule.reading,
        size: textBytes,
        clear: () async {
          try {
            await ChapterTextCache.instance.clear();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── TMDB 缓存（刮削数据 + 匹配记录）─────────────────────────
    var tmdbBytes = 0;
    try {
      tmdbBytes = CacheStore.instance.cacheItemsByteSizeByPrefix('tmdb:');
    } catch (_) {}
    var matchCount = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      matchCount = prefs
          .getKeys()
          .where((k) => k.startsWith('tmdb_match'))
          .length;
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'tmdb_scrape',
        label: '刮削数据缓存',
        hint: 'TMDB 搜索/详情/剧集结果，清了重新刮削',
        module: CacheModule.tmdb,
        size: tmdbBytes,
        clear: () async {
          try {
            await CacheStore.instance.clearItemsByPrefix('tmdb:');
          } catch (_) {}
        },
      ),
    );
    onSize?.call();
    out.add(
      CacheEntryInfo(
        id: 'tmdb_match',
        label: 'TMDB 匹配记录',
        hint: matchCount > 0 ? '已保存 $matchCount 条手动匹配，清了需重新匹配' : '暂无手动匹配记录',
        module: CacheModule.tmdb,
        size: -1,
        clear: () async {
          try {
            final prefs = await SharedPreferences.getInstance();
            for (final k in prefs
                .getKeys()
                .where((x) => x.startsWith('tmdb_match'))
                .toList()) {
              await prefs.remove(k);
            }
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── 海阔（hiker）：文件区 / 远端依赖 / 自带资源 ────────────────
    //   ⚠️ 文件区里可能有**用户自己导入的规则包**（如 Apollo）—— 它不是缓存，
    //      所以单独一项、提示写清"清了那批源会失效"，而不是混在"缓存"里悄悄删掉。
    var hikerFilesBytes = 0;
    try {
      // ⚠️ 排除 `libs/`：那是 `rc()` 远端依赖的缓存，下面单独一项 ——
      //    不排除会把同一份字节算两遍（总量虚高）
      final all = await HikerFiles.list();
      for (final e in all) {
        if (e.path == 'libs' || e.path.startsWith('libs/')) continue;
        hikerFilesBytes += e.size;
      }
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'hiker_files',
        label: '文件区（hiker://files）',
        hint: '规则读的数据文件；⚠️ 可能含你导入的规则包（如 Apollo），'
            '清了依赖它的源会失效',
        module: CacheModule.hiker,
        size: hikerFilesBytes,
        // 可能含用户导入的规则包 ⇒ 不参与「全部清除」（可在本页单独清）
        skipOnClearAll: true,
        clear: () async {
          try {
            await HikerFiles.clearAll();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    var hikerLibsBytes = 0;
    try {
      final d = await HikerFiles.dir();
      if (d != null) hikerLibsBytes = await _dirSize(Directory('${d.path}/libs'));
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'hiker_libs',
        label: '远端依赖缓存（rc）',
        hint: '规则用 rc()/requireCache() 下载的 JS，清了下次用到时重新下载',
        module: CacheModule.hiker,
        size: hikerLibsBytes,
        clear: () async {
          try {
            final d = await HikerFiles.dir();
            if (d != null) {
              await _deleteDirContents(Directory('${d.path}/libs'));
            }
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    var hikerBuiltinBytes = 0;
    try {
      final p = await HikerBuiltin.assetsDir();
      if (p.isNotEmpty) hikerBuiltinBytes = await _dirSize(Directory(p));
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'hiker_builtin',
        label: 'App 自带资源',
        hint: '随包资源（home.js / theme.js…）释放出来的副本，'
            '清了下次进海阔会自动重新铺',
        module: CacheModule.hiker,
        size: hikerBuiltinBytes,
        clear: () async {
          try {
            final p = await HikerBuiltin.assetsDir();
            if (p.isNotEmpty) await _deleteDirContents(Directory(p));
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── 观影记录同步：增量同步的**游标** ──────────────────────────
    //   游标是纯缓存（清了下次全量拉一次）；**墓碑不清** —— 它挡的是"远端已删除
    //   的记录又被拉回来"，清掉会让已删记录复活。
    var cursorBytes = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      cursorBytes = prefs.getString('webhtv_playback_cursors')?.length ?? 0;
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'playback_sync_cursor',
        label: '观影记录同步游标',
        hint: '增量同步的进度；清了下次会重新全量拉一次（不会丢记录）',
        module: CacheModule.playbackSync,
        size: cursorBytes,
        clear: () async {
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('webhtv_playback_cursors');
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── RSS：响应体缓存（纯内存、上限 80 条）────────────────────
    out.add(
      CacheEntryInfo(
        id: 'rss_body',
        label: '响应体缓存',
        hint: 'cacheFirst 源的响应体（纯内存，上限 80 条），清了下次重新抓',
        module: CacheModule.rss,
        size: -1, // 内存态，UI 显示"内存"
        clear: () async {
          try {
            RssReader.clearBodyCache();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── 图片（内存 + 磁盘）────────────────────────────────────
    var imageBytes = 0;
    try {
      imageBytes = PaintingBinding.instance.imageCache.currentSizeBytes;
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'image_memory',
        label: '内存图片缓存',
        hint: '当前会话已解码的图片，清了只影响滚动流畅度',
        module: CacheModule.app,
        size: imageBytes,
        clear: () async {
          try {
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    var diskImg = 0;
    try {
      // cached_network_image 把文件写在 getApplicationCacheDirectory() 里，
      // 所以直接量那个目录 —— 不用去碰 DefaultCacheManager 的内部 store
      //（它的目录字段不对外公开）。
      diskImg = await _dirSize(await getApplicationCacheDirectory());
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'image_disk',
        label: '磁盘图片缓存',
        hint: '封面/海报等网络图，清了会重新下载',
        module: CacheModule.app,
        size: diskImg,
        clear: () async {
          try {
            await DefaultCacheManager().emptyCache();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── 数据（页面数据缓存，与影视业务缓存同源：CacheStore items）────
    var dataBytes = 0;
    try {
      dataBytes = CacheStore.instance.cacheItemsByteSize();
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'data_pages',
        label: '页面数据缓存',
        hint: '首页列表 / 详情 / 刮削结果，清了会重新拉取',
        module: CacheModule.app,
        size: dataBytes,
        clear: () async {
          try {
            await CacheStore.instance.clearItemsCache();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── JS（源文件 JS 缓存）────────────────────────────────────
    out.add(
      CacheEntryInfo(
        id: 'js_source',
        label: '源 JS 缓存',
        hint: '已下载的 Spider 源脚本文件（弹窗承诺「全部清除」不动它，'
            '只在本页可单独清）',
        module: CacheModule.app,
        size: -1,
        skipOnClearAll: true,
        clear: () async {
          try {
            await NodeJSManager.instance.deleteSource();
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    // ── 临时文件 ──────────────────────────────────────────────
    var tmpBytes = 0;
    try {
      tmpBytes = await _dirSize(await getTemporaryDirectory());
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'temp_files',
        label: '临时文件',
        hint: '系统与第三方库的临时文件，可安全清理',
        module: CacheModule.app,
        size: tmpBytes,
        clear: () async {
          try {
            await _deleteDirContents(await getTemporaryDirectory());
          } catch (_) {}
        },
      ),
    );
    onSize?.call();

    return out;
  }

  /// 全部缓存的合计字节数（供设置页"清除应用缓存"那一行显示）。
  ///
  /// 与 [list] 用**同一份口径** —— 这一点很重要：
  /// 以前 `SettingsController.refreshCacheSize()` 自己算一遍、
  /// `clearCache()` 自己清一遍，两边的范围**不一致**
  /// （比如 refresh 算了 `getApplicationCacheDirectory()`，
  /// 而 clear 也清了它，但音乐/阅读的缓存两边都没覆盖）。
  /// 现在量什么、清什么，都由这里一处定义。
  static Future<int> totalSize() async {
    final all = await CacheManagerService.instance.list();
    // size < 0 表示"内存态"（拿不到精确字节），不计入
    return all.fold<int>(0, (a, e) => a + (e.size < 0 ? 0 : e.size));
  }

  /// 清空**某一模块**的全部缓存
  static Future<void> clearModule(
    List<CacheEntryInfo> all,
    CacheModule m,
  ) async {
    for (final e in all.where((x) => x.module == m)) {
      await e.clear();
    }
  }

  /// 清空全部
  ///
  /// ⚠️ 跳过 [CacheEntryInfo.skipOnClearAll] 的项（用户数据 / 清了会坏功能的）——
  /// 弹窗里也向用户承诺了"不会清除源文件 JS"，这里必须一致。
  static Future<void> clearAll(List<CacheEntryInfo> all) async {
    for (final e in all.where((x) => !x.skipOnClearAll)) {
      await e.clear();
    }
  }

  /// 人类可读的字节数
  static String formatSize(int bytes) {
    if (bytes < 0) return '内存';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  // ============================================================

  static Future<int> _dirSize(Directory dir) async {
    try {
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _deleteDirContents(Directory dir) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list(followLinks: false)) {
      try {
        await e.delete(recursive: true);
      } catch (_) {}
    }
  }
}
