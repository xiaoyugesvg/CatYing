import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';

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
  static const _kMusicSource = 'music.platform';

  /// 优先音质
  final audioQuality = ValueNotifier<AudioQuality>(AudioQuality.exhigh);

  /// 是否启用第三方音源（关掉就只用内置公开接口）
  final useThirdPartySources = ValueNotifier<bool>(true);

  /// 是否启用**跨平台匹配**（默认开）。
  ///
  /// 开启后：某平台的歌拿不到播放地址（VIP/无版权）时，
  /// 会去**其它平台**找同一首歌，用那边的地址播放。
  ///
  /// 例：QQ 的《晴天》要会员 → 自动用网易云/酷狗的《晴天》播。
  /// 匹配带**三重防错配**（歌名归一化相等 + 歌手交集 + 时长差 ≤10s），
  /// 找不到可信的同一首就**不播**（宁可没有，也不放错歌）。
  ///
  /// 默认 **true**：这是"VIP 歌听不了"的主要解法之一。
  final crossPlatformMatch = ValueNotifier<bool>(true);

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
    crossPlatformMatch.value = prefs.getBool(_kCrossPlatform) ?? true;
    // 没存过 / 存的是未知值 → `fromKey` 会兜底成 netease（行为不变）
    musicSource.value = SongSource.fromKey(prefs.getString(_kMusicSource));
    // 音源列表也在这里一起初始化，保证进音乐 tab 前就绪
    await ThirdPartySourceStore.instance.init();
  }

  Future<void> setAudioQuality(AudioQuality q) async {
    audioQuality.value = q;
    (await SharedPreferences.getInstance()).setString(_kQuality, q.name);
  }

  Future<void> setUseThirdPartySources(bool v) async {
    useThirdPartySources.value = v;
    (await SharedPreferences.getInstance()).setBool(_kSourceEnabled, v);
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
