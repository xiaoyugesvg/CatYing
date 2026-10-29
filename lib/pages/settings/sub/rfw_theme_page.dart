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
