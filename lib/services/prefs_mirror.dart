import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/services/app_log.dart';

/// 设置项的「**立刻落盘** + 文件镜像兜底」。
///
/// ── 主力机制：写完就落盘（2026-10-14，用户："为啥非要恢复备份呢"）──
/// iOS 的 `NSUserDefaults` 只在系统愿意的时候（周期/进后台/正常退出）写盘，
/// 所以磁盘上那份永远是"上次落盘的快照"；App 被硬杀时**本次会话改过的键**
/// 就丢了（表现：刚改的设置没了、别的还在）。
/// ⇒ [flushNow] 通过原生通道强制 `synchronize()`，做到"改了就是真的改了"。
/// 每个设置改动点调 [snapshotSoon]，400ms 后 [snapshot] → 里面会先落盘。
///
/// ── 兜底机制：文件镜像 ──────────────────────────────────────
/// 仍然保留一份全量快照写在**独立文件**（`<Documents>/prefs_mirror.json`），
/// 因为它能救两类 flush 救不了的场景：
///   · 进程在 `synchronize()` 之前就被信号杀掉（窗口极窄但存在）；
///   · 历史版本（没有 flush 通道）已经丢过的数据——下次启动逐键补齐拉回来。
/// ⚠️ 它是**第二道保险**，不是主路径。不要反过来依赖它。
class PrefsMirror {
  PrefsMirror._();

  static const String _fileName = 'prefs_mirror.json';

  /// 时间戳键：既写进镜像文件，也写进 prefs —— 用来判定"镜像和 plist 谁更新"。
  static const String _stampKey = '__prefs_mirror_stamp';

  static Timer? _timer;

