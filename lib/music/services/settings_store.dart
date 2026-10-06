import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import '../theme/discover_preset.dart';
import 'builtin_sources_service.dart';
import 'source_memory.dart';
import '../../services/app_log.dart';

/// 音乐模块的设置存储 —— 对应 Beans 的 `@AppStorage` / `PlatformPreferenceStore`。
///
/// 集中管理需要持久化的偏好，避免每个页面各读各的 `SharedPreferences`。
/// 用 `ValueNotifier` 暴露，UI 直接 `ValueListenableBuilder` 监听。
class SettingsStore {
  SettingsStore._();
  static final SettingsStore instance = SettingsStore._();

  static const _kQuality = AudioQuality.storageKey;
  static const _kSourceEnabled = 'music.sourceEnabled';
  static const String _kCrossPlatform = 'music.crossPlatformMatch';

  /// 发现页视觉预设（aurora / paper / midnight）。
  ///
  /// ⚠️ 这是**页面外观偏好**，不是主题 —— 它不改任何配色，
  /// 只决定发现页的背景与卡片材质（见 `discover_preset.dart`）。
  static const String _kDiscoverPreset = 'music.discoverPreset';
  static const _kMusicSource = 'music.platform';
  static const String _kBottomBarSubPages = 'music.bottomBarOnSubPages';

  /// **子页面是否显示音乐底部栏**（迷你条 + 导航栏）。
  ///
  /// ── 默认 **关**（用户 2026 要求做成开关）──────────────────────
  /// 用户先前要求「每个界面都要有迷你条 + 导航栏」，所以底栏被挂到
  /// 全局层（覆盖所有路由，含 push 出去的歌单详情/音源管理等）。
  ///
  /// 但那样会**盖住子页面最下方的内容** —— 除非每个子页都加底部留白。
  /// 而"我不想要这层遮挡"也是很合理的偏好（尤其子页面本来就不长时）。
  ///
  /// 所以做成开关，**默认关**：
  ///   · 关（默认）= 只有音乐主页有底栏，子页面干净、不被遮
  ///   · 开         = 子页面也有底栏（覆盖式浮在上面）
  ///
  /// ⚠️ 默认关还有个原因：**"盖住内容"是可见的坏体验**，
  ///    而"子页面没有底栏"只是少一个便利入口 —— 默认取不冒犯的那个。
  final bottomBarOnSubPages = ValueNotifier<bool>(false);


  /// 优先音质
  final audioQuality = ValueNotifier<AudioQuality>(AudioQuality.exhigh);

  /// 是否启用第三方音源（关掉就只用内置公开接口）
  final useThirdPartySources = ValueNotifier<bool>(true);

  /// 是否启用**跨平台匹配**（默认**关**）。
  ///
  /// 开启后：某平台的歌拿不到播放地址（VIP/无版权）时，
  /// 会去**其它平台**找同一首歌，用那边的地址播放。
  ///
  /// ── 🔴 为什么默认关（用户 2026 决定）──────────────────────────
  /// 实测结论：**跨平台匹配救不了 VIP 歌** ——
  /// QQ《晴天》在酷狗同名 9 条都能匹到，但**合格的 3 条全是
  /// `no_free_source`**；能播的 2 条是 134s/116s 的**片段**
  ///（时长差 135/153s 被防错配挡住）；网易云能播的 2 条是 112s
  /// 片段和**翻唱**（异歌手被挡）。
  ///
  /// 规律：**付费原版在其它平台也不免费** —— 这是版权现实，不是代码问题。
  /// 既然开了也基本匹不到，就不默认开启（少一次搜索、少几秒等待）。
  ///
  /// 实现仍保留（`CrossPlatformMatcher`），需要时可在设置里打开。
  final crossPlatformMatch = ValueNotifier<bool>(false);

