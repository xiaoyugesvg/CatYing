import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../pages/settings/sub/home_pages_settings_page.dart';
import '../../services/nav_feature_service.dart';
import '../widgets/app_toast.dart';
import 'emby_editor_page.dart';
import 'emby_models.dart';
import 'emby_store.dart';

/// 媒体服务器账号管理页（VidHub 风格）。
///
/// 替代旧的 EmbySettingsPage（AlertDialog 编辑弹窗）。
class EmbyAccountsPage extends StatefulWidget {
  const EmbyAccountsPage({super.key});

  @override
  State<EmbyAccountsPage> createState() => _EmbyAccountsPageState();
}

class _EmbyAccountsPageState extends State<EmbyAccountsPage> {
  final _store = EmbyStore.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.load();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openEditor([EmbyServer? existing]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EmbyEditorPage(existing: existing)),
    );
    if (saved == true) {
      await _load();
      if (mounted) {
        AppToast.show(
          existing == null ? '已添加服务器' : '已保存',
          '',
        );
      }
    }
  }

  Future<void> _delete(EmbyServer s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
        ),
        title: Text(
          '删除服务器',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          '确定删除「${s.name}」？仅删除本地配置，不会影响服务端。',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              '取消',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.remove(s.id);
    if (mounted) setState(() {});
  }

  /// 顶部「媒体服务器页签未开启」提示卡
  Widget _buildTabHint() {
    final nav = NavFeatureService.instance;
    if (nav.enabled.contains(NavFeature.emby)) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
      ),
      child: Row(
        children: [
          Icon(
            Icons.video_settings_outlined,
            color: AppTheme.textTertiary,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '「媒体服务器」页签未开启',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '已配置数据，开启后即可从主页访问该模块。',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const HomePagesSettingsPage(),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.accentColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                '去开启',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 点击服务器卡片 = 切换为当前使用中的服务器
  Future<void> _activate(EmbyServer s) async {
    if (s.id == _store.activeId) return;
    await _store.setActive(s.id);
    if (!mounted) return;
    setState(() {});
    AppToast.success('已切换到 ${s.name}');
  }

  Widget _serverCard(EmbyServer s) {
    final active = s.id == _store.activeId;
    final typeLabel = switch (s.type) {
      'jellyfin' => 'Jellyfin',
      'plex' => 'Plex',
      'autoDetect' => '自动探测',
      _ => 'Emby',
    };
    final radius = BorderRadius.circular(AppTheme.glassRadiusCard);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        // 使用中的服务器：浅主题色底 + 描边，一眼看出当前账号
        color: active
            ? AppTheme.accentColor.withValues(alpha: 0.10)
            : AppTheme.backgroundCard,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: active ? null : () => _activate(s),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: active
                  ? Border.all(
                      color: AppTheme.accentColor.withValues(alpha: 0.40),
                      width: 0.8,
                    )
                  : null,
            ),
            child: Row(
              children: [
                // 左侧服务器图标
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppTheme.accentColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                  ),
                  child: Icon(
                    Icons.dns_outlined,
                    color: AppTheme.accentColor,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontSubhead,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (active) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.accentColor,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '使用中',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: AppTheme.fontCaption - 1,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$typeLabel · ${s.username} · ${s.normalizedUrl}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 右侧 ··· 菜单
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_horiz,
                    color: AppTheme.textSecondary,
                  ),
                  color: AppTheme.backgroundElevated,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppTheme.glassRadiusCard),
                  ),
                  onSelected: (v) {
                    if (v == 'edit') _openEditor(s);
                    if (v == 'delete') _delete(s);
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit_outlined,
                              size: 18, color: AppTheme.textSecondary),
                          const SizedBox(width: 8),
                          Text('编辑账号',
                              style: TextStyle(color: AppTheme.textPrimary)),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline,
                              size: 18, color: Colors.redAccent),
                          const SizedBox(width: 8),
                          Text('删除',
                              style: TextStyle(color: Colors.redAccent)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final servers = _store.servers;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new,
              color: AppTheme.textPrimary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: true,
        title: Text(
          '媒体服务器账号',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '添加账号',
            icon: Icon(Icons.person_add_outlined,
                color: AppTheme.textPrimary, size: 22),
            onPressed: () => _openEditor(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildTabHint(),
                if (servers.isEmpty)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.dns_outlined,
                            size: 48,
                            color: AppTheme.textTertiary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '还没有添加服务器',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: AppTheme.fontSubhead,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: () => _openEditor(),
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('添加账号'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.accentColor,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(AppTheme.radiusMD),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 40),
                      itemCount: servers.length,
                      itemBuilder: (_, i) => _serverCard(servers[i]),
                    ),
                  ),
              ],
            ),
    );
  }
}
