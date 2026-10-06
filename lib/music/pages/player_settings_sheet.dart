import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';

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
                borderRadius: BorderRadius.circular(10),
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
            // ── 🔴 这里原来用 `setState` 刷新，是个**会崩**的写法 ──────────
            //
            // 原文：
            //   onChanged: (v) async {
            //     await MusicPlayerSkin.instance.setShowLyricFirst(v);
            //     setState(() {});          // ← await 之后 **没有 mounted 检查**
            //   },
            //
            // 为什么是硬崩（不只是 debug 断言）：`await` 的是 SharedPreferences
            // 的平台通道写盘，期间事件循环会处理其它平台消息，用户完全可能
            // 同时**下滑关闭这个弹层**。`State` 一旦 unmount，框架会把
            // `_element` 置 null，而 `setState()` 内部是
            // `_element!.markNeedsBuild()` → **release 下也抛**
            // `Null check operator used on a null value`。
            //
            // ── 修法：干脆不用 `setState` ──────────────────────────────
            // 这几个值**本来就是 `ValueNotifier`**（见 `MusicPlayerSkin` /
            // `SettingsStore`），所以让每行自己 `ValueListenableBuilder`
            // 监听就行 —— 一举两得：
            //   · 不再有"await 后 setState"的崩溃路径
            //   · 面板打开期间**别处**改了同一个值，这里也会跟着刷新
            //    （原来"调用时快照 + onChanged 里 setState"做不到这点）
            ValueListenableBuilder<bool>(
              valueListenable: MusicPlayerSkin.instance.showLyricFirst,
              builder: (context, v, _) => _switchRow(
                label: '进播放器先看歌词',
                value: v,
                onChanged: (nv) =>
                    MusicPlayerSkin.instance.setShowLyricFirst(nv),
              ),
            ),
            ValueListenableBuilder<MusicCoverStyle>(
              valueListenable: MusicPlayerSkin.instance.coverStyle,
              builder: (context, cur, _) => _enumRow<MusicCoverStyle>(
                label: '封面形态',
                values: MusicCoverStyle.values,
                current: cur,
                labelOf: (e) => e.label,
                onPick: (e) => MusicPlayerSkin.instance.setCoverStyle(e),
              ),
            ),
            ValueListenableBuilder<MusicDustMode>(
              valueListenable: MusicPlayerSkin.instance.dustMode,
              builder: (context, cur, _) => _enumRow<MusicDustMode>(
                label: '背景氛围',
                values: MusicDustMode.values,
                current: cur,
                labelOf: (e) => e.label,
                onPick: (e) => MusicPlayerSkin.instance.setDustMode(e),
              ),
            ),
            const Divider(height: 24),
            _title('音质'),
            ValueListenableBuilder<AudioQuality>(
              valueListenable: SettingsStore.instance.audioQuality,
              builder: (context, cur, _) => _enumRow<AudioQuality>(
                label: '优先音质',
                values: AudioQuality.values,
                current: cur,
                labelOf: (e) => e.displayName,
                onPick: (e) => SettingsStore.instance.setAudioQuality(e),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                '音质以「公开可用的最高档」为准；会员/独家曲目可能拿不到音源，'
                '播放器会明确提示而不是静默失败。',
                style: TextStyle(
                    color: MusicTheme.secondary, fontSize: AppTheme.fontCaption, height: 1.5),
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
                  fontSize: AppTheme.fontSubhead,
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
                style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontSubhead)),
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
                style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
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
          style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontBody)),
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
              style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontBody)),
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
                      fontSize: AppTheme.fontFootnote,
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