  /// 发现页视觉预设（默认 aurora = 青碧玻璃，对齐 Beans 默认）
  DiscoverPreset discoverPreset = DiscoverPreset.aurora;

  /// 当前音乐**平台**（搜索/发现用哪个内置数据源）。
  ///
  /// ⚠️ 播放地址**不看它** —— 解析用的是**每首歌自己的 `Song.source`**
  ///（否则搜到酷狗的歌却拿酷狗 id 去查网易云，必然取不到地址）。
  final musicSource = ValueNotifier<SongSource>(SongSource.netease);

  /// 加载全部音乐偏好，并**连带初始化音源相关的东西**。
  ///
  /// ── 🔴 整体 try/catch（修"prefs 一次失败就拖垮音源列表"）──────────
  ///
  /// 调用方 `main.dart` 是**裸 `await SettingsStore.instance.init();`**
  ///（没有 try/catch），而本方法里 `ThirdPartySourceStore.init()` /
  /// `SourceMemory.init()` / `BuiltinSourcesService.init()` **三个 await
  /// 串在同一条链上**。
  ///
  /// 只要**前面任何一步抛异常**（最可能的是下面
  /// `SharedPreferences.getInstance()` 平台通道失败 ——
  /// 本文件上面已经记录过"裸 await → 启动即崩"这个教训），
  /// 后面就**全部不执行** → **音源列表为空** →
  /// **点歌全部失败且用户看不到原因**（连"没有音源"都不会提示）✗
  ///
  /// 现在：prefs 拿不到就**用默认值继续跑**，音源相关的三步**照常执行** ——
  /// 少一个偏好项的代价，远小于"整个音乐模块不能用"。
  Future<void> init() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      // 刻意不 rethrow：下面的音源初始化才是**关键路径**
      AppLog.instance.log('[Music] SettingsStore 读取偏好失败（改用默认值）: $e');
    }

    if (prefs != null) {
      // ⚠️ 只在「存过**且合法**」时才覆盖默认值。
      //
      // 原来是无条件 `audioQuality.value = AudioQuality.fromName(prefs.getString(...))`，
      // 而 `AudioQuality.fromName` 的 orElse 是 **hires** ——
      // 首次启动（没有存储值 → 传 null）就被悄悄改成 hires，
      // 与这里声明的默认 `exhigh`(320K) 不符，用户更容易撞上"这首歌没有免费音源"。
      final saved = prefs.getString(_kQuality);
      AudioQuality? parsed;
      if (saved != null) {
        for (final q in AudioQuality.values) {
          if (q.name == saved) {
            parsed = q;
            break;
          }
        }
      }
      if (parsed != null) audioQuality.value = parsed;
      useThirdPartySources.value = prefs.getBool(_kSourceEnabled) ?? true;
      // ── ⚠️ **强制关闭**，并清掉可能存在的历史 true ────────────────
      //
      // 用户决定不要跨平台匹配，且设置页的开关**已移除** ——
      // 如果这里还老老实实读 prefs，那么"以前开过"的用户会**永远开着**，
      // 而且**没有任何入口能关掉**（开关没了）→ 变成幽灵行为。
      //
      // 所以：无条件置 false，并把存储里的旧值删掉（避免以后恢复开关时
      // 又被旧值翻上来）。
      crossPlatformMatch.value = false;
      if (prefs.containsKey(_kCrossPlatform)) {
        await prefs.remove(_kCrossPlatform);
      }
      discoverPreset = DiscoverPreset.fromName(prefs.getString(_kDiscoverPreset));
      // 没存过 / 存的是未知值 → `fromKey` 会兜底成 netease（行为不变）
      musicSource.value = SongSource.fromKey(prefs.getString(_kMusicSource));
      // 子页面底栏开关：**没存过就是 false**（默认关，见字段注释的理由）
      bottomBarOnSubPages.value = prefs.getBool(_kBottomBarSubPages) ?? false;
    }

    // ── 以下三步是**关键路径**：各自独立 try/catch，互不拖累 ─────────
    //
    // 音源列表也在这里一起初始化，保证进音乐 tab 前就绪
    try {
      await ThirdPartySourceStore.instance.init();
    } catch (e) {
      AppLog.instance.log('[Music] 音源列表初始化失败: $e');
    }
    // 音源记忆（"这首歌上次用哪个源" —— 见 SourceMemory）
    try {
      await SourceMemory.instance.init();
    } catch (e) {
      AppLog.instance.log('[Music] 音源记忆初始化失败: $e');
    }
    // 内置源注册 + 自动更新（静默：失败不影响启动）
    // 先注册出厂内置源，再异步拉远端看有没有新版本
    try {
      await BuiltinSourcesService.instance.init();
    } catch (e) {
      AppLog.instance.log('[Music] 内置源注册失败: $e');
    }
    unawaited(BuiltinSourcesService.instance.checkForUpdates());
  }

  /// 写入一个偏好项，**失败就回滚内存值**。
  ///
  /// ── 🔴 为什么不能"只改内存 + 丢弃写盘 Future"（修假设置）─────────
  ///
  /// 原来的六个 setter 都是这个形状：
  /// ```dart
  /// Future<void> setXxx(T v) async {
  ///   xxx.value = v;                                        // 先改内存
  ///   (await SharedPreferences.getInstance()).setBool(k, v); // 丢弃 Future
  /// }
  /// ```
  /// 问题：`set*` 返回 `Future<bool>`，**没有被 await、也没看返回值** →
  /// 写盘失败时**静默丢弃**，而 UI 已经切到新值 →
  /// 用户看到"设置生效了"，**重启却变回旧值**（最难查的那类 bug）。
  ///
  /// 现在：等写盘结果，失败就**回滚 notifier 并写日志**，
  /// 让"界面显示的状态"和"磁盘上的状态"始终一致。
  Future<void> _write(String key, Object v, VoidCallback rollback) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ok = v is bool
          ? await prefs.setBool(key, v)
          : await prefs.setString(key, v.toString());
      if (!ok) {
        rollback();
        AppLog.instance.log('[Music] 偏好写入返回 false（已回滚）：$key');
      }
    } catch (e) {
      rollback();
      AppLog.instance.log('[Music] 偏好写入失败（已回滚）：$key → $e');
    }
  }

  Future<void> setAudioQuality(AudioQuality q) async {
    final old = audioQuality.value;
    audioQuality.value = q;
    await _write(_kQuality, q.name, () => audioQuality.value = old);
  }

  Future<void> setUseThirdPartySources(bool v) async {
    final old = useThirdPartySources.value;
    useThirdPartySources.value = v;
    await _write(_kSourceEnabled, v, () => useThirdPartySources.value = old);
  }

  Future<void> setDiscoverPreset(DiscoverPreset v) async {
    final old = discoverPreset;
    discoverPreset = v;
    await _write(_kDiscoverPreset, v.name, () => discoverPreset = old);
  }

  Future<void> setCrossPlatformMatch(bool v) async {
    final old = crossPlatformMatch.value;
    crossPlatformMatch.value = v;
    await _write(_kCrossPlatform, v, () => crossPlatformMatch.value = old);
  }

  Future<void> setBottomBarOnSubPages(bool v) async {
    final old = bottomBarOnSubPages.value;
    bottomBarOnSubPages.value = v;
    await _write(_kBottomBarSubPages, v, () => bottomBarOnSubPages.value = old);
  }

  /// 切换音乐平台（搜索/发现用哪个内置数据源）。
  /// 播放地址**不受它影响** —— 那是按每首歌自己的 `Song.source` 解析的。
  Future<void> setMusicSource(SongSource s) async {
    final old = musicSource.value;
    musicSource.value = s;
    await _write(_kMusicSource, s.key, () => musicSource.value = old);
  }
}
