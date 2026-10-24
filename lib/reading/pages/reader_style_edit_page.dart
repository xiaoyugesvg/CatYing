import 'package:flutter/material.dart';

import '../models/reader_style.dart';
import '../models/reader_bg_assets.dart';
import '../models/reader_title_style.dart';

/// 单套「阅读样式」编辑器。
///
/// 同时服务两个入口：
///   · 阅读器 → 排版 → 样式库 → 编辑
///   · 阅读模块「我的」→ 阅读样式 → 编辑
///
/// 只改【样式参数】本身（配色/排版/边距/标题/页脚），不做预览渲染 ——
/// 预览在样式库列表里已经有一张小样，这里保持表单紧凑。
class ReaderStyleEditPage extends StatefulWidget {
  const ReaderStyleEditPage({
    super.key,
    required this.style,
    required this.background,
    required this.foreground,
    this.title = '编辑样式',
  });

  final ReaderStyle style;
  final Color background;
  final Color foreground;
  final String title;

  @override
  State<ReaderStyleEditPage> createState() => _ReaderStyleEditPageState();
}

class _ReaderStyleEditPageState extends State<ReaderStyleEditPage> {
  late TextEditingController _name;
  late TextEditingController _footerC;
  late double _fontSize;
  late double _lineHeight;
  late double _letterSpacing;
  late double _paraSpacing;
  late double _indent;
  late double _padLeft;
  late double _padRight;
  late double _padTop;
  late double _padBottom;
  late double _headerPadTop;
  late double _footerPadBottom;
  late int? _bgDay;
  late int? _bgNight;
  late int? _fgDay;
  late int? _fgNight;
  late String? _bgAssetDay;
  late String? _bgAssetNight;
  late ReaderTitleStyle _titleStyle;
  late bool _titleBold;

  Color get _fg => widget.foreground;
  Color get _bg => widget.background;

  static const _bgPresets = <int>[
    0xFFFFFFFF,
    0xFFFAF8F3,
    0xFFF5EFE0,
    0xFFEBD9BB,
    0xFFDDC090,
    0xFFC2D8AA,
    0xFFABCEE0,
    0xFFDBB8E2,
    0xFFD6D5D6,
    0xFFEEEEEE,
    0xFF1F232B,
    0xFF292D37,
    0xFF000000,
  ];

  static const _fgPresets = <int>[
    0xFF000000,
    0xFF1A1A1A,
    0xFF323232,
    0xFF3E3422,
    0xFF63543C,
    0xFF3E3D3B,
    0xFF3D4C54,
    0xFF596C44,
    0xFF386068,
    0xFF8E96A3,
    0xFFC8C8C8,
    0xFFE8E8E8,
  ];

  @override
  void initState() {
    super.initState();
    final s = widget.style;
    _name = TextEditingController(text: s.name);
    _footerC = TextEditingController(text: s.footerC);
    _fontSize = s.fontSize;
    _lineHeight = s.lineHeight;
    _letterSpacing = s.letterSpacing;
    _paraSpacing = s.paraSpacing;
    _indent = s.indent;
    _padLeft = s.padLeft;
    _padRight = s.padRight;
    _padTop = s.padTop;
    _padBottom = s.padBottom;
    _headerPadTop = s.headerPadTop;
    _footerPadBottom = s.footerPadBottom;
    _bgDay = s.bgColor;
    _bgNight = s.bgColorNight;
    _fgDay = s.fgColor;
    _fgNight = s.fgColorNight;
    _bgAssetDay = s.bgImageAsset;
    _bgAssetNight = s.bgImageAssetNight;
    _titleStyle = ReaderTitleStyle.fromId(s.chapterTitleStyle);
    _titleBold = s.titleBold;
  }

