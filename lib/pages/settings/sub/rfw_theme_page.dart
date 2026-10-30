import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/rfw_theme/rfw_theme_store.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

/// 设置 → 主页页面 → RFW 首页主题
///
/// ⚠️ **只作用于影视模块的首页**：换主题只改「分类 / 筛选 / 推荐 / 片单」
/// 这一块的排版与配色，音乐、阅读、直播、设置等页面完全不受影响。
/// 原因见 [RfwThemeEntry] 的注释 —— 主题能用的两个库
/// （`core.widgets` / `peek.home`）本来就是为首页片单设计的。
class RfwThemePage extends StatefulWidget {
  const RfwThemePage({super.key});

  @override
  State<RfwThemePage> createState() => _RfwThemePageState();
}

class _RfwThemePageState extends State<RfwThemePage> {
  List<RfwThemeEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await loadRfwThemeEntries();
    if (!mounted) return;
    setState(() {
      _entries = list;
      _loading = false;
    });
  }

  Future<void> _import() async {
    final result = await pickAndImportRfwTheme();
    if (result == null) return;
    if (!mounted) return;
    if (!result.ok) {
      AppToast.error(result.message);
      return;
    }
    AppToast.success(result.message);
    final entry = result.entry;
    if (entry != null) await saveRfwThemeId(entry.id);
    await _reload();
  }

  Future<void> _delete(RfwThemeEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除主题'),
        content: Text('确定删除「${entry.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await deleteImportedRfwTheme(entry);
    if (rfwThemeIdNotifier.value == entry.id) {
      await saveRfwThemeId(null);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: 'RFW 首页主题',
      help: const [
        SettingsHelpItem(
          icon: Icons.dashboard_customize_outlined,
          title: '这是什么',
          body: '用一段文本（.rfwtxt）描述的**影视首页皮肤**：分类、筛选、推荐位、'
              '片单网格长什么样，全由主题决定。它只管首页，播放页/详情页/'
              '其它模块都不受影响。默认关闭，保持原生首页。',
        ),
        SettingsHelpItem(
          icon: Icons.palette_outlined,
          title: '配色会跟着软件走',
          body: '三个内置主题的颜色不是写死的，而是从「外观 → 主题」里你当前选的'
              '那套配色实时算出来的：换配色，首页跟着变。'
              '晨光偏暖、素影完全跟随、星河强制深色但取你的强调色做底。',
        ),
        SettingsHelpItem(
          icon: Icons.grid_view_rounded,
          title: '显示样式怎么选',
          body: '网格/大网格适合挑海报；列表信息多、扫得快；'
              '横幅适合有横图的源；纯文字列表最省流量。'
              '换样式只改排版，不改内容。',
        ),
        SettingsHelpItem(
          icon: Icons.upload_file_rounded,
          title: '导入自己的主题',
          body: '点「导入主题文件」选一个 .rfwtxt。主题只能引用内置的两个库'
              '（core.widgets / peek.home），越权的文件会被拒绝 —— '
              '这是防止主题拿到系统能力的安全边界。导入后长按可删除。',
        ),
        SettingsHelpItem(
          icon: Icons.report_problem_outlined,
          title: '首页显示成一片「?」或空白',
          body: '「?」是主题里的图标缺字体信息（老版本主题的问题，重新导入或换内置主题'
              '即可）。空白/报错说明主题解析失败，换回内置主题先保证能用。',
        ),
      ],
      children: [
        ListenableBuilder(
          listenable: Listenable.merge([
            rfwThemeModeNotifier,
            rfwThemeIdNotifier,
            rfwDisplayStyleNotifier,
          ]),
          builder: (context, _) {
            final enabled = rfwThemeModeNotifier.value;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsGroup(
                  children: [
                    unifiedSwitchRow(
                      icon: Icons.auto_awesome_outlined,
                      title: '启用 RFW 主题',
                      subtitle: '只改影视首页（分类/筛选/推荐/片单），其他模块不变',
                      value: enabled,
                      onChanged: (v) => saveRfwThemeMode(v),
                    ),
                  ],
                ),
                if (enabled)
                  SettingsGroup(
                    title: '主题',
                    hint: '主题是 .rfwtxt 文本，可在「导入」里加载别人的主题；'
                        '文件里只能引用 core.widgets / peek.home 两个库。',
                    children: [
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      else ...[
                        for (final e in _entries)
                          _themeRow(
                            entry: e,
                            selected: (rfwThemeIdNotifier.value ?? '') == e.id ||
                                (rfwThemeIdNotifier.value == null &&
                                    _entries.isNotEmpty &&
                                    e.id == _entries.first.id),
                          ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _import,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.file_download_outlined,
                                  size: 20,
                                  color: AppTheme.accentColor,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    '导入主题文件（.rfwtxt）',
                                    style: TextStyle(
                                      color: AppTheme.accentColor,
                                      fontSize: AppTheme.fontSubhead,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                if (enabled)
                  SettingsGroup(
                    title: '显示样式',
                    children: [
                      _styleRow('网格', 'grid'),
                      _styleRow('大网格', 'largeGrid'),
                      _styleRow('横幅', 'banner'),
                      _styleRow('列表', 'list'),
                      _styleRow('纯文字列表', 'textList'),
                      _styleRow('卡片', 'card'),
                    ],
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _themeRow({required RfwThemeEntry entry, required bool selected}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => saveRfwThemeId(entry.id),
      onLongPress: entry.isBuiltin ? null : () => _delete(entry),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
        child: Row(
          children: [
            Icon(
              entry.isBuiltin
                  ? Icons.inventory_2_outlined
                  : Icons.folder_open_outlined,
              size: 20,
              color: AppTheme.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.name,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.isBuiltin ? '内置主题' : '导入主题 · 长按删除',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, color: AppTheme.accentColor, size: 20),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _styleRow(String label, String value) {
    final selected = rfwDisplayStyleNotifier.value == value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => saveRfwDisplayStyle(value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, color: AppTheme.accentColor, size: 20),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}
