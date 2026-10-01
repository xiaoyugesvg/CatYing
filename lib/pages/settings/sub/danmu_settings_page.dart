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
        // #11：实时预览 —— 原来调字号/透明度/速度时**看不到任何效果**，
        // 必须退出去播视频才知道对不对，来回试很折磨。
        // 这里给一块模拟视频区，示例弹幕按当前参数滚动。
        _DanmuPreview(
          fontSize: _fontSize,
          opacity: _opacity,
          speed: _speed,
          strokeWidth: _strokeWidth,
        ),
        const SizedBox(height: 14),

        // ================= 服务 =================
        SettingsGroup(
          children: [
            // ⚠️ 这里原来包了 Obx，但 `_enabled` 是普通 bool（本页用 setState 管理），
            // Obx 内没有任何可观察变量 → GetX 抛
            //   "[Get] the improper use of a GetX has been detected"
            // 该异常会让整棵子树被 ErrorWidget 取代，而 ErrorWidget 的高度是
            // **100000px** —— 整页变成一块巨大的空白卡（"长白板"的根因）。
            // 本页是 StatefulWidget + setState，不需要 Obx。
            unifiedSwitchRow(
              icon: Icons.subtitles,
              title: '启用弹幕',
              value: _enabled,
              onChanged: (v) async {
                setState(() => _enabled = v);
                await _saveBool('danmu_enabled', v);
              },
            ),
            unifiedSwitchRow(
              icon: Icons.video_settings,
              title: '优先使用视频返回弹幕数据',
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
              value: _showTop,
              onChanged: (v) async {
                setState(() => _showTop = v);
                await _saveBool('danmu_block_top', !v);
              },
            ),
            unifiedSwitchRow(
              icon: Icons.vertical_align_bottom,
              title: '显示底部弹幕',
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

/// #11：弹幕参数实时预览。
///
/// ── 为什么做成自包含 widget ────────────────────────────────────
/// 页面状态类是 `State<DanmuSettingsPage>`（没有 TickerProvider）。
/// 如果在这个类里加 AnimationController，就得把 mixin 也加上、
/// 并改动 initState/dispose —— 影响面更大。
/// 预览的动画完全属于它自己，做成独立 StatefulWidget 更干净：
/// 页面只管把当前参数**传进来**，动画/重绘都在内部。
class _DanmuPreview extends StatefulWidget {
  const _DanmuPreview({
    required this.fontSize,
    required this.opacity,
    required this.speed,
    required this.strokeWidth,
  });

  final double fontSize;
  final double opacity;

  /// 屏幕宽度/秒（越大越快）
  final double speed;
  final double strokeWidth;

  @override
  State<_DanmuPreview> createState() => _DanmuPreviewState();
}

class _DanmuPreviewState extends State<_DanmuPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  /// 3 条示例弹幕，用不同的纵向位置与相位错开
  static const _samples = [
    ('这画面也太顶了吧', 0.16, 0.0),
    ('前方高能预警', 0.44, 0.35),
    ('哈哈哈哈哈哈', 0.72, 0.68),
  ];

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );
    // ── ⚠️ 预览动画必须是"有终点"的 ─────────────────────────────
    //
    // 我试过两种写法，**都会让测试挂掉**（值得记下来）：
    //   ① `_c.repeat()` —— 无限循环 → `pumpAndSettle()` 永不返回
    //      （它一直等"没有待处理帧"），那个设置页回归测试直接卡 10 分钟
    //   ② `forward()` 完再 `Future.delayed` 循环 —— 虽然动画有终点，
    //      但 `Future.delayed` 会在测试里留下 **pending timer**，
    //      teardown 断言 `!timersPending` 直接失败
    //
    // 所以：**只播一遍，播完停在终点**。
    // 代价是没有"一批批滚动"的连续感；换来的是整页可测、也不会有
    // 后台一直跑的动画耗电。弹幕参数改一下就会重播（见 didUpdateWidget），
    // 所以"改完立刻看到效果"这个核心诉求是满足的。
    _c.value = 0;
    _c.forward();
  }

  @override
  void didUpdateWidget(covariant _DanmuPreview old) {
    super.didUpdateWidget(old);
    // 任一项参数变了就重播一遍 —— 用户拖滑块时立刻看到新效果
    if (old.fontSize != widget.fontSize ||
        old.opacity != widget.opacity ||
        old.speed != widget.speed ||
        old.strokeWidth != widget.strokeWidth) {
      _c.value = 0;
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 130,
      decoration: BoxDecoration(
        // 用深色底模拟视频画面 —— 弹幕本来就主要出现在视频上，
        // 在浅色设置页里用白底预览会看不出白字描边的效果。
        color: const Color(0xFF1A1A1C),
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          return Stack(
            children: [
              // 左上角标一下这是预览，别让用户以为是真在放视频
              Positioned(
                left: 10,
                top: 8,
                child: Row(
                  children: [
                    Icon(Icons.play_circle_outline,
                        size: 12, color: Colors.white.withValues(alpha: 0.35)),
                    const SizedBox(width: 4),
                    Text('预览',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.white.withValues(alpha: 0.35))),
                  ],
                ),
              ),
              for (final (text, top, phase) in _samples)
                AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    // 速度：值越大，走完一屏用的时间越短
                    // speed 范围 60~300 → 周期 6s~1.2s，与真实弹幕观感接近
                    final secs = (300 - widget.speed) / 40 + 1.2;
                    final p = ((_c.value * 6 / secs) + phase) % 1.0;
                    // 从右侧进入、向左移出
                    final x = w - p * (w + 220);
                    return Positioned(
                      left: x,
                      top: 24 + top * 78,
                      child: Opacity(
                        opacity: widget.opacity,
                        child: Text(
                          text,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: widget.fontSize,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            // 描边用 shadows 近似（真实弹幕也是描边+阴影）
                            shadows: widget.strokeWidth <= 0
                                ? null
                                : [
                                    Shadow(
                                        color: Colors.black,
                                        blurRadius: widget.strokeWidth),
                                    const Shadow(
                                        color: Colors.black, blurRadius: 2),
                                  ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}