  @override
  void dispose() {
    _name.dispose();
    _footerC.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final out = ReaderStyle.fromJson({
      ...widget.style.toJson(),
      'name': name.isEmpty ? widget.style.name : name,
      'fontSize': _fontSize,
      'lineHeight': _lineHeight,
      'letterSpacing': _letterSpacing,
      'paraSpacing': _paraSpacing,
      'indent': _indent,
      'padLeft': _padLeft,
      'padRight': _padRight,
      'padTop': _padTop,
      'padBottom': _padBottom,
      'headerPadTop': _headerPadTop,
      'footerPadBottom': _footerPadBottom,
      'bgColor': _bgDay,
      'bgColorNight': _bgNight,
      'fgColor': _fgDay,
      'fgColorNight': _fgNight,
      'bgImageAsset': _bgAssetDay,
      'bgImageAssetNight': _bgAssetNight,
      'chapterTitleStyle': _titleStyle.id,
      'titleBold': _titleBold,
      'footerC': _footerC.text.trim(),
    });
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: _fg,
        title: Text(
          widget.title,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _fg),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text('保存', style: TextStyle(color: _fg, fontSize: 15)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          _field(
            TextField(
              controller: _name,
              style: TextStyle(color: _fg, fontSize: 15),
              decoration: InputDecoration(
                labelText: '样式名称',
                labelStyle: TextStyle(color: _fg.withValues(alpha: 0.5)),
                filled: true,
                fillColor: _fg.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          _section('排版'),
          _slider('字号', _fontSize, 12, 30, _fontSize.round().toString(), (v) {
            setState(() => _fontSize = v);
          }, step: 1),
          // 取值范围与阅读器套用时的 clamp 对齐（1.05~3.0 / -2~8 / 左右 0~80），
          // 否则导入的高行高样式一进编辑器就被"看不见地夹住"
          _slider('行高', _lineHeight, 1.05, 3.0, _lineHeight.toStringAsFixed(2), (v) {
            setState(() => _lineHeight = v);
          }, step: 0.05),
          _slider('字距', _letterSpacing, -2, 8, _letterSpacing.toStringAsFixed(1), (v) {
            setState(() => _letterSpacing = v);
          }, step: 0.1),
          _slider('段距', _paraSpacing, 0, 2, '${_paraSpacing.toStringAsFixed(2)}x', (v) {
            setState(() => _paraSpacing = v);
          }, step: 0.05),
          _slider('首行缩进', _indent, 0, 4, '${_indent.round()} 字', (v) {
            setState(() => _indent = v);
          }, step: 1),
          _section('边距'),
          _slider('左', _padLeft, 0, 80, _padLeft.round().toString(), (v) {
            setState(() => _padLeft = v);
          }, step: 1),
          _slider('右', _padRight, 0, 80, _padRight.round().toString(), (v) {
            setState(() => _padRight = v);
          }, step: 1),
          _slider('上', _padTop, 0, 120, _padTop.round().toString(), (v) {
            setState(() => _padTop = v);
          }, step: 1),
          _slider('下', _padBottom, 0, 120, _padBottom.round().toString(), (v) {
            setState(() => _padBottom = v);
          }, step: 1),
          _section('背景图（日 / 夜）'),
          _wallpapers('日间', _bgAssetDay, (v) {
            setState(() {
              _bgAssetDay = v;
              // 选到黑白成对的图（古风/泼墨/皮卡丘）时顺手补上夜间那张
              final pair = ReaderBgAssets.pairOf(v);
              if (pair != null && _bgAssetNight == null) _bgAssetNight = pair;
            });
          }, assets: ReaderBgAssets.picker),
          _wallpapers('夜间', _bgAssetNight, (v) {
            setState(() => _bgAssetNight = v);
          }),
          _section('配色'),
          _swatches('背景（日间）', _bgDay, _bgPresets, (v) {
            setState(() => _bgDay = v);
          }),
          _swatches('背景（夜间）', _bgNight, _bgPresets, (v) {
            setState(() => _bgNight = v);
          }),
          _swatches('文字（日间）', _fgDay, _fgPresets, (v) {
            setState(() => _fgDay = v);
          }),
          _swatches('文字（夜间）', _fgNight, _fgPresets, (v) {
            setState(() => _fgNight = v);
          }),
          _section('章标题'),
          DropdownButtonFormField<ReaderTitleStyle>(
            initialValue: _titleStyle,
            dropdownColor: _bg,
            style: TextStyle(color: _fg, fontSize: 14),
            decoration: InputDecoration(
              filled: true,
              fillColor: _fg.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
            ),
            items: [
              for (final t in ReaderTitleStyle.values)
                DropdownMenuItem(
                  value: t,
                  child: Text(t.label, style: TextStyle(color: _fg)),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _titleStyle = v);
            },
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _titleBold,
            activeThumbColor: _fg,
            title: Text(
              '章标题加粗',
              style: TextStyle(color: _fg, fontSize: 14),
            ),
            onChanged: (v) => setState(() => _titleBold = v),
          ),
          _section('页脚'),
          TextField(
            controller: _footerC,
            style: TextStyle(color: _fg, fontSize: 14),
            decoration: InputDecoration(
              hintText: '如：第p页 / % / 第c/C章',
              hintStyle: TextStyle(color: _fg.withValues(alpha: 0.35)),
              filled: true,
              fillColor: _fg.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '占位符：p 页码 · P 总页 · % 进度 · c 章号 · C 总章 · # 章节名 · B 书名 · t 时间 · b/n 电量',
            style: TextStyle(fontSize: 11, color: _fg.withValues(alpha: 0.45)),
          ),
        ],
      ),
    );
  }

  Widget _field(Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: child,
  );

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: _fg.withValues(alpha: 0.5),
        letterSpacing: 0.3,
      ),
    ),
  );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    String display,
    ValueChanged<double> onChanged, {
    double step = 1,
  }) {
    final v = value.clamp(min, max).toDouble();
    return Row(
      children: [
        SizedBox(
          width: 58,
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: _fg.withValues(alpha: 0.75)),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: _fg,
              inactiveTrackColor: _fg.withValues(alpha: 0.18),
              thumbColor: _fg,
            ),
            child: Slider(
              value: v,
              min: min,
              max: max,
              divisions: ((max - min) / step).round(),
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, color: _fg.withValues(alpha: 0.6)),
          ),
        ),
      ],
    );
  }

  /// 日间 / 夜间壁纸选择（横向缩略图，第一格是「无」）
  ///
  /// [assets] 缺省 = 全部；日间列表传 [ReaderBgAssets.picker]（不重复列夜版）。
  Widget _wallpapers(
    String label,
    String? current,
    ValueChanged<String?> onChanged, {
    List<String> assets = ReaderBgAssets.all,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label壁纸',
            style: TextStyle(fontSize: 12, color: _fg.withValues(alpha: 0.55)),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 54,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: assets.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (c, i) {
                if (i == 0) return _wallTile(null, current == null, onChanged);
                final asset = assets[i - 1];
                return _wallTile(asset, current == asset, onChanged);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _wallTile(
    String? asset,
    bool selected,
    ValueChanged<String?> onChanged,
  ) {
    return GestureDetector(
      onTap: () => onChanged(asset),
      child: Container(
        width: 40,
        height: 54,
        decoration: BoxDecoration(
          color: _fg.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _fg : _fg.withValues(alpha: 0.2),
            width: selected ? 2 : 1,
          ),
          image: asset == null
              ? null
              : DecorationImage(image: AssetImage(asset), fit: BoxFit.cover),
        ),
        child: asset == null
            ? Icon(Icons.block, size: 14, color: _fg.withValues(alpha: 0.6))
            : null,
      ),
    );
  }

  Widget _swatches(
    String label,
    int? current,
    List<int> presets,
    ValueChanged<int?> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: _fg.withValues(alpha: 0.55)),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _swatch(
                color: null,
                selected: current == null,
                onTap: () => onChanged(null),
              ),
              for (final c in presets)
                _swatch(
                  color: Color(c),
                  selected: current == c,
                  onTap: () => onChanged(c),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _swatch({
    required Color? color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color ?? Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _fg : _fg.withValues(alpha: 0.22),
            width: selected ? 2 : 1,
          ),
        ),
        child: color == null
            ? Icon(Icons.block, size: 14, color: _fg.withValues(alpha: 0.6))
            : null,
      ),
    );
  }
}
