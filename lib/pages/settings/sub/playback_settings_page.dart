import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/theme.dart';
import '../../../models/player_engine.dart';
import '../../../services/app_log.dart';
import '../../../services/player_prefs.dart';
import '../../../widgets/common_widgets.dart';
import '../controller.dart';
import 'settings_shared.dart';

/// 设置 → 播放设置
///
/// 从原 settings/view.dart 拆出。行为保持一致：
/// 播放内核 + 随内核显隐的专有项 + 通用播放项 + 调试日志。
///
/// 交互统一：原来有两套选择器（`_showEnumSelector` 用 AlertDialog、
/// 清理周期用 bottom sheet）。这里统一走 [SettingsDialogs.pick] 的底部弹窗，
/// 视觉与操作一致。
class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({super.key});

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  SettingsController get controller => Get.find<SettingsController>();

  int _skipIntro = 0;
  int _skipOutro = 0;

  @override
  void initState() {
    super.initState();
    _loadSkipDefaults();
  }

  Future<void> _loadSkipDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _skipIntro = prefs.getInt('skip_intro_seconds') ?? 0;
      _skipOutro = prefs.getInt('skip_outro_seconds') ?? 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '播放设置',
      children: [
        // ---------- 播放内核 ----------
        SettingsGroup(
          title: '播放内核',
          children: [
            Obx(() => SettingsRow(
                  icon: Icons.play_circle_outline,
                  title: '点播播放器',
                  value: controller.vodPlayerEngine.value.title,
                  onTap: () => _pickEngine(),
                )),
            // 随内核显隐的专有设置
            Obx(() {
              final engine = controller.vodPlayerEngine.value;
              if (engine == PlayerEngine.mpv) {
                return Column(
                  children: [
                    Divider(color: AppTheme.borderLight, height: 1),
                    SettingsRow(
                      icon: Icons.memory,
                      title: '视频解码（MPV）',
                      value: controller.decodeMode.value.title,
                      onTap: () => _pickDecodeMode(),
                    ),
                    Divider(color: AppTheme.borderLight, height: 1),
                    SettingsRow(
                      icon: Icons.storage_outlined,
                      title: 'MPV缓冲',
                      value: controller.vlcBufferMode.value.title,
                      onTap: () => _pickBufferMode(),
                    ),
                  ],
                );
              }
              if (engine == PlayerEngine.webview) {
                return Column(
                  children: [
                    Divider(color: AppTheme.borderLight, height: 1),
                    Obx(() => SettingsRow(
                          icon: Icons.javascript,
                          title: '网页 JS',
                          value: PlayerPrefs.instance.webviewEnableJs.value
                              ? '已开启'
                              : '已关闭',
                          trailingSwitch: true,
                          switchValue:
                              PlayerPrefs.instance.webviewEnableJs.value,
                          onSwitchChanged: (v) =>
                              PlayerPrefs.instance.setWebviewEnableJs(v),
                        )),
                    Divider(color: AppTheme.borderLight, height: 1),
                    Obx(() => SettingsRow(
                          icon: Icons.screen_rotation,
                          title: '强制横屏',
                          value: PlayerPrefs
                                  .instance.webviewForceLandscape.value
                              ? '已开启'
                              : '已关闭',
                          trailingSwitch: true,
                          switchValue: PlayerPrefs
                              .instance.webviewForceLandscape.value,
                          onSwitchChanged: (v) => PlayerPrefs.instance
                              .setWebviewForceLandscape(v),
                        )),
                  ],
                );
              }
              return Column(
                children: [
                  Divider(color: AppTheme.borderLight, height: 1),
                  Obx(() => SettingsRow(
                        icon: Icons.skip_next,
                        title: '自动下一集',
                        value: PlayerPrefs.instance.avAutoNext.value
                            ? '已开启'
                            : '已关闭',
                        trailingSwitch: true,
                        switchValue: PlayerPrefs.instance.avAutoNext.value,
                        onSwitchChanged: (v) =>
                            PlayerPrefs.instance.setAvAutoNext(v),
                      )),
                ],
              );
            }),
          ],
        ),

        // ---------- 通用播放项 ----------
        SettingsGroup(
          title: '播放行为',
          children: [
            Obx(() => SettingsRow(
                  icon: Icons.fast_forward,
                  title: '快进步长',
                  value: '${controller.playTimeStep.value}秒',
                  onTap: () => _pickTimeStep(),
                )),
            Obx(() => SettingsRow(
                  icon: Icons.battery_saver,
                  title: '静音后台保活',
                  value: PlayerPrefs.instance.silentKeepAlive.value
                      ? '已开启'
                      : '已关闭',
                  trailingSwitch: true,
                  switchValue: PlayerPrefs.instance.silentKeepAlive.value,
                  onSwitchChanged: (v) =>
                      PlayerPrefs.instance.setSilentKeepAlive(v),
                )),
            SettingsRow(
              icon: Icons.hourglass_top,
              title: '默认跳过片头',
              value: _skipIntro > 0 ? '$_skipIntro秒' : '关闭',
              onTap: () => _pickSkipSeconds(intro: true),
            ),
            SettingsRow(
              icon: Icons.hourglass_bottom,
              title: '默认跳过片尾',
              value: _skipOutro > 0 ? '$_skipOutro秒' : '关闭',
              onTap: () => _pickSkipSeconds(intro: false),
            ),
            Obx(() => SettingsRow(
                  icon: Icons.high_quality_outlined,
                  title: '默认画质',
                  value:
                      PlayerPrefs.instance.defaultQuality.value == 1
                          ? '最高'
                          : '自动',
                  onTap: () async {
                    final q = await SettingsDialogs.pick<int>(
                      context: context,
                      title: '默认画质',
                      options: const [0, 1],
                      selected: PlayerPrefs.instance.defaultQuality.value,
                      labelBuilder: (v) => v == 1 ? '最高清晰度' : '自动',
                    );
                    if (q != null) {
                      await PlayerPrefs.instance.setDefaultQuality(q);
                    }
                  },
                )),
          ],
        ),

        // ---------- 诊断 ----------
        SettingsGroup(
          title: '诊断',
          children: [
            SettingsRow(
              icon: Icons.bug_report_outlined,
              title: '调试日志',
              value: '查看 / 清空',
              onTap: _showDebugLogDialog,
            ),
          ],
          hint: '播放异常时可先看日志；日志位于应用文档目录，包含源加载、刮削、弹幕等关键流程。',
        ),
      ],
    );
  }

  // ============================================================
  // 选择器
  // ============================================================

  Future<void> _pickEngine() async {
    final e = await SettingsDialogs.pick<PlayerEngine>(
      context: context,
      title: '点播播放器',
      options: PlayerEngine.availableEngines,
      selected: controller.vodPlayerEngine.value,
      labelBuilder: (x) => x.title,
    );
    if (e != null) await controller.setVodPlayerEngine(e);
  }

  Future<void> _pickDecodeMode() async {
    final m = await SettingsDialogs.pick<VideoDecodeMode>(
      context: context,
      title: '视频解码',
      options: VideoDecodeMode.values,
      selected: controller.decodeMode.value,
      labelBuilder: (x) => x.title,
    );
    if (m != null) await controller.setDecodeMode(m);
  }

  Future<void> _pickBufferMode() async {
    final m = await SettingsDialogs.pick<VLCBufferMode>(
      context: context,
      title: 'MPV缓冲',
      options: VLCBufferMode.values,
      selected: controller.vlcBufferMode.value,
      labelBuilder: (x) => x.title,
    );
    if (m != null) await controller.setVLCBufferMode(m);
  }

  Future<void> _pickTimeStep() async {
    final step = await SettingsDialogs.pick<int>(
      context: context,
      title: '快进步长',
      options: controller.playTimeStepOptions,
      selected: controller.playTimeStep.value,
      labelBuilder: (s) => '$s秒',
    );
    if (step != null) await controller.setPlayTimeStep(step);
  }

  /// 选择默认跳过片头/片尾秒数（与详情页播放器内设置共用同一 key）
  Future<void> _pickSkipSeconds({required bool intro}) async {
    const options = [0, 5, 10, 15, 20, 30, 60, 90, 120];
    final s = await SettingsDialogs.pick<int>(
      context: context,
      title: intro ? '默认跳过片头' : '默认跳过片尾',
      options: options,
      selected: intro ? _skipIntro : _skipOutro,
      labelBuilder: (v) => v == 0 ? '关闭' : '$v秒',
    );
    if (s == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(intro ? 'skip_intro_seconds' : 'skip_outro_seconds', s);
    if (mounted) {
      setState(() {
        if (intro) {
          _skipIntro = s;
        } else {
          _skipOutro = s;
        }
      });
    }
  }

  // ============================================================
  // 调试日志
  // ============================================================

  Future<void> _showDebugLogDialog() async {
    final text = await AppLog.instance.readRecentLines(lines: 120);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('调试日志（最近）',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? '（暂无日志，先操作几步再打开）' : text,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                await AppLog.instance.clear();
              } catch (_) {}
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child:
                Text('清空', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('关闭',
                style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }
}
