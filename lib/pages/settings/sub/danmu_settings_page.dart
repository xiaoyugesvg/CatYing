import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/theme.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 设置 → 弹幕
///
/// 从原 settings/view.dart 拆出：弹幕 API、弹幕样式、屏蔽关键词。
///
/// 本页自持状态并直接读写 SharedPreferences —— 与播放器
/// （video_player.dart 的 `_loadDanmuSettings`）共用同一批 key，
/// 所以这里的改动播放器下次进页面就会生效。
class DanmuSettingsPage extends StatefulWidget {
  const DanmuSettingsPage({super.key});

  @override
  State<DanmuSettingsPage> createState() => _DanmuSettingsPageState();
}

class _DanmuSettingsPageState extends State<DanmuSettingsPage> {
  String _apiUrl = '';
  double _fontSize = 14;
  double _opacity = 1;
  int _tracks = 4;
  double _speed = 150;
  List<String> _blockWords = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _apiUrl = (prefs.getString('danmu_api_url') ?? '').trim();
        _fontSize =
            (prefs.getDouble('danmu_font_size') ?? 14).clamp(10.0, 28.0);
        _opacity =
            (prefs.getDouble('danmu_opacity') ?? 1).clamp(0.2, 1.0);
        _tracks = (prefs.getInt('danmu_tracks') ?? 4).clamp(2, 8);
        _speed =
            (prefs.getDouble('danmu_speed') ?? 150).clamp(80.0, 240.0);
        _blockWords =
            prefs.getStringList('danmu_block_words') ?? const [];
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '弹幕',
      children: [
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.subtitles,
              title: '弹幕 API',
              value: _apiUrl.isEmpty ? '未配置' : _truncate(_apiUrl),
              onTap: _editApi,
            ),
            SettingsRow(
              icon: Icons.format_size,
              title: '弹幕样式',
              value: '${_fontSize.round()}号 · ${(_opacity * 100).round()}%',
              onTap: _editStyle,
            ),
            SettingsRow(
              icon: Icons.block,
              title: '屏蔽关键词',
              value: _blockWords.isEmpty ? '无' : _blockWords.join('、'),
              onTap: _editBlockWords,
            ),
          ],
          hint: '播放器按视频 URL 匹配弹幕（{API}/api/v2/comment?url=...）。\n'
              'spider 源的 CDN 直链常匹配不到，此时会自动改用片名在各源搜索兜底。',
        ),
      ],
    );
  }

  String _truncate(String url) =>
      url.length <= 28 ? url : '${url.substring(0, 25)}...';

  // ============================================================
  // 弹幕 API
  // ============================================================

  Future<void> _editApi() async {
    final url = await SettingsDialogs.editText(
      context: context,
      title: '弹幕 API 地址',
      initial: _apiUrl,
      hint: '如 https://dm.example.com/your-token',
      helper: '播放器会请求 {API}/api/v2/comment?url=... 拉取弹幕。\n'
          '基址支持 host / host/{token} / host/{token}/api/v2 三种写法。',
    );
    if (url == null) return;
    final v = url.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('danmu_api_url', v);
    } catch (_) {}
    if (mounted) setState(() => _apiUrl = v);
  }

  // ============================================================
  // 弹幕样式
  // ============================================================

  Future<void> _editStyle() async {
    var fontSize = _fontSize;
    var opacity = _opacity;
    var tracks = _tracks;
    var speed = _speed;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG),
          ),
          title: Text('弹幕样式',
              style: TextStyle(color: AppTheme.textPrimary)),
          content: SingleChildScrollView(
            child: Column(
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
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('保存',
                  style: TextStyle(color: AppTheme.accentColor)),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('danmu_font_size', fontSize);
      await prefs.setDouble('danmu_opacity', opacity);
      await prefs.setInt('danmu_tracks', tracks);
      await prefs.setDouble('danmu_speed', speed);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _fontSize = fontSize;
        _opacity = opacity;
        _tracks = tracks;
        _speed = speed;
      });
    }
  }

  // ============================================================
  // 屏蔽关键词
  // ============================================================

  Future<void> _editBlockWords() async {
    final text = await SettingsDialogs.editText(
      context: context,
      title: '屏蔽关键词',
      initial: _blockWords.join('\n'),
      hint: '每行一个关键词，命中的弹幕不显示',
      maxLines: 6,
    );
    if (text == null) return;
    final words = text
        .split(RegExp(r'[\n,，、]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('danmu_block_words', words);
    } catch (_) {}
    if (mounted) setState(() => _blockWords = words);
  }
}
