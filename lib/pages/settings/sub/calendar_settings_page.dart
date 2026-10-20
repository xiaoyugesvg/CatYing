import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/theme.dart';
import '../../../services/tmdb_service.dart';
import '../../../services/trakt_service.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 「追剧日历」设置卡片。
///
/// 两块数据：
///   · Trakt 追剧日历：填 Trakt Client ID 后，到追剧日历里用设备码登录；
///   · 豆瓣热播 / 平台剧场 / 骨朵热榜：MineTrakt 同款公开 JSON，无需 Key。
class CalendarSettingsPage extends StatefulWidget {
  const CalendarSettingsPage({super.key});

  @override
  State<CalendarSettingsPage> createState() => _CalendarSettingsPageState();
}

class _CalendarSettingsPageState extends State<CalendarSettingsPage> {
  static const String _kDefaultPeriod = 'calendar_default_period';
  static const List<String> _periodLabels = ['今天', '本周', '本月'];

  int _defaultPeriod = 0;
  bool _traktLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var period = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      period = (prefs.getInt(_kDefaultPeriod) ?? 0).clamp(0, 2);
    } catch (_) {}
    await TraktService.instance.load();
    if (!mounted) return;
    setState(() {
      _defaultPeriod = period;
      _traktLoggedIn = TraktService.instance.loggedIn;
    });
  }

  Future<void> _editTraktClientId() async {
    final ctrl = TextEditingController(text: TraktService.instance.clientId);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          'Trakt Client ID',
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
              autocorrect: false,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontFootnote,
              ),
              decoration: const InputDecoration(
                hintText: '在 trakt.tv/oauth/applications 创建应用后获取',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '只保存 Client ID（设备码 + PKCE 授权，不需要 Client Secret）。',
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
    await TraktService.instance.saveClientId(saved);
    if (!mounted) return;
    setState(() {});
    AppToast.message(saved.isEmpty ? '已清除 Trakt Client ID' : 'Trakt Client ID 已保存');
  }

  Future<void> _logoutTrakt() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('退出 Trakt 登录？',
            style: TextStyle(color: AppTheme.textPrimary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (yes != true) return;
    await TraktService.instance.logout();
    if (!mounted) return;
    setState(() => _traktLoggedIn = false);
    AppToast.message('已退出 Trakt');
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
          title: 'Trakt 追剧日历',
          hint: '在 trakt.tv/oauth/applications 新建应用（Redirect URI 填 '
              'urn:ietf:wg:oauth:2.0:oob），把 Client ID 填到这里，'
              '然后到「追剧日历 → 追剧日历 tab」点登录。',
          children: [
            SettingsRow(
              icon: Icons.vpn_key_outlined,
              title: 'Trakt Client ID',
              subtitle: TraktService.instance.configured
                  ? '已填写'
                  : '未填写（追剧日历需要）',
              value: TraktService.instance.configured ? '已配置' : '未配置',
              onTap: _editTraktClientId,
            ),
            SettingsRow(
              icon: Icons.login_rounded,
              title: 'Trakt 登录状态',
              subtitle: _traktLoggedIn
                  ? '已登录，点击可退出'
                  : '未登录（到追剧日历里点「开始登录」）',
              value: _traktLoggedIn ? '已登录' : '未登录',
              onTap: _traktLoggedIn ? _logoutTrakt : null,
            ),
          ],
        ),
        SettingsGroup(
          title: '公开榜单',
          hint: '与 MineTrakt 相同：豆瓣热播 / 平台剧场 / 骨朵热榜三份公开 JSON，'
              '自带 TMDB 海报与更新日期，无需 Key；TMDB Key 仅用于图片代理。',
          children: [
            const SettingsRow(
              icon: Icons.cloud_download_outlined,
              title: '日历数据源',
              subtitle: '豆瓣热播 · 平台剧场 · 骨朵热榜（公开 JSON）',
              value: '内置',
            ),
            SettingsRow(
              icon: Icons.key_rounded,
              title: 'TMDB API Key',
              subtitle: TmdbService.instance.configured
                  ? '已配置（图片走 TMDB 代理）'
                  : '可选（不填也能看海报）',
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