  static Future<File?> _mirrorFile() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      return File('${d.path}/$_fileName');
    } catch (_) {
      return null;
    }
  }

  // ── 洞 P（2026-10-14）：阅读模块数据的**独立整块备份** ─────────────
  //
  // 为什么单独一份：阅读模块的持久化键（书源 / 书架 / 图书与漫画进度 / 收藏 /
  // 笔记 / 书签 / TTS 源 / 浏览与搜索历史 / z-library 账号 …）**没有**模块级
  // `.bak` —— 订阅、直播、小程序都各自有，唯独阅读没有，全靠上面那份全量镜像
  // 兜底。这份文件给它多加一层，而且**与主镜像不是同一个文件**（主镜像被写花
  // 或被清掉时它还在）。
  //
  // ⚠️ 白名单来自 2026-10-14 对 `lib/reading` 的扫描。**新增阅读设置项时要在这里
  //    同步加前缀 / 字面键**，否则那一项不会被这份备份覆盖 —— 这是它的已知边界，
  //    别当成"全覆盖"。

  static const String _readingFileName = 'reading_state.bak';

  /// 阅读 / 音乐模块的键前缀
  /// （这份文件叫 `reading_state.bak`，实际覆盖"阅读 + 音乐"两块的模块数据）
  static const List<String> _readingPrefixes = [
    'book_',
    'bookshelf_',
    'bs_book_',
    'comic_',
    'manga_',
    'reader_',
    'reading_',
    'tts_',
    'browse_',
    'zlibrary_',
    'qread_',
    'peer_transfer_',
    // 洞 X（2026-10-14）：音乐模块同样是 prefs 单点、没有模块级 .bak ——
    // 收藏 / 最近 / 队列 / 播放列表（`music.*.v1`）+ 第三方音源 + 音质设置。
    'music_',
    'music.',
  ];

  /// 前缀盖不住的字面键（漫画解密密钥、AI 配置、同步配置…）
  static const List<String> _readingLiterals = [
    'ai_service_config_v1',
    'sync_config_v1',
    'trim_whitespace_presets',
    'xxxmanga.woo.key',
    'dismissed_notification',
  ];

  /// **不参与镜像**的键：体积大且**可再生**。
  ///
  /// 2026-10-14 补：`music.thirdPartySources.v1` 是 MusicFree 插件源那一整块
  /// （50 个插件脚本正文，合计约 4 MB，见 `plugin_script_cache.dart` 的说明）。
  /// 镜像**是全量序列化**，而 `music.` 又在 `_readingPrefixes` 白名单里 ⇒
  /// 原来每 15s 要把这 4 MB 写**两遍**（主镜像 + `reading_state.bak`）≈ 8 MB IO。
  /// 它丢了也不影响用户（脚本有文件缓存 + 可重新下载），故从镜像里排除。
  static const Set<String> _skipKeys = {
    'music.thirdPartySources.v1',
  };

  static bool _isReadingKey(String k) {
    if (_readingLiterals.contains(k)) return true;
    for (final p in _readingPrefixes) {
      if (k.startsWith(p)) return true;
    }
    return false;
  }

  static Future<File?> _readingFile() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      return File('${d.path}/$_readingFileName');
    } catch (_) {
      return null;
    }
  }

  /// 把备份文件里的一个值写回 prefs；类型不认识时返回 false。
  static Future<bool> _writeKey(
      SharedPreferences prefs, String k, dynamic v) async {
    if (v is bool) {
      await prefs.setBool(k, v);
    } else if (v is int) {
      await prefs.setInt(k, v);
    } else if (v is double) {
      await prefs.setDouble(k, v);
    } else if (v is String) {
      await prefs.setString(k, v);
    } else if (v is List) {
      await prefs.setStringList(k, v.map((x) => x.toString()).toList());
    } else {
      return false;
    }
    return true;
  }

  /// 原生通道：让 NSUserDefaults **立刻写盘**（iOS 独有）。
  static const MethodChannel _flushChannel = MethodChannel('tvbox/prefs_flush');

  /// 强制把当前内存里的设置写进 plist —— "改了就是真的改了"靠的就是这一步。
  ///
  /// 不落盘的话，App 被硬杀（从多任务划掉 / 被信号杀死）时，**本次会话新写或
  /// 改过的键**会跟着内存一起消失，而磁盘上还是上一次落盘的旧快照。
  ///
  /// 通道缺失（非 iOS / 还没装到带原生实现的新包）时静默忽略：
  /// 退回到"依靠系统周期落盘"，不影响任何功能。
  static Future<void> flushNow() async {
    if (!Platform.isIOS) return;
    try {
      await _flushChannel.invokeMethod('flush');
    } catch (_) {
      // 忽略：镜像快照仍是第二道保险
    }
  }

  /// 启动**最早期**调用（必须早于任何服务读 prefs）。
  ///
  /// ── 2026-10-14 重写（用户："用菜单设置改了菜单栏，重启后又没了"）────
  /// 原实现是"**prefs 一个键都没有**才恢复"，实测**永远不触发**：
  ///   · NSUserDefaults 丢的通常不是"整个域"，而是**最近没来得及落盘的几个键**
  ///     （整域丢失只是极端情况）；只要还有任何一个键活着，prefs.getKeys()
  ///     就非空 ⇒ 这道门直接拦住，镜像里明明有正确值却救不回来。
  ///   · 日志实证：本次会话三次启动，只有 `[PrefsMirror] 自动快照已启动`，
  ///     从头到尾没有一条"从镜像恢复"，而订阅那边已经报 `prefs 丢失/损坏`。
  /// 现在改成**逐键补齐**：镜像里有、当前 prefs 里缺的键，补回去。
  ///
  /// ⚠️ 只补**缺失**的键：已存在的键一律不动 —— 否则会把用户刚改好的新值
  /// 用镜像里的旧值覆盖回去。
  static Future<void> restoreIfLost() async {
    try {
      final f = await _mirrorFile();
      if (f == null) return;
      var raw = (await f.exists()) ? await f.readAsString() : '';
      if (raw.isEmpty) {
        // 主镜像缺失/为空 → 退回上一代（见 snapshot 里的滚动逻辑）
        final prev = File('${f.path}.prev');
        if (await prev.exists()) {
          raw = await prev.readAsString();
          AppLog.instance.log('[PrefsMirror] 主镜像不可用，改用上一代 .prev');
        }
      }
      if (raw.isEmpty) return;
      Map<dynamic, dynamic> map;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return;
        map = decoded;
      } catch (e) {
        // 主镜像内容坏了 → 再试一次上一代
        final prev = File('${f.path}.prev');
        if (!await prev.exists()) return;
        final decoded2 = jsonDecode(await prev.readAsString());
        if (decoded2 is! Map) return;
        map = decoded2;
        AppLog.instance.log('[PrefsMirror] 主镜像损坏，改用上一代 .prev');
      }
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getKeys();
      // ── 判谁更新（2026-10-14 补的第二个洞）────────────────────────
      // 镜像里的 stamp 是"这份快照是什么时候拍的"；
      // prefs 里的 stamp 是"plist 真正落盘过的最新一次快照时间"。
      //   相等   → 设置那次确实落盘了 → **只补缺失的键**（绝不动已存在的，
      //            避免把用户后来改的新值回退成镜像里的旧值）；
      //   镜像更新 → plist 那次没落盘（通道不可用/写盘失败/被硬杀），
      //            镜像里的才是真值 → **允许覆盖已存在的旧值**。
      // 这一步堵的是"键还在、值是旧的"：光靠"只补缺失键"永远救不回这种，
      // 而用户反复修改时，plist 里几乎必然已经有一版旧键。
      final mirrorStamp = (map[_stampKey] as num?)?.toInt() ?? 0;
      final prefsStamp = prefs.getInt(_stampKey) ?? 0;
      final mirrorNewer = mirrorStamp > prefsStamp;
      var restored = 0;
      for (final e in map.entries) {
        final k = e.key.toString();
        if (k == _stampKey) continue;
        if (!mirrorNewer && existing.contains(k)) continue;
        if (!await _writeKey(prefs, k, e.value)) {
          continue; // 未知类型不认，跳过
        }
        restored++;
      }
      // 洞 P：阅读模块的独立备份 —— **只补缺失键**（不动已存在的值）。
      // 它不做 stamp 判定：这份文件没有"镜像 vs plist 谁更新"的证据，
      // 保守补齐即可；"键在、值是旧"那类由上面的主镜像负责。
      restored += await _restoreReadingBackup(prefs, existing);
      if (restored > 0) {
        // 对齐 stamp 并立刻落盘：否则每次启动都会再"恢复"一遍（无害但吵闹）。
        await prefs.setInt(_stampKey, mirrorStamp);
        await flushNow();
        AppLog.instance.log('[PrefsMirror] 已从文件镜像恢复 $restored 项设置'
            '（${mirrorNewer ? "镜像更新 → 覆盖旧值" : "仅补齐缺失键"}，镜像共 ${map.length} 项）');
      }
    } catch (e) {
      AppLog.instance.log('[PrefsMirror] 镜像恢复失败: $e');
    }
  }

  /// 洞 P：从 `<Documents>/reading_state.bak` 补齐**缺失**的阅读键。
  ///
  /// 与主镜像的区别：这里**只补缺失、不做 stamp 覆盖** —— 这份文件没有"谁更新"
  /// 的证据，保守补齐最安全（宁可少救，也不能回退掉更新的值）。
  static Future<int> _restoreReadingBackup(
      SharedPreferences prefs, Set<String> existing) async {
    try {
      final rf = await _readingFile();
      if (rf == null || !await rf.exists()) return 0;
      final raw = await rf.readAsString();
      if (raw.isEmpty) return 0;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return 0;
      var n = 0;
      for (final e in decoded.entries) {
        final k = e.key.toString();
        if (existing.contains(k)) continue; // 只补缺失
        if (await _writeKey(prefs, k, e.value)) n++;
      }
      if (n > 0) {
        AppLog.instance.log('[PrefsMirror] 已从阅读备份补齐 $n 项');
      }
      return n;
    } catch (e) {
      AppLog.instance.log('[PrefsMirror] 阅读备份恢复失败: $e');
      return 0;
    }
  }

  /// 把当前 prefs 全量快照写进镜像文件；**写之前先强制落盘**。
  static Future<void> snapshot() async {
    try {
      // 先落盘再读：保证"镜像里存的"和"plist 里最终留下的"是同一份，
      // 不会出现"镜像比 plist 新"（然后被逐键补齐又写回去）的错位。
      await flushNow();
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      if (keys.isEmpty) return;
      final map = <String, dynamic>{};
      for (final k in keys) {
        if (_skipKeys.contains(k)) continue; // 体积大且可再生，不进镜像
        final v = prefs.get(k);
        if (v == null) continue;
        if (v is List) {
          map[k] = v.map((x) => x.toString()).toList();
        } else if (v is bool || v is int || v is double || v is String) {
          map[k] = v;
        }
      }
      // 时间戳：给"镜像 vs plist 到底谁更新"一个可判定的依据（见 restoreIfLost）。
      final stamp = DateTime.now().millisecondsSinceEpoch;
      map[_stampKey] = stamp;
      final f = await _mirrorFile();
      if (f == null) return;
      // 🔴 2026-10-14（洞 P 的通用加固）：写之前先把上一份滚成 `.prev`。
      //   书源 / 书架 / 阅读进度 / Cookie 之外的那些**没有模块级 .bak** 的数据，
      //   全靠这一份镜像兜底 —— 镜像自己写花或被清掉就彻底没救。
      //   多留一代，成本几 KB，换"镜像单点失效"这个风险降一档。
      try {
        if (await f.exists()) {
          await f.copy('${f.path}.prev');
        }
      } catch (_) {
        /* 滚动失败不影响主流程 */
      }
      await f.writeAsString(jsonEncode(map), flush: true);
      // ── 洞 P：阅读模块那一块另存一份独立文件 ────────────────────────
      //   与主镜像**同一时刻**导出（同一份 map），**零新增挂钩点** ——
      //   跟着"改完即落盘 / 15s 周期 / 切后台"的节奏自动更新。
      final reading = <String, dynamic>{};
      for (final e in map.entries) {
        if (_isReadingKey(e.key)) reading[e.key] = e.value;
      }
      if (reading.isNotEmpty) {
        final rf = await _readingFile();
        if (rf != null) {
          try {
            await rf.writeAsString(jsonEncode(reading), flush: true);
          } catch (_) {
            /* 阅读备份失败不影响主流程 */
          }
        }
      }
      // 同一时间戳也写进 prefs，并**立刻落盘**（这一步必须 flush）。
      //
      // ⚠️ 2026-10-15 修正：原实现刻意不 flush，理由是"即便这条 stamp 没落盘，
      //   只会让'镜像更新'成立，而镜像是全量快照，恢复它是安全的（不会回退）"。
      //   该推理**只在"每次改设置都调 snapshotSoon"时成立**，而实际上并非所有
      //   设置项都挂了这个钩子（例如主题明暗/模块配色原来就没有）。于是 prefs 里
      //   的 stamp 会**结构性滞后一代**（每次 snapshot 开始时 flushNow 落的是
      //   上一版的 stamp）⇒ 每次启动 `mirrorNewer` 恒为真 ⇒ 走"覆盖已存在键"
      //   分支 ⇒ 上次快照之后改过的设置，会被镜像里的旧值**回退**掉。
      //   flush 之后：正常路径下两边 stamp 相等 ⇒ 只补缺失键（绝不回退新值）；
      //   而真的"plist 没落盘"时 flush 一样会失败、stamp 仍滞后 ⇒ 依旧走覆盖分支
      //   完成救援。两全。
      await prefs.setInt(_stampKey, stamp);
      await flushNow();
    } catch (e) {
      AppLog.instance.log('[PrefsMirror] 镜像写入失败: $e');
    }
  }

  /// 起一个低频周期快照（默认 15s）。
  ///
  /// 为什么用轮询而不是 hook 每一次 prefs 写入：写入点散落几十处，逐一挂钩
  /// 侵入性太大且容易漏；15s 写一个几 KB 的 JSON 开销可忽略，且能保证
  /// "崩溃前最多丢 15s 内的改动"。
  static void startAutoSnapshot({Duration interval = const Duration(seconds: 15)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(snapshot()));
    AppLog.instance.log('[PrefsMirror] 自动快照已启动（每 ${interval.inSeconds}s）');
  }

  static void stopAutoSnapshot() {
    _timer?.cancel();
    _timer = null;
    // 🔴 2026-10-29：这里原来只停周期定时器，**没停 400ms 去抖那个**
    // (`_soon`)。设置子页在 `dispose()` 里会调 `snapshotSoon()`，测试结束
    // 后这个 400ms Timer 还挂着 ⇒ flutter_test 报
    // 「A Timer is still pending」把用例判失败（settings_layout_regression_test）。
    // 生产环境不受影响（进程退出即回收），但测试必须干净。
    _soon?.cancel();
    _soon = null;
  }

  static Timer? _soon;

  /// **刚改完设置就调用**：把快照提前到 ~0.4s 后写一次。
  ///
  /// 为什么需要它（用户 2026-10-14 实测）：
  ///   周期快照是 15s 一次，窗口太宽 —— 用户改完菜单栏、马上从多任务里划掉 App
  ///   （或 App 被系统/信号杀死），那一版快照**还没跑**，
  ///   于是 prefs 和镜像里都还是旧值 ⇒ 重启后改动凭空消失。
  ///   这里做三件事：
  ///     ① **立刻**让 plist 落盘（`flushNow`）
  ///     ② **立刻**写一次镜像文件（不留窗口）
  ///     ③ 400ms 后再补写一次，合并设置页里连点开关 / 连续拖动产生的密集调用
  static void snapshotSoon(
      {Duration delay = const Duration(milliseconds: 400)}) {
    // ① **立刻落盘**（plist）—— 这一步才是"改了就是改了"的关键：
    //    键一旦进了 plist，之后不管进程被怎么杀都不会丢。
    unawaited(flushNow());
    // ② **立刻写一次镜像** —— 2026-10-14 堵的"400ms 窗口"：
    //    原来镜像只靠 400ms 去抖/15s 周期写，改完立刻上滑杀 App 就还是旧值。
    //    现在先把当前状态落一次，连这 400ms 都不留。
    unawaited(snapshot());
    // ③ 再去抖补一次：合并设置页里连点开关 / 连续拖动产生的密集调用。
    _soon?.cancel();
    _soon = Timer(delay, () => unawaited(snapshot()));
  }

  /// 立刻落盘 + 写镜像，**不留定时器**。
  ///
  /// 给 `dispose()` 这类"页面正在消失"的场景用：那边要的是"走之前把改动
  /// 存下来"，而不是"400ms 后再存一次"。留个定时器在树已销毁之后还会跑，
  /// 既没意义，也会让 flutter_test 报「A Timer is still pending」。
  static void snapshotNow() {
    unawaited(flushNow());
    unawaited(snapshot());
  }
}
