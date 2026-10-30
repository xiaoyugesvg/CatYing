import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/rfw_theme/rfw_theme_preview.dart';
import 'package:tvbox/rfw_theme/rfw_theme_store.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 「首页主题（RFW）」这一整块设置 —— 开关 + 主题选择 + 显示样式 + 导入。
///
/// ── 为什么要单独抽成一块（2026-10-30）──────────────────────────
/// 用户要求把「外观主题 / 壁纸 / RFW 主题」收进**同一个管理入口**，
/// 功能不能变。原来这块只存在于 `rfw_theme_page.dart`，如果复制一份到
/// 统一页，两边一定会分叉（改一边忘另一边）。
/// 所以抽成这个 widget：`RfwThemePage` 和「主题与外观」页**引用同一份**，
/// 改一次两边一起变。
///
/// [onPickPalette]：统一页传进来就能在卡里直接换配色（真正"互融"）；
/// 单独的主题页没有配色上下文，传 null 时只显示"跟随外观配色"的说明。
class RfwThemeSettingsSection extends StatefulWidget {
  const RfwThemeSettingsSection({
    super.key,
    this.onPickPalette,
    this.paletteName,
  });

  final VoidCallback? onPickPalette;
  final String? paletteName;

  @override
  State<RfwThemeSettingsSection> createState() =>
      _RfwThemeSettingsSectionState();
}

class _RfwThemeSettingsSectionState extends State<RfwThemeSettingsSection> {
  /// 先拿内置主题铺出来，再去扫导入的主题。
  ///
  /// 不要"等读完目录再显示"：`loadRfwThemeEntries()` 要过 path_provider，
  /// 某些环境里这个 Future 会一直挂着（widget test 里没有插件实现就是如此）
  /// ⇒ 整块卡在转圈上、`pumpAndSettle` 永远等不到静止。
  /// 内置主题是编译进包的，根本不需要等 IO，没有理由让用户看转圈。
  List<RfwThemeEntry> _entries = builtinRfwThemes;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    List<RfwThemeEntry> list;
    try {
      list = await loadRfwThemeEntries();
    } catch (_) {
      // 拿不到应用文档目录（权限/插件缺失）时，内置主题照样能选。
      return;
    }
    if (!mounted) return;
    setState(() => _entries = list);
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
    if (entry != null) {
      // 刚导入的预览要按新内容渲染，缓存里可能还是同名旧文件。
      RfwThemeTextCache.evict(entry.id);
      await saveRfwThemeId(entry.id);
    }
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
    RfwThemeTextCache.evict(entry.id);
    if (rfwThemeIdNotifier.value == entry.id) {
      await saveRfwThemeId(null);
    }
    await _reload();
  }

  Future<void> _preview(RfwThemeEntry entry) async {
    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RfwThemePreviewPage(
          entry: entry,
          initialDisplayStyle: rfwDisplayStyleNotifier.value,
        ),
      ),
    );
    if (applied == true && mounted) {
      AppToast.success('已启用「${entry.name}」');
    }
  }

  String get _currentId => effectiveRfwThemeId(rfwThemeIdNotifier.value);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        rfwThemeModeNotifier,
        rfwThemeIdNotifier,
        rfwDisplayStyleNotifier,
      ]),
      builder: (context, _) {
        final enabled = rfwThemeModeNotifier.value;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary,
            borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _head(enabled),
              const SizedBox(height: 12),
              if (enabled) ...[
                _themeStrip(),
                const SizedBox(height: 14),
                _styleChips(),
                const SizedBox(height: 12),
                _paletteLine(),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 卡片头：图标 + 标题 + 副标题 + 开关
  Widget _head(bool enabled) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.dashboard_customize_outlined,
            size: 18, color: AppTheme.accentColor),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '首页主题',
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                enabled
                    ? '正在用「${_nameOf(_currentId)}」渲染影视首页'
                    : '关闭时用软件原生首页',
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: AppTheme.textTertiary,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: enabled,
          activeThumbColor: AppTheme.accentColor,
          onChanged: (v) => saveRfwThemeMode(v),
        ),
      ],
    );
  }

  String _nameOf(String id) {
    for (final e in _entries) {
      if (e.id == id) return e.name;
    }
    return builtinRfwThemes.first.name;
  }

  /// 主题卡横向条：每张卡就是**真实渲染出来的缩略首页**。
  Widget _themeStrip() {
    return SizedBox(
      height: 236,
      child: ListView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        children: [
          for (final e in _entries)
            _ThemeCard(
              entry: e,
              selected: e.id == _currentId,
              displayStyle: rfwDisplayStyleNotifier.value,
              onSelect: () => saveRfwThemeId(e.id),
              onPreview: () => _preview(e),
              onDelete: e.isBuiltin ? null : () => _delete(e),
            ),
          _ImportCard(onTap: _import),
        ],
      ),
    );
  }

  Widget _styleChips() {
    const styles = <String, String>{
      'grid': '网格',
      'largeGrid': '大网格',
      'banner': '横幅',
      'list': '列表',
      'textList': '纯文字',
      'card': '卡片',
    };
    final current = rfwDisplayStyleNotifier.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '显示样式',
          style: TextStyle(
            fontSize: AppTheme.fontFootnote,
            color: AppTheme.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in styles.entries)
              _Chip(
                label: e.value,
                selected: current == e.key,
                onTap: () => saveRfwDisplayStyle(e.key),
              ),
          ],
        ),
      ],
    );
  }

  /// 配色联动那一行 —— 这是"外观"和"首页主题"互融的落点。
  ///
  /// 三套内置主题的颜色不是写死的，是从「外观 → 配色」实时算出来的
  /// （见 `rfw_theme_palette.dart`）。这一行把这条隐性联系**摆到明面上**，
  /// 并且给一个直接换配色的入口，省得用户在两页之间来回跳。
  Widget _paletteLine() {
    final name = widget.paletteName;
    final picker = widget.onPickPalette;
    return Row(
      children: [
        Icon(Icons.palette_outlined, size: 15, color: AppTheme.textTertiary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            name == null
                ? '配色跟随「外观 → 配色」，换配色这里会跟着变'
                : '配色跟随「$name」，换配色首页跟着变',
            maxLines: 2,
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: AppTheme.textTertiary,
              height: 1.4,
            ),
          ),
        ),
        if (picker != null)
          TextButton(
            onPressed: picker,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('换配色'),
          ),
      ],
    );
  }
}

