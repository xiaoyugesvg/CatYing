import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';

/// 播放设置面板（Beans 的播放设置/个性化外观的合并入口）。
///
/// 原版把这些散在 `PlayerView` 的多个 sheet 里；这里收成一个面板，
/// 减少跳转层级。改动即时生效并持久化。
class PlayerSettingsSheet extends StatefulWidget {
  const PlayerSettingsSheet({super.key});

  @override
  State<PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}

class _PlayerSettingsSheetState extends State<PlayerSettingsSheet> {
  final player = MusicPlayerManager.instance;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: MusicTheme.secondary.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            _title('播放'),
            _slider(
              label: '音量',
              value: player.volume.value,
              min: 0,
              max: 100,
              display: '${player.volume.value.round()}',
              onChanged: (v) => setState(() => player.setVolume(v)),
            ),
            _slider(
              label: '歌词偏移',
              value: player.lyricOffset.value.toDouble(),
              min: -3000,
              max: 3000,
              display: '${player.lyricOffset.value >= 0 ? "+" : ""}${player.lyricOffset.value} ms',
              onChanged: (v) => setState(() => player.setLyricOffset(v.round())),
            ),
            const Divider(height: 24),
            _title('外观'),
            _switchRow(
              label: '进播放器先看歌词',
              value: MusicPlayerSkin.instance.showLyricFirst.value,
              onChanged: (v) async {
                await MusicPlayerSkin.instance.setShowLyricFirst(v);
                setState(() {});
              },
            ),
            _enumRow<MusicCoverStyle>(
              label: '封面形态',
              values: MusicCoverStyle.values,
              current: MusicPlayerSkin.instance.coverStyle.value,
              labelOf: (e) => e.label,
              onPick: (e) async {
                await MusicPlayerSkin.instance.setCoverStyle(e);
                setState(() {});
              },
            ),
            _enumRow<MusicDustMode>(
              label: '背景氛围',
              values: MusicDustMode.values,
              current: MusicPlayerSkin.instance.dustMode.value,
              labelOf: (e) => e.label,
              onPick: (e) async {
                await MusicPlayerSkin.instance.setDustMode(e);
                setState(() {});
              },
            ),
            const Divider(height: 24),
            _title('音质'),
            _enumRow<AudioQuality>(
              label: '优先音质',
              values: AudioQuality.values,
              current: SettingsStore.instance.audioQuality.value,
              labelOf: (e) => e.displayName,
              onPick: (e) async {
                await SettingsStore.instance.setAudioQuality(e);
                setState(() {});
              },
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                '音质以「公开可用的最高档」为准；会员/独家曲目可能拿不到音源，'
                '播放器会明确提示而不是静默失败。',
                style: TextStyle(
                    color: MusicTheme.secondary, fontSize: 11, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(t,
              style: TextStyle(
                  color: MusicTheme.tint,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ),
      );

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label,
                style: TextStyle(color: MusicTheme.label, fontSize: 13)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: MusicTheme.tint,
                inactiveTrackColor:
                    MusicTheme.secondary.withValues(alpha: 0.25),
                thumbColor: MusicTheme.tint,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 66,
            child: Text(display,
                textAlign: TextAlign.right,
                style: TextStyle(color: MusicTheme.secondary, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _switchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(label,
          style: TextStyle(color: MusicTheme.label, fontSize: 14)),
      activeThumbColor: MusicTheme.tint,
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _enumRow<T>({
    required String label,
    required List<T> values,
    required T current,
    required String Function(T) labelOf,
    required ValueChanged<T> onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(color: MusicTheme.label, fontSize: 14)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: values.map((e) {
              final active = e == current;
              return GestureDetector(
                onTap: () => onPick(e),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: active
                        ? MusicTheme.tint.withValues(alpha: 0.16)
                        : MusicTheme.label.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: active
                          ? MusicTheme.tint.withValues(alpha: 0.6)
                          : Colors.transparent,
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    labelOf(e),
                    style: TextStyle(
                      color: active ? MusicTheme.tint : MusicTheme.secondary,
                      fontSize: 12,
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
