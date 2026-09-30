import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/theme.dart';
import '../../../widgets/common_widgets.dart';
import '../../webview/view.dart';
import 'settings_shared.dart';

/// 弹幕服务来源
enum DanmuSource {
  local('local', '本地服务'),
  builtin('builtin', '订阅自带'),
  remote('remote', '自定义远程');

  const DanmuSource(this.id, this.label);
  final String id;
  final String label;

  static DanmuSource fromId(String? v) => DanmuSource.values
      .firstWhere((e) => e.id == v, orElse: () => DanmuSource.remote);
}

/// 设置 → 弹幕服务（详细）
///
/// 与播放器共用同一批 SharedPreferences key —— 这里改完，
/// 播放器下次进入页面（`_loadDanmuSettings`）即生效。
class DanmuSettingsPage extends StatefulWidget {
  const DanmuSettingsPage({super.key});

  @override
  State<DanmuSettingsPage> createState() => _DanmuSettingsPageState();
}

class _DanmuSettingsPageState extends State<DanmuSettingsPage> {
  // ---- 服务 ----
  bool _enabled = true;
  bool _preferVideoDanmu = false;
  DanmuSource _source = DanmuSource.remote;
  String _apiUrl = '';

  // ---- 显示 ----
  bool _showTop = true;
  bool _showBottom = true;
  bool _showScroll = true;
  bool _syncSpeed = false;
  String _colorMode = 'builtin'; // builtin=自带色 / white / custom
  List<String> _blockWords = [];

  // ---- 样式数值 ----
  double _fontSize = 16;
  double _lineSpacing = 1.6;
  double _opacity = 1.0;
  double _areaRatio = 1.0;
  double _speed = 150;
  double _strokeWidth = 1.5;
  int _fontWeight = 500;
  double _delaySeconds = 0.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _enabled = p.getBool('danmu_enabled') ?? true;
      _preferVideoDanmu = p.getBool('danmu_prefer_video') ?? false;
      _source = DanmuSource.fromId(p.getString('danmu_source'));
      _apiUrl = (p.getString('danmu_api_url') ?? '').trim();

      _showTop = !(p.getBool('danmu_block_top') ?? false);
      _showBottom = !(p.getBool('danmu_block_bottom') ?? false);
      _showScroll = !(p.getBool('danmu_block_scroll') ?? false);
      _syncSpeed = p.getBool('danmu_sync_speed') ?? false;
      _colorMode = p.getString('danmu_color_mode') ?? 'builtin';
      _blockWords = p.getStringList('danmu_block_words') ?? const [];

