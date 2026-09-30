import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../common/theme.dart';
import '../../services/api_config.dart';
import '../../services/tmdb_service.dart';
import '../../services/background_service.dart';
import '../../models/player_engine.dart';
import '../../widgets/common_widgets.dart';
import '../../common/theme_mode_store.dart';
import '../../services/player_prefs.dart';
import '../../services/app_log.dart';
import 'controller.dart';

/// 设置页 - 对应 Swift SettingsView
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final controller = Get.put(SettingsController());

  /// 弹幕 API 地址（Logvr-danmu / 弹弹play 兼容），播放器按视频 URL 匹配弹幕
  String _danmuApiUrl = '';
  double _danmuFontSize = 14;
  double _danmuOpacity = 1;
  int _danmuTracks = 4;
  double _danmuSpeed = 150;
  List<String> _danmuBlockWords = [];
  bool _sourceCacheEnabled = true;
  int _autoCleanIndex = 0;
  int _skipIntro = 0;
  int _skipOutro = 0;

  @override
  void initState() {
    super.initState();
    _loadDanmuPrefs();
    _loadCachePrefs();
    _loadPlaybackDefaults();
    controller.runAutoCacheCleanIfNeeded();
  }

  Future<void> _loadPlaybackDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _skipIntro = prefs.getInt('skip_intro_seconds') ?? 0;
      _skipOutro = prefs.getInt('skip_outro_seconds') ?? 0;
    });
  }

  Future<void> _loadCachePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sourceCacheEnabled = prefs.getBool('source_cache_enabled') ?? true;
      _autoCleanIndex = prefs.getInt('source_cache_auto_clean') ?? 0;
    });
  }

  Future<void> _loadDanmuPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = (prefs.getString('danmu_api_url') ?? '').trim();
      if (!mounted) return;
      setState(() {
        _danmuApiUrl = url;
        _danmuFontSize = (prefs.getDouble('danmu_font_size') ?? 14).clamp(10.0, 28.0);
        _danmuOpacity = (prefs.getDouble('danmu_opacity') ?? 1).clamp(0.2, 1.0);
        _danmuTracks = (prefs.getInt('danmu_tracks') ?? 4).clamp(2, 8);
        _danmuSpeed = (prefs.getDouble('danmu_speed') ?? 150).clamp(80.0, 240.0);
        _danmuBlockWords =
            prefs.getStringList('danmu_block_words') ?? const [];
      });
    } catch (e) { /* ignore */ }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 透明背景,让 ContentView 全局背景层透出
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingLG,
              AppTheme.spacingLG,
              AppTheme.spacingLG,
              AppTheme.spacingLG + 96,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '设置',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXXL),

                // 外观 - 主题 + 自定义背景
                const SectionHeader(title: '外观'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildThemeModeSection(),
                const SizedBox(height: AppTheme.spacingSM),
                _buildAppearanceSection(),
                const SizedBox(height: AppTheme.spacingSM),
                _buildFontScaleSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 数据源
                const SectionHeader(title: '数据源'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildDataSourceSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 直播
                const SectionHeader(title: '直播'),
                const SizedBox(height: AppTheme.spacingSM),
                AppCard(
                  child: SettingsRow(
                    icon: Icons.live_tv_outlined,
                    title: '直播源管理',
                    value: '全局 EPG、屏蔽分类',
                    onTap: () => Get.toNamed('/live/settings'),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXXL),

                // 播放设置
                const SectionHeader(title: '播放设置'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildPlayerSettingsSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 弹幕
                const SectionHeader(title: '弹幕'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildDanmuSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // TMDB 智能刮削
                const SectionHeader(title: '元数据'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildTmdbSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 缓存
                const SectionHeader(title: '缓存'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildCacheSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 关于
                const SectionHeader(title: '关于'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildAboutSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 外观 - 主题模式
  // ============================================================

  Widget _buildThemeModeSection() {
    final mode = ThemeModeStore.mode;
    String label = switch (mode) {
      ThemeMode.light => '浅色',
      ThemeMode.system => '跟随系统',
      _ => '深色',
    };
    return AppCard(
      child: SettingsRow(
        icon: Icons.brightness_6_outlined,
        title: '外观模式',
        value: label,
        onTap: () async {
          final selected = await showModalBottomSheet<String>(
            context: context,
            backgroundColor: const Color(0xFF1C1C1E),
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('外观模式',
                        style: TextStyle(color: Colors.white, fontSize: 15)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.dark_mode_outlined,
                        color: Colors.white70),
                    title: const Text('深色',
                        style: TextStyle(color: Colors.white70)),
                    trailing: mode == ThemeMode.dark
                        ? const Icon(Icons.check, color: AppTheme.accentColor)
                        : null,
                    onTap: () => Navigator.pop(ctx, 'dark'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.light_mode_outlined,
                        color: Colors.white70),
                    title: const Text('浅色',
                        style: TextStyle(color: Colors.white70)),
                    trailing: mode == ThemeMode.light
                        ? const Icon(Icons.check, color: AppTheme.accentColor)
                        : null,
                    onTap: () => Navigator.pop(ctx, 'light'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings_suggest_outlined,
                        color: Colors.white70),
                    title: const Text('跟随系统',
                        style: TextStyle(color: Colors.white70)),
                    trailing: mode == ThemeMode.system
                        ? const Icon(Icons.check, color: AppTheme.accentColor)
                        : null,
                    onTap: () => Navigator.pop(ctx, 'system'),
                  ),
                ],
              ),
            ),
          );
          if (selected == null) return;
          final m = switch (selected) {
            'light' => ThemeMode.light,
            'system' => ThemeMode.system,
            _ => ThemeMode.dark,
          };
          await ThemeModeStore.set(m);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  // ============================================================
  // 外观 - 自定义背景
  // ============================================================

  Widget _buildAppearanceSection() {
    final bg = BackgroundService.instance;
    return AppCard(
      child: Obx(() => SettingsRow(
            icon: Icons.wallpaper_outlined,
            title: '应用背景',
            value: bg.choice.value == BackgroundChoice.custom
                ? '自定义图片'
                : bg.currentDisplayName,
            onTap: () => _showBackgroundPicker(bg),
          )),
    );
  }

  /// 界面字号（全局 textScaler，弹幕字号单独设置不受影响）
  Widget _buildFontScaleSection() {
    return Obx(() => AppCard(
          child: SettingsRow(
            icon: Icons.text_fields,
            title: '界面字号',
            value: '${(PlayerPrefs.instance.fontScale.value * 100).round()}%',
            onTap: () => _showFontScaleDialog(),
          ),
        ));
  }

  void _showFontScaleDialog() {
    var v = PlayerPrefs.instance.fontScale.value;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: AppTheme.backgroundSecondary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusLG),
            ),
            title: Text('界面字号',
                style: TextStyle(color: AppTheme.textPrimary)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${(v * 100).round()}%',
                    style: TextStyle(color: AppTheme.textSecondary)),
                Slider(
                  value: v,
                  min: 0.85,
                  max: 1.30,
                  divisions: 9,
                  label: '${(v * 100).round()}%',
                  onChanged: (nv) => setDialogState(() => v = nv),
                ),
                const SizedBox(height: AppTheme.spacingSM),
                Text(
                  '作用于全部界面文字（弹幕字号单独设置不受影响）',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('取消',
                    style: TextStyle(color: AppTheme.textSecondary)),
              ),
              TextButton(
                onPressed: () async {
                  await PlayerPrefs.instance.setFontScale(v);
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
                child: Text('保存',
                    style: TextStyle(color: AppTheme.accentColor)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 背景选择弹窗 - 4 个内置渐变 + 相册选择 + 清除自定义
  void _showBackgroundPicker(BackgroundService bg) {
    final previews = BackgroundService.builtinPreviews;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('选择应用背景',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: 360,
          child: Obx(() => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 4 个内置渐变预览
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.85,
                    ),
                    itemCount: previews.length,
                    itemBuilder: (_, i) {
                      final p = previews[i];
                      final isSelected = bg.choice.value == p.choice;
                      return _BackgroundPreviewTile(
                        name: p.name,
                        colors: p.colors,
                        isSelected: isSelected,
                        onTap: () async {
                          await bg.setBuiltin(p.choice);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  // 从相册选择
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                      onTap: () async {
                        // 关闭当前弹窗,异步选择图片
                        Navigator.pop(ctx);
                        await bg.pickFromGallery();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMD),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.photo_library_outlined,
                                color: AppTheme.accentColor, size: 18),
                            const SizedBox(width: 10),
                            Text(
                              '从相册选择图片',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontSubhead,
                              ),
                            ),
                            const Spacer(),
                            if (bg.choice.value == BackgroundChoice.custom)
                              const Icon(Icons.check_circle,
                                  color: AppTheme.accentColor, size: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 清除自定义
                  if (bg.choice.value == BackgroundChoice.custom) ...[
                    const SizedBox(height: 8),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMD),
                        onTap: () async {
                          await bg.clearCustom();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.1),
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMD),
                            border: Border.all(
                              color: Colors.red.withValues(alpha: 0.3),
                              width: 0.5,
                            ),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.delete_outline,
                                  color: Colors.redAccent, size: 18),
                              SizedBox(width: 10),
                              Text(
                                '清除自定义图片,恢复默认',
                                style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: AppTheme.fontSubhead,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              )),
        ),
      ),
    );
  }

  // ============================================================
  // 数据源
  // ============================================================

  Widget _buildDataSourceSection() {
    return AppCard(
      child: Column(
        children: [
          // 点播接口地址
          Obx(() => SettingsRow(
                icon: Icons.movie_outlined,
                title: '点播接口地址',
                value: controller.vodApiUrl.value.isEmpty
                    ? '未配置'
                    : _truncateUrl(controller.vodApiUrl.value),
                onTap: () => _showApiEditDialog(),
              )),
          Divider(color: AppTheme.borderLight, height: 1),
          // 主页数据源
          Obx(() => SettingsRow(
                icon: Icons.dns_outlined,
                title: '主页数据源',
                value: ApiConfig.instance.homeSourceBean.value?.name ?? '未选择',
                onTap: () => _showSourcePicker(),
              )),
          Divider(color: AppTheme.borderLight, height: 1),
          // 重置配置 - 回到 setupView 重新输入源 URL
          SettingsRow(
            icon: Icons.restart_alt,
            iconColor: Colors.redAccent,
            title: '重置配置',
            titleColor: Colors.redAccent,
            value: '回到初始设置',
            onTap: _showResetConfigDialog,
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 播放设置
  // ============================================================

  Widget _buildPlayerSettingsSection() {
    return AppCard(
      child: Column(
        children: [
          Obx(() => SettingsRow(
                icon: Icons.play_circle_outline,
                title: '点播播放器',
                value: controller.vodPlayerEngine.value.title,
                onTap: () => _showEnumSelector<PlayerEngine>(
                  title: '点播播放器',
                  options: PlayerEngine.availableEngines,
                  selected: controller.vodPlayerEngine.value,
                  labelBuilder: (e) => e.title,
                  onSelect: (e) => controller.setVodPlayerEngine(e),
                ),
              )),
          // 按内核显示专有设置（真实可点、写入 PlayerPrefs 并被播放器读取）
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
                    onTap: () => _showEnumSelector<VideoDecodeMode>(
                      title: '视频解码',
                      options: VideoDecodeMode.values,
                      selected: controller.decodeMode.value,
                      labelBuilder: (e) => e.title,
                      onSelect: (e) => controller.setDecodeMode(e),
                    ),
                  ),
                  Divider(color: AppTheme.borderLight, height: 1),
                  SettingsRow(
                    icon: Icons.storage_outlined,
                    title: 'MPV缓冲',
                    value: controller.vlcBufferMode.value.title,
                    onTap: () => _showEnumSelector<VLCBufferMode>(
                      title: 'MPV缓冲',
                      options: VLCBufferMode.values,
                      selected: controller.vlcBufferMode.value,
                      labelBuilder: (e) => e.title,
                      onSelect: (e) => controller.setVLCBufferMode(e),
                    ),
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
                        switchValue: PlayerPrefs.instance.webviewEnableJs.value,
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
                        switchValue:
                            PlayerPrefs.instance.webviewForceLandscape.value,
                        onSwitchChanged: (v) =>
                            PlayerPrefs.instance.setWebviewForceLandscape(v),
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
          Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
                icon: Icons.fast_forward,
                title: '快进步长',
                value: '${controller.playTimeStep.value}秒',
                onTap: () => _showTimeStepSelector(),
              )),
          Divider(color: AppTheme.borderLight, height: 1),
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
          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.hourglass_top,
            title: '默认跳过片头',
            value: _skipIntro > 0 ? '$_skipIntro秒' : '关闭',
            onTap: () => _pickSkipSeconds(intro: true),
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.hourglass_bottom,
            title: '默认跳过片尾',
            value: _skipOutro > 0 ? '$_skipOutro秒' : '关闭',
            onTap: () => _pickSkipSeconds(intro: false),
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
                icon: Icons.high_quality_outlined,
                title: '默认画质',
                value: PlayerPrefs.instance.defaultQuality.value == 1
                    ? '最高'
                    : '自动',
                onTap: () => _showEnumSelector<int>(
                  title: '默认画质',
                  options: const [0, 1],
                  selected: PlayerPrefs.instance.defaultQuality.value,
                  labelBuilder: (q) => q == 1 ? '最高清晰度' : '自动',
                  onSelect: (q) =>
                      PlayerPrefs.instance.setDefaultQuality(q),
                ),
              )),
          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.bug_report_outlined,
            title: '调试日志',
            value: '查看 / 清空',
            onTap: _showDebugLogDialog,
          ),
        ],
      ),
    );
  }

  /// 调试日志：最近若干行 + 一键清空
  Future<void> _showDebugLogDialog() async {
    final text = await AppLog.instance.readRecentLines(lines: 120);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
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
              child: Text('清空', style: TextStyle(color: AppTheme.textTertiary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('关闭',
                  style: TextStyle(color: AppTheme.accentColor)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDanmuSection() {
    return AppCard(
      child: Column(
        children: [
          SettingsRow(
            icon: Icons.subtitles,
            title: '弹幕 API',
            value: _danmuApiUrl.isEmpty ? '未配置' : _danmuApiUrl,
            onTap: _showDanmuApiEditDialog,
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.format_size,
            title: '弹幕样式',
            value: '$_danmuFontSize号 · ${(_danmuOpacity * 100).round()}%',
            onTap: _showDanmuStyleDialog,
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.block,
            title: '屏蔽关键词',
            value: _danmuBlockWords.isEmpty ? '无' : _danmuBlockWords.join('、'),
            onTap: _showDanmuBlockWordsDialog,
          ),
        ],
      ),
    );
  }

  Future<void> _showDanmuBlockWordsDialog() async {
    final ctrl = TextEditingController(text: _danmuBlockWords.join('\n'));
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('屏蔽关键词', style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctrl,
            maxLines: 6,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: '每行一个关键词，命中的弹幕不显示',
              hintStyle: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
              filled: true,
              fillColor: AppTheme.backgroundTertiary,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSM),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              final words = ctrl.text
                  .split(RegExp(r'[\n,，、]'))
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList();
              final prefs = await SharedPreferences.getInstance();
              await prefs.setStringList('danmu_block_words', words);
              if (mounted) {
                setState(() => _danmuBlockWords = words);
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: Text('保存', style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }

  Widget _buildTmdbSection() {
    final tmdb = TmdbService.instance;
    return AppCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsRow(
            icon: Icons.movie_filter_outlined,
            title: 'TMDB API Key',
            value: tmdb.configured
                ? '${tmdb.apiKey.value.substring(0, tmdb.apiKey.value.length.clamp(0, 6))}***'
                : '未配置',
            onTap: _showTmdbKeyDialog,
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
            icon: Icons.auto_awesome,
            title: '自动刮削元数据',
            value: tmdb.autoScrape.value ? '已开启' : '已关闭',
            onTap: () async {
              await tmdb.setAutoScrape(!tmdb.autoScrape.value);
            },
          )),
          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.info_outline,
            title: '说明',
            value: '在 themoviedb.org 申请 Key',
          ),
        ],
      ),
    );
  }

  void _showTmdbKeyDialog() {
    final tmdb = TmdbService.instance;
    final ctrl = TextEditingController(text: tmdb.apiKey.value);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('TMDB API Key',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: const InputDecoration(
            hintText: '粘贴 API Key (v3)',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await tmdb.saveApiKey(ctrl.text);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) setState(() {});
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 缓存
  // ============================================================

  Widget _buildCacheSection() {
    return AppCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 源文件缓存开关（普通 bool + setState，不能包 Obx）
          SettingsRow(
            icon: Icons.offline_bolt_outlined,
            title: '源文件缓存',
            value: _sourceCacheEnabled ? '已开启' : '已关闭',
            onTap: () async {
              setState(() => _sourceCacheEnabled = !_sourceCacheEnabled);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool(
                  'source_cache_enabled', _sourceCacheEnabled);
            },
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          // 自动清理
          SettingsRow(
            icon: Icons.auto_delete_outlined,
            title: '自动清理缓存',
            value: const ['关闭', '每天', '每周', '每月'][_autoCleanIndex],
            onTap: _pickAutoClean,
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          // 清理源文件
          SettingsRow(
            icon: Icons.cleaning_services_outlined,
            title: '清理源文件缓存',
            value: '源 JS',
            onTap: () => controller.clearSourceCache(),
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
                icon: Icons.delete_outline,
                title: '清除应用缓存',
                value: controller.cacheSizeString.value,
                onTap: () => _confirmClearCache(),
              )),
        ],
      ),
    );
  }

  Future<void> _pickAutoClean() async {
    const options = ['关闭', '每天', '每周', '每月'];
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('自动清理缓存',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
            ),
            for (var i = 0; i < options.length; i++)
              ListTile(
                title: Text(options[i],
                    style: const TextStyle(color: Colors.white70)),
                trailing: _autoCleanIndex == i
                    ? const Icon(Icons.check, color: AppTheme.accentColor)
                    : null,
                onTap: () => Navigator.pop(ctx, i),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      setState(() => _autoCleanIndex = selected);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('source_cache_auto_clean', selected);
    }
  }

  /// 选择默认跳过片头/片尾秒数（与详情页播放器内设置共用同一 key）
  Future<void> _pickSkipSeconds({required bool intro}) async {
    const options = [0, 5, 10, 15, 20, 30, 60, 90, 120];
    final key = intro ? 'skip_intro_seconds' : 'skip_outro_seconds';
    final title = intro ? '默认跳过片头' : '默认跳过片尾';
    final current = intro ? _skipIntro : _skipOutro;
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(title,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
            for (final s in options)
              ListTile(
                dense: true,
                title: Text(s == 0 ? '关闭' : '$s秒',
                    style: const TextStyle(color: Colors.white70)),
                trailing: current == s
                    ? const Icon(Icons.check, color: AppTheme.accentColor)
                    : null,
                onTap: () => Navigator.pop(ctx, s),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, selected);
    if (mounted) {
      setState(() {
        if (intro) {
          _skipIntro = selected;
        } else {
          _skipOutro = selected;
        }
      });
    }
  }

  /// 清除应用缓存前确认：分项说明清理范围，避免用户担心误清历史/收藏
  Future<void> _confirmClearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('清除应用缓存',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '将清除：\n'
          '· 图片缓存（内存 + 磁盘）\n'
          '· 视频切片与临时文件\n'
          '· 应用缓存目录\n\n'
          '不会清除：观看历史、收藏、源文件 JS、播放设置',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('清除',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await controller.clearCache();
    }
  }

  // ============================================================
  // 关于
  // ============================================================

  Widget _buildAboutSection() {
    return AppCard(
      child: Column(
        children: [
          const SettingsRow(
            icon: Icons.info_outline,
            title: '版本',
            value: '1.0.0',
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
                icon: Icons.public,
                title: '站点数量',
                value: '${ApiConfig.instance.sourceBeanList.length}',
              )),
          Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
                icon: Icons.auto_fix_high,
                title: '解析数量',
                value: '${ApiConfig.instance.parseBeanList.length}',
              )),
          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.person_outline,
            title: '关于版本',
            value: '',
            onTap: () => _showAboutDialog(),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 弹幕 API 编辑弹窗
  // ============================================================

  void _showDanmuApiEditDialog() {
    final textController = TextEditingController(text: _danmuApiUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text(
          '弹幕 API 地址',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: textController,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
              ),
              decoration: InputDecoration(
                hintText: '输入 Logvr-danmu / 弹弹play API 地址，如 https://xx.vercel.app',
                hintStyle: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontSubhead,
                ),
                filled: true,
                fillColor: AppTheme.backgroundTertiary,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSM),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
                prefixIcon: Icon(Icons.subtitles,
                    size: 18, color: AppTheme.textTertiary),
              ),
            ),
            const SizedBox(height: AppTheme.spacingMD),
            Text(
              '播放器会按当前视频 URL 请求 {API}/api/v2/comment?url=... 拉取弹幕',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 11,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              '取消',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              final url = textController.text.trim();
              try {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('danmu_api_url', url);
              } catch (e) { /* ignore */ }
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
                if (mounted) setState(() => _danmuApiUrl = url);
              }
            },
            child: const Text(
              '保存',
              style: TextStyle(color: AppTheme.accentColor),
            ),
          ),
        ],
      ),
    );
  }

  /// 弹幕字号 / 透明度 / 密度 / 速度
  void _showDanmuStyleDialog() {
    var fontSize = _danmuFontSize;
    var opacity = _danmuOpacity;
    var tracks = _danmuTracks;
    var speed = _danmuSpeed;
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: AppTheme.backgroundSecondary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusLG),
              ),
              title: Text(
                '弹幕样式',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('字号 ${fontSize.round()}',
                      style: TextStyle(color: AppTheme.textSecondary)),
                  Slider(
                    value: fontSize,
                    min: 10,
                    max: 28,
                    divisions: 18,
                    onChanged: (v) => setDialogState(() => fontSize = v),
                  ),
                  Text('透明度 ${(opacity * 100).round()}%',
                      style: TextStyle(color: AppTheme.textSecondary)),
                  Slider(
                    value: opacity,
                    min: 0.2,
                    max: 1,
                    divisions: 8,
                    onChanged: (v) => setDialogState(() => opacity = v),
                  ),
                  Text('轨道密度 $tracks 条',
                      style: TextStyle(color: AppTheme.textSecondary)),
                  Slider(
                    value: tracks.toDouble(),
                    min: 2,
                    max: 8,
                    divisions: 6,
                    onChanged: (v) =>
                        setDialogState(() => tracks = v.round()),
                  ),
                  Text('滚动速度 ${speed.round()} px/s',
                      style: TextStyle(color: AppTheme.textSecondary)),
                  Slider(
                    value: speed,
                    min: 80,
                    max: 240,
                    divisions: 16,
                    onChanged: (v) => setDialogState(() => speed = v),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('取消',
                      style: TextStyle(color: AppTheme.textSecondary)),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setDouble('danmu_font_size', fontSize);
                      await prefs.setDouble('danmu_opacity', opacity);
                      await prefs.setInt('danmu_tracks', tracks);
                      await prefs.setDouble('danmu_speed', speed);
                    } catch (_) {}
                    if (ctx.mounted) {
                      Navigator.of(ctx).pop();
                      if (mounted) {
                        setState(() {
                          _danmuFontSize = fontSize;
                          _danmuOpacity = opacity;
                          _danmuTracks = tracks;
                          _danmuSpeed = speed;
                        });
                      }
                    }
                  },
                  child: const Text('保存',
                      style: TextStyle(color: AppTheme.accentColor)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ============================================================
  // API 编辑弹窗（点播接口）
  // ============================================================

  /// 点播接口：支持多源切换（历史源一键切换 + 手动输入新地址）
  void _showApiEditDialog() {
    final vodController =
        TextEditingController(text: controller.vodApiUrl.value);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final history = controller.apiHistory.toList();
            return AlertDialog(
              backgroundColor: AppTheme.backgroundSecondary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusLG),
              ),
              title: Text(
                '点播接口地址',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (history.isNotEmpty) ...[
                      Text(
                        '切换数据源',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: history.length,
                          itemBuilder: (_, i) {
                            final url = history[i];
                            final selected =
                                url == controller.vodApiUrl.value;
                            return InkWell(
                              borderRadius:
                                  BorderRadius.circular(AppTheme.radiusSM),
                              onTap: () {
                                vodController.text = url;
                                setDialogState(() {});
                              },
                              onLongPress: () async {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (c2) => AlertDialog(
                                    backgroundColor:
                                        AppTheme.backgroundSecondary,
                                    title: Text('移除数据源',
                                        style: TextStyle(
                                            color: AppTheme.textPrimary)),
                                    content: Text(
                                      _truncateUrl(url),
                                      style: TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: AppTheme.fontCaption),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c2, false),
                                        child: Text('取消',
                                            style: TextStyle(
                                                color: AppTheme.textTertiary)),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c2, true),
                                        child: Text('移除',
                                            style: TextStyle(
                                                color: Colors.redAccent)),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok == true) {
                                  await controller.removeApiHistory(url);
                                  setDialogState(() {});
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 6, horizontal: 4),
                                child: Row(
                                  children: [
                                    Icon(
                                      selected
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_off,
                                      size: 18,
                                      color: selected
                                          ? AppTheme.accentColor
                                          : AppTheme.textTertiary,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _truncateUrl(url),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: selected
                                              ? AppTheme.accentColor
                                              : AppTheme.textPrimary,
                                          fontSize: AppTheme.fontSubhead,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      Divider(color: AppTheme.borderLight, height: 1),
                      const SizedBox(height: 12),
                      Text(
                        '手动输入 / 修改',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: vodController,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead,
                      ),
                      decoration: InputDecoration(
                        hintText: '输入点播接口地址',
                        hintStyle: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontSubhead,
                        ),
                        filled: true,
                        fillColor: AppTheme.backgroundTertiary,
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusSM),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        isDense: true,
                        prefixIcon: Icon(Icons.movie_outlined,
                            size: 18, color: AppTheme.textTertiary),
                      ),
                    ),
                    Obx(() {
                      if (controller.isLoadingConfig.value) {
                        return Padding(
                          padding:
                              const EdgeInsets.only(top: AppTheme.spacingSM),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.accentColor,
                                ),
                              ),
                              const SizedBox(width: AppTheme.spacingSM),
                              Text(
                                '正在加载配置...',
                                style: TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: AppTheme.fontCaption,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      if (controller.configError.value != null) {
                        return Padding(
                          padding:
                              const EdgeInsets.only(top: AppTheme.spacingSM),
                          child: Text(
                            controller.configError.value!,
                            style: const TextStyle(
                                color: Colors.red,
                                fontSize: AppTheme.fontCaption),
                          ),
                        );
                      }
                      if (controller.configSuccess.value) {
                        return Padding(
                          padding:
                              const EdgeInsets.only(top: AppTheme.spacingSM),
                          child: const Text(
                            '配置加载成功',
                            style: TextStyle(
                                color: AppTheme.accentColor,
                                fontSize: AppTheme.fontCaption),
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('取消',
                      style: TextStyle(color: AppTheme.textTertiary)),
                ),
                Obx(() => TextButton(
                      onPressed: controller.isLoadingConfig.value
                          ? null
                          : () {
                              controller.vodApiUrl.value =
                                  vodController.text.trim();
                              controller.loadConfig();
                              Navigator.pop(ctx);
                            },
                      child: const Text('加载',
                          style: TextStyle(color: AppTheme.accentColor)),
                    )),
              ],
            );
          },
        );
      },
    );
  }
  // ============================================================
  // 主页数据源选择
  // ============================================================

  void _showSourcePicker() {
    final sources = ApiConfig.instance.sourceBeanList;
    if (sources.isEmpty) {
      _showApiEditDialog();
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('主页数据源',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Obx(() {
          final homeKey = ApiConfig.instance.homeSourceBean.value?.key;
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: sources.length,
              itemBuilder: (context, index) {
                final source = sources[index];
                final isHome = homeKey == source.key;
                return Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    title: Text(
                      source.name,
                      style: TextStyle(
                        color: isHome
                            ? AppTheme.accentColor
                            : AppTheme.textPrimary,
                        fontWeight:
                            isHome ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      source.api,
                      style: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: isHome
                        ? const Icon(Icons.check_circle,
                            color: AppTheme.accentColor, size: 16)
                        : null,
                    onTap: () {
                      ApiConfig.instance.setHomeSource(source);
                      Navigator.pop(ctx);
                    },
                  ),
                );
              },
            ),
          );
        }),
      ),
    );
  }

  // ============================================================
  // 通用枚举选择器
  // ============================================================

  void _showEnumSelector<T>({
    required String title,
    required List<T> options,
    required T selected,
    required String Function(T) labelBuilder,
    required ValueChanged<T> onSelect,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title:
            Text(title, style: TextStyle(color: AppTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((option) {
            final isSelected = option == selected;
            return Material(
              color: Colors.transparent,
              child: ListTile(
                dense: true,
                title: Text(labelBuilder(option),
                    style: TextStyle(
                      color: isSelected
                          ? AppTheme.accentColor
                          : AppTheme.textPrimary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    )),
                trailing: isSelected
                    ? const Icon(Icons.check_circle,
                        color: AppTheme.accentColor, size: 18)
                    : null,
                onTap: () {
                  onSelect(option);
                  Navigator.pop(ctx);
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ============================================================
  // 快进步长选择器
  // ============================================================

  void _showTimeStepSelector() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('快进步长',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: controller.playTimeStepOptions.map((step) {
            final isSelected = controller.playTimeStep.value == step;
            return Material(
              color: Colors.transparent,
              child: ListTile(
                dense: true,
                title: Text('$step秒',
                    style: TextStyle(
                      color: isSelected
                          ? AppTheme.accentColor
                          : AppTheme.textPrimary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    )),
                trailing: isSelected
                    ? const Icon(Icons.check_circle,
                        color: AppTheme.accentColor, size: 18)
                    : null,
                onTap: () {
                  controller.setPlayTimeStep(step);
                  Navigator.pop(ctx);
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ============================================================
  // 重置配置对话框 - 清掉已保存的源 URL，重启后回到 setupView
  // ============================================================

  void _showResetConfigDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Row(
          children: [
            Icon(Icons.restart_alt, color: Colors.redAccent, size: 22),
            SizedBox(width: 8),
            Text(
              '重置配置',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          '将清除已保存的点播接口地址、接口历史以及已下载的源缓存。\n\n'
          '播放器、主题、字体等本地设置会保留。\n\n'
          '重置后请重启应用，下次打开将回到初始设置界面。',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await controller.resetConfig();
              if (!mounted) return;
              await showDialog(
                context: context,
                builder: (ctx2) => AlertDialog(
                  backgroundColor: AppTheme.backgroundSecondary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusLG),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle,
                          color: AppTheme.accentColor, size: 48),
                      SizedBox(height: 12),
                      Text(
                        '配置已重置',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        '请退出应用后重新打开，\n将进入初始设置界面。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx2),
                      child: const Text('知道了',
                          style: TextStyle(color: AppTheme.accentColor)),
                    ),
                  ],
                ),
              );
            },
            child: const Text('重置',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 关于版本弹窗
  // ============================================================

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_circle_filled,
                color: AppTheme.accentColor, size: 48),
            const SizedBox(height: AppTheme.spacingLG),
            Text(
              'TVBox',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: AppTheme.spacingXS),
            Text(
              '版本 1.0.0',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
            const SizedBox(height: AppTheme.spacingXS),
            Text(
              '软件作者：包子',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定',
                style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 工具方法
  // ============================================================

  String _truncateUrl(String url) {
    if (url.length > 30) {
      return '${url.substring(0, 27)}...';
    }
    return url;
  }
}

/// 背景预览小方块 - 4 个内置渐变缩略图
class _BackgroundPreviewTile extends StatelessWidget {
  final String name;
  final List<Color> colors;
  final bool isSelected;
  final VoidCallback onTap;

  const _BackgroundPreviewTile({
    required this.name,
    required this.colors,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                ),
                borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.accentColor
                      : AppTheme.borderLight,
                  width: isSelected ? 2 : 0.5,
                ),
              ),
              child: isSelected
                  ? const Center(
                      child: Icon(
                        Icons.check_circle,
                        color: Colors.white,
                        size: 22,
                        shadows: [
                          Shadow(blurRadius: 4, color: Colors.black54),
                        ],
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            name,
            style: TextStyle(
              color: isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
              fontSize: AppTheme.fontCaption,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