/// 一张主题卡：缩略图 + 名字 + 预览按钮。
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.entry,
    required this.selected,
    required this.displayStyle,
    required this.onSelect,
    required this.onPreview,
    this.onDelete,
  });

  final RfwThemeEntry entry;
  final bool selected;
  final String displayStyle;
  final VoidCallback onSelect;
  final VoidCallback onPreview;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: SizedBox(
        width: 118,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSelect,
          onLongPress: onDelete,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    width: 118,
                    height: 178,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: selected
                            ? AppTheme.accentColor
                            : AppTheme.borderLight,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: RfwThemeThumb(
                      entry: entry,
                      width: 114,
                      height: 174,
                      displayStyle: displayStyle,
                      radius: 11,
                    ),
                  ),
                  if (selected)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: AppTheme.accentColor,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_rounded,
                          size: 12,
                          color: AppTheme.accentColor.computeLuminance() > 0.5
                              ? Colors.black
                              : Colors.white,
                        ),
                      ),
                    ),
                  // 预览按钮压在缩略图底部：点卡片是"选它"，点这里才"看它"。
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: GestureDetector(
                      onTap: onPreview,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.visibility_outlined,
                                size: 11, color: Colors.white),
                            SizedBox(width: 3),
                            Text(
                              '预览',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppTheme.accentColor : AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                entry.isBuiltin ? '内置' : '导入 · 长按删',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: AppTheme.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 主题条最后那张「导入」卡
class _ImportCard extends StatelessWidget {
  const _ImportCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 92,
              height: 178,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: AppTheme.borderLight, width: 1),
                color: AppTheme.backgroundTertiary,
              ),
              child: Icon(
                Icons.add_rounded,
                size: 26,
                color: AppTheme.accentColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '导入主题',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.accentColor,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '.rfwtxt',
              style: TextStyle(fontSize: 10, color: AppTheme.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accentColor : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected
                ? (AppTheme.accentColor.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white)
                : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}
