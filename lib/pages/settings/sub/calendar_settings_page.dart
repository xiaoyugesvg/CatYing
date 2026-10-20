import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/theme.dart';
import '../../../services/douban_service.dart';
import '../../../services/tmdb_service.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 「追剧日历」设置卡片。
///
/// 用户 2026-10-20：「相关的数据 key 填写就新建一个追剧日历的设置管理卡片」。
/// 这里放三件事：
///   · 豆瓣 Cookie（可选）—— 豆瓣列表接口风控较严时填上更稳；
///   · TMDB API Key（可选）—— 与「TMDB 管理」共用，用于补充信息；
///   · 默认打开周期（今天 / 本周 / 本月）。
class CalendarSettingsPage extends StatefulWidget {
  const CalendarSettingsPage({super.key});

  @override
  State<CalendarSettingsPage> createState() => _CalendarSettingsPageState();
}

class _CalendarSettingsPageState extends State<CalendarSettingsPage> {
  static const String _kDefaultPeriod = 'calendar_default_period';
  static const List<String> _periodLabels = ['今天', '本周', '本月'];

  String _cookie = '';
  int _defaultPeriod = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cookie = await DoubanService.instance.loadCookie();
    var period = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      period = (prefs.getInt(_kDefaultPeriod) ?? 0).clamp(0, 2);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _cookie = cookie;
      _defaultPeriod = period;
    });
  }

  Future<void> _editCookie() async {
    final ctrl = TextEditingController(text: _cookie);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '豆瓣 Cookie',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              maxLines: 4,
              minLines: 3,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontFootnote,
              ),
              decoration: const InputDecoration(
                hintText: '可留空；风控较严时粘贴浏览器里的 Cookie',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '只用于 movie.douban.com 的公开列表接口，不会上传到别处。',
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
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    await DoubanService.instance.saveCookie(saved);
    if (!mounted) return;
    setState(() => _cookie = saved);
    AppToast.message(saved.isEmpty ? '已清除豆瓣 Cookie' : '豆瓣 Cookie 已保存');
  }

  Future<void> _editTmdbKey() async {
    final tmdb = TmdbService.instance;
    final ctrl = TextEditingController(text: tmdb.apiKey.value);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          'TMDB API Key',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: TextField(
          controller: ctrl,
          autocorrect: false,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontFootnote,
          ),
          decoration: const InputDecoration(hintText: '例如 1a2b3c…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    await tmdb.saveApiKey(saved);
    if (!mounted) return;
    setState(() {});
    AppToast.message(saved.isEmpty ? '已清除 TMDB Key' : 'TMDB Key 已保存');
  }

  Future<void> _pickDefaultPeriod() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            for (var i = 0; i < _periodLabels.length; i++)
              ListTile(
                title: Text(
                  _periodLabels[i],
                  style: TextStyle(
                    color: i == _defaultPeriod
                        ? AppTheme.accentColor
                        : AppTheme.textPrimary,
                    fontWeight: i == _defaultPeriod
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                trailing: i == _defaultPeriod
                    ? Icon(Icons.check, color: AppTheme.accentColor, size: 20)
                    : null,
                onTap: () => Navigator.pop(ctx, i),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kDefaultPeriod, picked);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _defaultPeriod = picked);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '追剧日历',
      children: [
        SettingsGroup(
          title: '数据源',
          hint: '列表来自豆瓣公开接口（movie.douban.com/j/search_subjects），'
              '无需 key；TMDB Key 与「TMDB 管理」共用，用于补充信息。',
          children: [
            SettingsRow(
              icon: Icons.cookie_outlined,
              title: '豆瓣 Cookie',
              subtitle: _cookie.isEmpty ? '未填写（可选）' : '已填写',
              value: _cookie.isEmpty ? '未设置' : '已设置',
              onTap: _editCookie,
            ),
            SettingsRow(
              icon: Icons.key_rounded,
              title: 'TMDB API Key',
              subtitle: TmdbService.instance.configured ? '已配置' : '可选',
              value: TmdbService.instance.configured ? '已配置' : '未配置',
              onTap: _editTmdbKey,
            ),
          ],
        ),
        SettingsGroup(
          title: '显示',
          children: [
            SettingsRow(
              icon: Icons.today_rounded,
              title: '默认打开周期',
              subtitle: '进入追剧日历先看哪个时间段',
              value: _periodLabels[_defaultPeriod],
              onTap: _pickDefaultPeriod,
            ),
          ],
        ),
      ],
    );
  }
}