      _fontSize =
          (p.getDouble('danmu_font_size') ?? 16).clamp(10.0, 28.0);
      _lineSpacing =
          (p.getDouble('danmu_line_spacing') ?? 1.6).clamp(1.0, 3.0);
      _opacity = (p.getDouble('danmu_opacity') ?? 1.0).clamp(0.2, 1.0);
      _areaRatio =
          (p.getDouble('danmu_area_ratio') ?? 1.0).clamp(0.25, 1.0);
      _speed = (p.getDouble('danmu_speed') ?? 150).clamp(60.0, 300.0);
      _strokeWidth =
          (p.getDouble('danmu_stroke_width') ?? 1.5).clamp(0.0, 3.0);
      _fontWeight = p.getInt('danmu_font_weight') ?? 500;
      _delaySeconds =
          (p.getDouble('danmu_delay_seconds') ?? 0.0).clamp(-5.0, 5.0);
    });
  }

  Future<void> _saveBool(String k, bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(k, v);
  }

  Future<void> _saveDouble(String k, double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(k, v);
  }

  Future<void> _saveInt(String k, int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(k, v);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '弹幕服务',
      children: [
        // ================= 服务 =================
        SettingsGroup(
          children: [
            Obx(() => unifiedSwitchRow(
                  icon: Icons.subtitles,
                  title: '启用弹幕',
                  value: _enabled,
                  onChanged: (v) async {
                    setState(() => _enabled = v);
                    await _saveBool('danmu_enabled', v);
                  },
                )),
            unifiedSwitchRow(
              icon: Icons.video_settings,
              title: '优先使用视频返回弹幕数据',
              subtitle: '播放时优先加载播放接口返回的弹幕，未返回或加载失败时回退自动匹配',
              value: _preferVideoDanmu,
              onChanged: (v) async {
                setState(() => _preferVideoDanmu = v);
                await _saveBool('danmu_prefer_video', v);
              },
            ),
            const SizedBox(height: 6),
            // 服务来源：三段切换
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 8),
                    child: Text('弹幕服务来源',
                        style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: AppTheme.fontSubhead)),
                  ),
                  _sourceSelector(),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ================= 自定义远程服务 =================
        if (_source == DanmuSource.remote) ...[
          AppCard(
            dense: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                  child: Row(
                    children: [
                      // 图标与全站统一：强调色圆角容器（原来是写死的品牌蓝圆）
                      Container(
                        width: 38,
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.accentColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color:
                                  AppTheme.accentColor.withValues(alpha: 0.24),
                              width: 0.5),
                        ),
                        child: Icon(Icons.public,
                            size: 19, color: AppTheme.accentColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('自定义远程服务',
                                style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(
                              _apiUrl.isEmpty ? '未配置' : _apiUrl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: AppTheme.textTertiary,
                                  fontSize: AppTheme.fontCaption),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 服务地址
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('服务地址',
                          style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: AppTheme.fontSubhead)),
                      const SizedBox(height: 6),
                      _urlField(),
                    ],
                  ),
                ),
                // 保存
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _saveUrl,
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppTheme.accentColor,
                        borderRadius:
                            BorderRadius.circular(AppTheme.glassRadiusSmall),
                      ),
                      child: const Text('保存',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // 打开网页
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _openWeb,
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(AppTheme.glassRadiusSmall),
                        border: Border.all(
                            color: AppTheme.accentColor, width: 1),
                      ),
                      child: Text('打开网页',
                          style: TextStyle(
                              color: AppTheme.accentColor,
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.spacingLG),
        ],

        // ================= 显示 =================
        SettingsGroup(
          children: [
            unifiedSwitchRow(
              icon: Icons.vertical_align_top,
              title: '显示顶部弹幕',
              subtitle: '关闭后该位置弹幕改为滚动显示',
              value: _showTop,
              onChanged: (v) async {
                setState(() => _showTop = v);
                await _saveBool('danmu_block_top', !v);
              },
            ),
            unifiedSwitchRow(
              icon: Icons.vertical_align_bottom,
              title: '显示底部弹幕',
              subtitle: '关闭后该位置弹幕改为滚动显示',
              value: _showBottom,
              onChanged: (v) async {
                setState(() => _showBottom = v);
                await _saveBool('danmu_block_bottom', !v);
              },
            ),
            unifiedSwitchRow(
              icon: Icons.swap_horiz,
              title: '显示滚动弹幕',
              value: _showScroll,
              onChanged: (v) async {
                setState(() => _showScroll = v);
                await _saveBool('danmu_block_scroll', !v);
              },
            ),
            unifiedSwitchRow(
              icon: Icons.sync,
              title: '同步视频速度',
              subtitle: '倍速播放时弹幕滚动同比缩放',
              value: _syncSpeed,
              onChanged: (v) async {
                setState(() => _syncSpeed = v);
                await _saveBool('danmu_sync_speed', v);
              },
            ),
            SettingsRow(
              icon: Icons.palette_outlined,
              title: '弹幕颜色',
              value: _colorModeText,
              onTap: _pickColorMode,
            ),
            SettingsRow(
              icon: Icons.block,
              title: '屏蔽词',
              value: _blockWords.isEmpty ? '无' : '${_blockWords.length} 个',
              onTap: _editBlockWords,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ================= 样式数值 =================
        AppCard(
          dense: true,
          child: Column(
            children: [
              _sliderRow(
                label: '字号',
                value: _fontSize,
                min: 10,
                max: 28,
                divisions: 18,
                text: '${_fontSize.round()}',
                onChanged: (v) async {
                  setState(() => _fontSize = v);
                  await _saveDouble('danmu_font_size', v);
                },
              ),
              _sliderRow(
                label: '行间距',
                value: _lineSpacing,
                min: 1.0,
                max: 3.0,
                divisions: 20,
                text: _lineSpacing.toStringAsFixed(1),
                onChanged: (v) async {
                  setState(() => _lineSpacing = v);
                  await _saveDouble('danmu_line_spacing', v);
                },
              ),
              _sliderRow(
                label: '透明度',
                value: _opacity,
                min: 0.2,
                max: 1.0,
                divisions: 16,
                text: _opacity.toStringAsFixed(2),
                onChanged: (v) async {
                  setState(() => _opacity = v);
                  await _saveDouble('danmu_opacity', v);
                },
              ),
              _sliderRow(
                label: '显示区域',
                value: _areaRatio,
                min: 0.25,
                max: 1.0,
                divisions: 15,
                text: _areaRatio.toStringAsFixed(2),
                onChanged: (v) async {
                  setState(() => _areaRatio = v);
                  await _saveDouble('danmu_area_ratio', v);
                },
              ),
              _sliderRow(
                label: '滚动速度',
                value: _speed,
                min: 60,
                max: 300,
                divisions: 24,
                text: '${_speed.round()}',
                onChanged: (v) async {
                  setState(() => _speed = v);
                  await _saveDouble('danmu_speed', v);
                },
              ),
              _sliderRow(
                label: '描边',
                value: _strokeWidth,
                min: 0.0,
                max: 3.0,
                divisions: 6,
                text: _strokeWidth.toStringAsFixed(1),
                onChanged: (v) async {
                  setState(() => _strokeWidth = v);
                  await _saveDouble('danmu_stroke_width', v);
                },
              ),
              _sliderRow(
                label: '字体粗细',
                value: _fontWeight.toDouble(),
                min: 400,
                max: 700,
                divisions: 3,
                text: '$_fontWeight',
                onChanged: (v) async {
                  final w = v.round();
                  setState(() => _fontWeight = w);
                  await _saveInt('danmu_font_weight', w);
                },
              ),
              _sliderRow(
                label: '弹幕延迟',
                value: _delaySeconds,
                min: -5.0,
                max: 5.0,
                divisions: 100,
                text: '${_delaySeconds.toStringAsFixed(1)} 秒',
                onChanged: (v) async {
                  setState(() => _delaySeconds = v);
                  await _saveDouble('danmu_delay_seconds', v);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.spacingSM),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '播放器按视频 URL 匹配弹幕（{API}/api/v2/comment?url=...）。\n'
            'spider 源的 CDN 直链常匹配不到，此时会自动改用片名在各源搜索兜底。',
            style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
                height: 1.5),
          ),
        ),
      ],
    );
  }

  String get _colorModeText => switch (_colorMode) {
        'white' => '统一白色',
        'custom' => '自定义',
        _ => '自带色',
      };

  // ============================================================
  // 组件
  // ============================================================

  /// 三段服务来源选择（本地服务 / 订阅自带 / 自定义远程）
  Widget _sourceSelector() {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
      ),
      child: Row(
        children: [
          for (var i = 0; i < DanmuSource.values.length; i++) ...[
            if (i > 0)
              Container(
                width: 1,
                height: 16,
                color: AppTheme.borderMedium.withValues(alpha: 0.6),
              ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  setState(() => _source = DanmuSource.values[i]);
                  final p = await SharedPreferences.getInstance();
                  await p.setString(
                      'danmu_source', DanmuSource.values[i].id);
                },
                child: Container(
                  alignment: Alignment.center,
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: _source == DanmuSource.values[i]
                        ? AppTheme.backgroundElevated
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    border: _source == DanmuSource.values[i]
                        ? Border.all(
                            color: AppTheme.glassBorder, width: 0.6)
                        : null,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_sourceIcon(DanmuSource.values[i]),
                          size: 13,
                          color: _source == DanmuSource.values[i]
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        DanmuSource.values[i].label,
                        style: TextStyle(
                          color: _source == DanmuSource.values[i]
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary,
                          fontSize: AppTheme.fontCaption,
                          fontWeight: _source == DanmuSource.values[i]
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _sourceIcon(DanmuSource s) => switch (s) {
        DanmuSource.local => Icons.cloud_off,
        DanmuSource.builtin => Icons.cloud_outlined,
        DanmuSource.remote => Icons.dns_outlined,
      };

  Widget _urlField() {
    final ctrl = TextEditingController(text: _apiUrl)
      ..selection = TextSelection.collapsed(offset: _apiUrl.length);
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              cursorColor: AppTheme.accentColor,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
              onChanged: (v) => _apiUrl = v,
              decoration: InputDecoration(
                hintText: 'https://dm.example.com/your-token',
                hintStyle: TextStyle(
                    color: AppTheme.textTertiary, fontSize: 13),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          if (_apiUrl.isNotEmpty)
            GestureDetector(
              onTap: () {
                ctrl.clear();
                setState(() => _apiUrl = '');
              },
              child: Icon(Icons.cancel,
                  size: 17, color: AppTheme.textTertiary),
            ),
        ],
      ),
    );
  }

  /// 标签 + 右侧数值 + 滑条（对应参考图一屏多个滑条）
  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String text,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
              Text(label,
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead + 0.5)),
              const Spacer(),
              Text(text,
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead)),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              activeTrackColor: AppTheme.accentColor,
              inactiveTrackColor:
                  AppTheme.textTertiary.withValues(alpha: 0.28),
              thumbColor: AppTheme.accentColor,
              overlayColor: AppTheme.accentColor.withValues(alpha: 0.12),
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 行为
  // ============================================================

  Future<void> _saveUrl() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('danmu_api_url', _apiUrl.trim());
    _apiUrl = _apiUrl.trim();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已保存')));
  }

  Future<void> _openWeb() async {
    final url = _apiUrl.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先填写服务地址')));
      return;
    }
    // 用应用内的 WebView 页面浏览弹幕服务（它没有命名路由，直接构造）
    Get.to(() => InAppWebViewPage(url: url, title: '弹幕服务'));
  }

  Future<void> _pickColorMode() async {
    final v = await SettingsDialogs.pick<String>(
      context: context,
      title: '弹幕颜色',
      options: const ['builtin', 'white', 'custom'],
      selected: _colorMode,
      labelBuilder: (x) => switch (x) {
        'white' => '统一白色',
        'custom' => '自定义',
        _ => '自带色',
      },
    );
    if (v == null) return;
    setState(() => _colorMode = v);
    final p = await SharedPreferences.getInstance();
    await p.setString('danmu_color_mode', v);
  }

  /// 屏蔽词编辑（多词，逗号/换行分隔）
  Future<void> _editBlockWords() async {
    final r = await SettingsDialogs.editText(
      context: context,
      title: '屏蔽词',
      initial: _blockWords.join('，'),
      hint: '多个词用逗号分隔，如：剧透，广告',
      helper: '命中的弹幕会被过滤掉。清空则取消屏蔽。',
    );
    if (r == null) return;
    final words = r
        .split(RegExp(r'[,，\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    setState(() => _blockWords = words);
    final p = await SharedPreferences.getInstance();
    await p.setStringList('danmu_block_words', words);
    if (mounted) {
      Clipboard.setData(ClipboardData(text: words.join(',')));
    }
  }
}
