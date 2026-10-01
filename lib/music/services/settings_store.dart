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

  /// 优先音质
  final audioQuality = ValueNotifier<AudioQuality>(AudioQuality.exhigh);

  /// 是否启用第三方音源（关掉就只用内置公开接口）
  final useThirdPartySources = ValueNotifier<bool>(true);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    audioQuality.value =
        AudioQuality.fromName(prefs.getString(_kQuality));
    useThirdPartySources.value = prefs.getBool(_kSourceEnabled) ?? true;
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
}
