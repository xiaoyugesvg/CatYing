import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../../reading/services/book_content_cache_service.dart';
import '../../reading/services/book_page_cache_service.dart';
import '../../music/services/music_api.dart';
import '../models/cache_store.dart';

/// 缓存分类：**软件本身** vs **各模块**
enum CacheModule {
  app('软件本身'),
  video('影视 · 直播'),
  music('音乐'),
  reading('阅读');

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
  });

  final String id;
  final String label;

  /// 一句话说明"清了会怎样"（让用户敢点）
  final String hint;
  final CacheModule module;
  final int size;
  final Future<void> Function() clear;
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

    // ── 软件本身 ──────────────────────────────────────────────
    var imageBytes = 0;
    try {
      imageBytes = PaintingBinding.instance.imageCache.currentSizeBytes;
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'app_image_memory',
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
        id: 'app_image_disk',
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

    var tmpBytes = 0;
    try {
      tmpBytes = await _dirSize(await getTemporaryDirectory());
    } catch (_) {}
    out.add(
      CacheEntryInfo(
        id: 'app_temp',
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

    // ── 影视 · 直播 ───────────────────────────────────────────
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
  static Future<void> clearAll(List<CacheEntryInfo> all) async {
    for (final e in all) {
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
