import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/player_engine.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/settings/controller.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';
import 'package:tvbox/pages/settings/sub/parse_lines_page.dart';
import 'package:tvbox/services/parse_lines.dart';

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
      title: '播放器',
      children: [
        // ---------- 硬件加速（顶部独立卡片）----------
        Obx(() => AppCard(
              dense: true,
              child: unifiedSwitchRow(
                icon: Icons.memory,
                title: '硬件加速',
                value: PlayerPrefs.instance.hardwareAccel.value,
                onChanged: PlayerPrefs.instance.setHardwareAccel,
              ),
            )),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 画面与内核 ----------
        SettingsGroup(
          title: '画面与内核',
          children: [
            Obx(() => SettingsRow(
                  icon: Icons.video_settings,
                  title: '播放内核',
                  // 直接读 PlayerPrefs 的 Rx：播放器内切核心时设置页会**实时同步**
                  // （原来读的是 controller 里的副本，只在加载时拷贝一次 ⇒ 不同步）
                  value: PlayerPrefs.instance.vodEngine.value.title,
                  onTap: _pickEngine,
                )),
            // 直播内核：与点播**独立持久化**（PlayerPrefs.liveEngine），
            // 选项与直播页内嵌菜单一致（iOS：AV/KS/MPV，无 webview ——
            // 直播没有网页播放路径）。其它平台只有 mpv 可选，直接隐藏。
            if (Platform.isIOS)
              Obx(() => SettingsRow(
                    icon: Icons.live_tv,
                    title: '直播内核',
                    value: PlayerPrefs.instance.liveEngine.value.title,
                    onTap: _pickLiveEngine,
                  )),
            Obx(() => SettingsRow(
                  icon: Icons.aspect_ratio,
                  title: '画面填充',
                  value: _fillModeText(PlayerPrefs.instance.videoFillMode.value),
                  onTap: _pickFillMode,
                )),
            // 随内核显隐的专有项
            Obx(() => PlayerPrefs.instance.vodEngine.value == PlayerEngine.mpv
                ? SettingsRow(
                    icon: Icons.memory,
                    title: '视频解码（MPV）',
                    value: PlayerPrefs.instance.decodeMode.value.title,
                    onTap: _pickDecodeMode,
                  )
                : const SizedBox.shrink()),
            Obx(() => PlayerPrefs.instance.vodEngine.value == PlayerEngine.mpv
                ? SettingsRow(
                    icon: Icons.sd_card_outlined,
                    title: 'MPV 缓冲',
                    value: PlayerPrefs.instance.bufferMode.value.title,
                    onTap: _pickBufferMode,
                  )
                : const SizedBox.shrink()),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 播放 ----------
        SettingsGroup(
          title: '播放',
          children: [
            Obx(() => _stepperRow(
                  icon: Icons.speed,
                  title: '默认倍速',
                  value: PlayerPrefs.instance.defaultSpeed.value,
                  text:
                      '${PlayerPrefs.instance.defaultSpeed.value.toStringAsFixed(1)}',
                  min: 0.5,
                  max: 3.0,
                  step: 0.5,
                  onChanged: PlayerPrefs.instance.setDefaultSpeed,
                )),
            Obx(() => _stepperRow(
                  icon: Icons.fast_forward,
                  title: '快进快退秒数',
                  value: controller.playTimeStep.value.toDouble(),
                  text: '${controller.playTimeStep.value}',
                  min: 5,
                  max: 60,
                  step: 5,
                  onChanged: (v) =>
                      controller.setPlayTimeStep(v.round()),
                )),
            Obx(() => _stepperRow(
                  icon: Icons.touch_app,
                  title: '长按倍速',
                  value: PlayerPrefs.instance.longPressSpeed.value,
                  text:
                      '${PlayerPrefs.instance.longPressSpeed.value.toStringAsFixed(1)}',
                  min: 1.5,
                  max: 5.0,
                  step: 0.5,
                  onChanged: PlayerPrefs.instance.setLongPressSpeed,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.swipe,
                  title: '长按滑动调节倍速',
                  value: PlayerPrefs.instance.longPressAdjustable.value,
                  onChanged: PlayerPrefs.instance.setLongPressAdjustable,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.screen_rotation,
                  title: '优先横屏',
                  value: PlayerPrefs.instance.preferLandscape.value,
                  onChanged: PlayerPrefs.instance.setPreferLandscape,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.timer_outlined,
                  title: '进度条显示总时长',
                  value: PlayerPrefs.instance.showTotalDuration.value,
                  onChanged: PlayerPrefs.instance.setShowTotalDuration,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.hide_source,
                  title: '隐藏中央快进快退',
                  value: PlayerPrefs.instance.hideCenterSeek.value,
                  onChanged: PlayerPrefs.instance.setHideCenterSeek,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.pause_circle_outline,
                  title: '进入后台暂停',
                  value: PlayerPrefs.instance.pauseOnBackground.value,
                  onChanged: PlayerPrefs.instance.setPauseOnBackground,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.notifications_none,
                  title: '跳过提示',
                  value: PlayerPrefs.instance.skipHint.value,
                  onChanged: PlayerPrefs.instance.setSkipHint,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.switch_video,
                  title: '切集提示',
                  value: PlayerPrefs.instance.switchEpisodeHint.value,
                  onChanged: PlayerPrefs.instance.setSwitchEpisodeHint,
                )),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 信息显示 ----------
        SettingsGroup(
          title: '信息显示',
          children: [
            Obx(() => unifiedSwitchRow(
                  icon: Icons.bar_chart,
                  title: '显示帧率与编码',
                  value: PlayerPrefs.instance.showFpsCodec.value,
                  onChanged: PlayerPrefs.instance.setShowFpsCodec,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.speed,
                  title: '始终显示网速',
                  value: PlayerPrefs.instance.alwaysShowSpeed.value,
                  onChanged: PlayerPrefs.instance.setAlwaysShowSpeed,
                )),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 解析线路（网页播放地址 → 媒体直链）----------
        // 用户 2026-10-29：只要一个「线路切换」入口，其余不做。
        ListenableBuilder(
          listenable: ParseLineStore.instance,
          builder: (context, _) {
            final store = ParseLineStore.instance;
            return SettingsGroup(
              title: '解析线路',
              hint: '播放地址是网页（含解析接口链接）时，后台自动解析成 m3u8/mp4 '
                  '再交给播放器；不需要开关。',
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ParseLinesPage(),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.alt_route_rounded,
                          size: 20,
                          color: AppTheme.textSecondary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '线路切换',
                                style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: AppTheme.fontSubhead,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '当前：${store.selectedName}'
                                '${store.isEmpty ? '（暂无线路）' : ' · 共 ${store.lines.length} 条'}',
                                style: TextStyle(
                                  color: AppTheme.textTertiary,
                                  fontSize: AppTheme.fontCaption,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: AppTheme.textTertiary,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 其他（原有项，保留）----------
        SettingsGroup(
          title: '其他',
          children: [
            Obx(() => unifiedSwitchRow(
                  icon: Icons.skip_next_outlined,
                  title: '自动下一集',
                  value: PlayerPrefs.instance.avAutoNext.value,
                  onChanged: PlayerPrefs.instance.setAvAutoNext,
                )),
            // 影视模块已不提供 WebView 内核（2026-10-29）：影视只播媒体直链。
            // 但「网页播放页」仍被 RSS / 小程序 / 海阔使用，下面这两个开关
            // 控制的就是那些页面，所以常驻显示。
            Obx(() => unifiedSwitchRow(
                  icon: Icons.javascript,
                  title: '网页 JS',
                  subtitle: '网页播放（RSS / 海阔 / 小程序）生效',
                  value: PlayerPrefs.instance.webviewEnableJs.value,
                  onChanged: PlayerPrefs.instance.setWebviewEnableJs,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.screen_lock_landscape_outlined,
                  title: '强制横屏（网页）',
                  value: PlayerPrefs.instance.webviewForceLandscape.value,
                  onChanged: PlayerPrefs.instance.setWebviewForceLandscape,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.volume_off_outlined,
                  title: '静音后台保活',
                  value: PlayerPrefs.instance.silentKeepAlive.value,
                  onChanged: PlayerPrefs.instance.setSilentKeepAlive,
                )),
            SettingsRow(
              icon: Icons.skip_previous_outlined,
              title: '默认跳过片头',
              value: _skipIntro == 0 ? '关闭' : '$_skipIntro秒',
              onTap: () => _pickSkipSeconds(intro: true),
            ),
            SettingsRow(
              icon: Icons.skip_next_outlined,
              title: '默认跳过片尾',
              value: _skipOutro == 0 ? '关闭' : '$_skipOutro秒',
              onTap: () => _pickSkipSeconds(intro: false),
            ),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.high_quality_outlined,
                  title: '默认画质',
                  subtitle: '开启：最高清晰度；关闭：自动',
                  value: PlayerPrefs.instance.defaultQuality.value == 1,
                  onChanged: (v) async {
                    final cur = PlayerPrefs.instance.defaultQuality.value;
                    await PlayerPrefs.instance
                        .setDefaultQuality(v ? 1 : (cur == 1 ? 0 : cur));
                  },
                )),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 诊断 ----------
        SettingsGroup(
          title: '诊断',
          children: [
            SettingsRow(
              icon: Icons.bug_report_outlined,
              title: '调试日志',
              value: '查看最近记录',
              onTap: _showDebugLogDialog,
            ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // 组件
  // ============================================================

  String _fillModeText(int v) => switch (v) {
        1 => '裁剪铺满',
        2 => '拉伸铺满',
        _ => '原比例',
      };

  Future<void> _pickFillMode() async {
    final v = await SettingsDialogs.pick<int>(
      context: context,
      title: '画面填充',
      options: const [0, 1, 2],
      selected: PlayerPrefs.instance.videoFillMode.value,
      labelBuilder: _fillModeText,
    );
    if (v != null) await PlayerPrefs.instance.setVideoFillMode(v);
  }

  /// 数值步进行（− 值 ＋），对应参考图的默认倍速/快进秒数/长按倍速
  Widget _stepperRow({
    required IconData icon,
    required String title,
    required double value,
    required String text,
    required double min,
    required double max,
    required double step,
    required ValueChanged<double> onChanged,
  }) {
    final canMinus = value > min + 1e-6;
    final canPlus = value < max - 1e-6;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingXS, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accentColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 17, color: AppTheme.accentColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 0.5,
                    fontWeight: FontWeight.w500)),
          ),
          _stepButton(Icons.remove, canMinus, () {
            final v = (value - step);
            onChanged(v < min ? min : v);
          }),
          SizedBox(
            width: 54,
            child: Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 0.5,
                    fontWeight: FontWeight.w600)),
          ),
          _stepButton(Icons.add, canPlus, () {
            final v = (value + step);
            onChanged(v > max ? max : v);
          }),
        ],
      ),
    );
  }

  Widget _stepButton(IconData icon, bool enabled, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.accentColor
              .withValues(alpha: enabled ? 0.18 : 0.06),
          shape: BoxShape.circle,
        ),
        child: Icon(icon,
            size: 16,
            color: enabled
                ? AppTheme.accentColor
                : AppTheme.textTertiary.withValues(alpha: 0.5)),
      ),
    );
  }
  // ============================================================
  // 选择器
  // ============================================================

  Future<void> _pickEngine() async {
    // ⚠️ 以 PlayerPrefs 为准，不用 controller 里那份缓存：
    // 播放器内切内核时只写 PlayerPrefs，而本页控制器是设置 tab 启动时创建的，
    // 那份 Rx 可能还是旧值 → 选中态会勾在**另一个内核**上。
    final e = await SettingsDialogs.pick<PlayerEngine>(
      context: context,
      title: '点播播放器',
      options: PlayerEngine.availableEngines,
      selected: PlayerPrefs.instance.vodEngine.value,
      labelBuilder: (x) => x.title,
    );
    if (e != null) await controller.setVodPlayerEngine(e);
  }

  /// 直播内核选择：与直播页 `_liveEngines` 保持一致（无 webview）。
  /// 选中即写入 `PlayerPrefs.liveEngine`——直播页每次都实时读它，
  /// 下次开播/切台立即生效（无需重启）。
  Future<void> _pickLiveEngine() async {
    final e = await SettingsDialogs.pick<PlayerEngine>(
      context: context,
      title: '直播播放器',
      options: const [
        PlayerEngine.avplayer,
        PlayerEngine.ksplayer,
        PlayerEngine.mpv,
      ],
      selected: PlayerPrefs.instance.liveEngine.value,
      labelBuilder: (x) => x.title,
    );
    if (e != null) await PlayerPrefs.instance.setLiveEngine(e);
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
                fontSize: AppTheme.fontCaption,
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
