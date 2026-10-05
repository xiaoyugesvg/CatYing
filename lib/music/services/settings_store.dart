import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import '../theme/discover_preset.dart';
import 'builtin_sources_service.dart';

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

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
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
    // 音源列表也在这里一起初始化，保证进音乐 tab 前就绪
    await ThirdPartySourceStore.instance.init();
    // 内置源注册 + 自动更新（静默：失败不影响启动）
    // 先注册出厂内置源，再异步拉远端看有没有新版本
    await BuiltinSourcesService.instance.init();
    unawaited(BuiltinSourcesService.instance.checkForUpdates());
  }

  Future<void> setAudioQuality(AudioQuality q) async {
    audioQuality.value = q;
    (await SharedPreferences.getInstance()).setString(_kQuality, q.name);
  }

  Future<void> setUseThirdPartySources(bool v) async {
    useThirdPartySources.value = v;
    (await SharedPreferences.getInstance()).setBool(_kSourceEnabled, v);
  }

  Future<void> setDiscoverPreset(DiscoverPreset v) async {
    discoverPreset = v;
    (await SharedPreferences.getInstance()).setString(_kDiscoverPreset, v.name);
  }

  Future<void> setCrossPlatformMatch(bool v) async {
    crossPlatformMatch.value = v;
    (await SharedPreferences.getInstance()).setBool(_kCrossPlatform, v);
  }

  /// 切换音乐平台（搜索/发现用哪个内置数据源）。
  /// 播放地址**不受它影响** —— 那是按每首歌自己的 `Song.source` 解析的。
  Future<void> setMusicSource(SongSource s) async {
    musicSource.value = s;
    (await SharedPreferences.getInstance()).setString(_kMusicSource, s.key);
  }
}
